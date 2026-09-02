import { fileIo as fs } from '@kit.CoreFileKit';
import { WsBase64Codec } from '../core/Bytes';
import { WsData } from '../core/Types';
import { ImConversationStore, ImCursorStore, ImMessageStore } from './ImStore';
import { ImConversation, ImConversationKind, ImMessage, ImMessagePage, ImMessageStatus,
  ImPageRequest } from './ImTypes';

export class ImAttributeEntry {
  key: string = '';
  value: string = '';
  constructor(key: string = '', value: string = '') { this.key = key; this.value = value; }
}

export class ImPersistedMessage {
  id: string = '';
  clientId: string = '';
  conversationId: string = '';
  senderId: string = '';
  sequence: number = 0;
  createdAt: number = 0;
  contentType: string = '';
  binary: boolean = false;
  payload: string = '';
  status: string = ImMessageStatus.PENDING;
  attributes: ImAttributeEntry[] = [];
}

export class ImPersistedConversation {
  id: string = '';
  kind: string = ImConversationKind.DIRECT;
  title: string = '';
  memberIds: string[] = [];
  attributes: ImAttributeEntry[] = [];
}

export class ImStoreSnapshot {
  version: number = 1;
  cursor: string = '';
  messages: ImPersistedMessage[] = [];
  conversations: ImPersistedConversation[] = [];
}

export interface ImStoreSnapshotCodec {
  encode(snapshot: ImStoreSnapshot): string | ArrayBuffer;
  decode(data: string | ArrayBuffer): ImStoreSnapshot;
}

export class JsonImStoreSnapshotCodec implements ImStoreSnapshotCodec {
  encode(snapshot: ImStoreSnapshot): string { return JSON.stringify(snapshot); }
  decode(data: string | ArrayBuffer): ImStoreSnapshot {
    if (typeof data !== 'string') throw new Error('JSON IM store 需要文本数据');
    const snapshot: ImStoreSnapshot = JSON.parse(data) as ImStoreSnapshot;
    if (snapshot.version !== 1) throw new Error(`不支持的 IM store version：${snapshot.version}`);
    return snapshot;
  }
}

export class FileImStoreOptions {
  fileName: string = 'hmkit-im-store.data';
  codec: ImStoreSnapshotCodec = new JsonImStoreSnapshotCodec();
  maxMessages: number = 100000;
}

class FileImStoreBackend {
  private readonly filePath: string;
  private readonly temporaryPath: string;
  private readonly backupPath: string;
  private readonly options: FileImStoreOptions;
  private snapshot: ImStoreSnapshot = new ImStoreSnapshot();

  constructor(directory: string, options: FileImStoreOptions = new FileImStoreOptions()) {
    if (directory.trim().length === 0) throw new Error('IM store directory 不能为空');
    const base: string = directory.endsWith('/') ? directory.substring(0, directory.length - 1) : directory;
    this.options = options;
    this.filePath = `${base}/${options.fileName}`;
    this.temporaryPath = `${this.filePath}.tmp`;
    this.backupPath = `${this.filePath}.bak`;
    this.load();
  }

  async putMessageValue(value: ImMessage): Promise<void> { this.upsertMessage(value); this.flush(); }

  async getMessageValue(id: string): Promise<ImMessage | undefined> {
    for (let i: number = 0; i < this.snapshot.messages.length; i++) {
      const message: ImPersistedMessage = this.snapshot.messages[i];
      if (message.id === id || message.clientId === id) return this.decodeMessage(message);
    }
    return undefined;
  }

  async updateStatus(idOrClientId: string, status: ImMessageStatus): Promise<void> {
    for (let i: number = 0; i < this.snapshot.messages.length; i++) {
      const message: ImPersistedMessage = this.snapshot.messages[i];
      if (message.id === idOrClientId || message.clientId === idOrClientId) {
        message.status = status; this.flush(); return;
      }
    }
  }

  async page(conversationId: string, request: ImPageRequest): Promise<ImMessagePage> {
    const messages: ImMessage[] = [];
    for (let i: number = 0; i < this.snapshot.messages.length; i++) {
      const persisted: ImPersistedMessage = this.snapshot.messages[i];
      if (persisted.conversationId === conversationId &&
        (request.beforeSequence <= 0 || persisted.sequence < request.beforeSequence)) {
        messages.push(this.decodeMessage(persisted));
      }
    }
    messages.sort((left: ImMessage, right: ImMessage): number => right.sequence - left.sequence);
    return new ImMessagePage(messages.slice(0, request.limit), messages.length > request.limit);
  }

  async putConversationValue(value: ImConversation): Promise<void> {
    this.upsertConversation(value); this.flush();
  }

  async getConversationValue(id: string): Promise<ImConversation | undefined> {
    for (let i: number = 0; i < this.snapshot.conversations.length; i++) {
      if (this.snapshot.conversations[i].id === id) return this.decodeConversation(this.snapshot.conversations[i]);
    }
    return undefined;
  }

  async listConversations(): Promise<ImConversation[]> {
    return this.snapshot.conversations.map((value: ImPersistedConversation): ImConversation =>
      this.decodeConversation(value));
  }

  async setCursor(cursor: string): Promise<void> { this.snapshot.cursor = cursor; this.flush(); }
  async getCursor(): Promise<string> { return this.snapshot.cursor; }

  exportSnapshot(): ImStoreSnapshot { return this.snapshot; }

  private upsertMessage(message: ImMessage): void {
    const persisted: ImPersistedMessage = this.encodeMessage(message);
    let index: number = -1;
    for (let i: number = 0; i < this.snapshot.messages.length; i++) {
      const current: ImPersistedMessage = this.snapshot.messages[i];
      if ((message.id.length > 0 && current.id === message.id) || current.clientId === message.clientId) {
        index = i; break;
      }
    }
    if (index >= 0) this.snapshot.messages[index] = persisted;
    else this.snapshot.messages.push(persisted);
    if (this.snapshot.messages.length > this.options.maxMessages) {
      this.snapshot.messages.sort((left: ImPersistedMessage, right: ImPersistedMessage): number =>
        left.createdAt - right.createdAt);
      this.snapshot.messages.splice(0, this.snapshot.messages.length - this.options.maxMessages);
    }
  }

  private upsertConversation(conversation: ImConversation): void {
    const persisted: ImPersistedConversation = this.encodeConversation(conversation);
    for (let i: number = 0; i < this.snapshot.conversations.length; i++) {
      if (this.snapshot.conversations[i].id === conversation.id) {
        this.snapshot.conversations[i] = persisted; return;
      }
    }
    this.snapshot.conversations.push(persisted);
  }

  private load(): void {
    if (!fs.accessSync(this.filePath) && fs.accessSync(this.backupPath)) {
      fs.renameSync(this.backupPath, this.filePath);
    }
    if (!fs.accessSync(this.filePath)) return;
    try { this.snapshot = this.options.codec.decode(fs.readTextSync(this.filePath)); }
    catch (primaryError) {
      if (!fs.accessSync(this.backupPath)) {
        throw primaryError instanceof Error ? primaryError : new Error('读取 IM file store 失败');
      }
      this.snapshot = this.options.codec.decode(fs.readTextSync(this.backupPath));
    }
  }

  private flush(): void {
    const data: string | ArrayBuffer = this.options.codec.encode(this.snapshot);
    let file: fs.File | undefined;
    try {
      file = fs.openSync(this.temporaryPath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data); fs.fsyncSync(file.fd); fs.closeSync(file); file = undefined;
      if (fs.accessSync(this.backupPath)) fs.unlinkSync(this.backupPath);
      if (fs.accessSync(this.filePath)) fs.renameSync(this.filePath, this.backupPath);
      fs.renameSync(this.temporaryPath, this.filePath);
      if (fs.accessSync(this.backupPath)) fs.unlinkSync(this.backupPath);
    } catch (error) {
      if (!fs.accessSync(this.filePath) && fs.accessSync(this.backupPath)) {
        try { fs.renameSync(this.backupPath, this.filePath); } catch (_restoreError) {}
      }
      throw error instanceof Error ? error : new Error('写入 IM file store 失败');
    } finally {
      if (file !== undefined) { try { fs.closeSync(file); } catch (_closeError) {} }
    }
  }

  private encodeMessage(message: ImMessage): ImPersistedMessage {
    const value: ImPersistedMessage = new ImPersistedMessage();
    value.id = message.id; value.clientId = message.clientId; value.conversationId = message.conversationId;
    value.senderId = message.senderId; value.sequence = message.sequence; value.createdAt = message.createdAt;
    value.contentType = message.contentType; value.status = message.status;
    if (typeof message.payload === 'string') value.payload = message.payload;
    else { value.binary = true; value.payload = WsBase64Codec.encode(new Uint8Array(message.payload)); }
    value.attributes = this.encodeAttributes(message.attributes); return value;
  }

  private decodeMessage(value: ImPersistedMessage): ImMessage {
    const payload: WsData = value.binary ? WsBase64Codec.decode(value.payload).buffer : value.payload;
    return new ImMessage(value.clientId, value.conversationId, value.senderId, value.contentType, payload,
      value.createdAt, value.id, value.sequence, value.status as ImMessageStatus,
      this.decodeAttributes(value.attributes));
  }

  private encodeConversation(value: ImConversation): ImPersistedConversation {
    const persisted: ImPersistedConversation = new ImPersistedConversation();
    persisted.id = value.id; persisted.kind = value.kind; persisted.title = value.title;
    persisted.memberIds = [...value.memberIds]; persisted.attributes = this.encodeAttributes(value.attributes);
    return persisted;
  }

  private decodeConversation(value: ImPersistedConversation): ImConversation {
    return new ImConversation(value.id, value.kind as ImConversationKind, value.title,
      value.memberIds, this.decodeAttributes(value.attributes));
  }

  private encodeAttributes(attributes: Map<string, string>): ImAttributeEntry[] {
    const result: ImAttributeEntry[] = [];
    attributes.forEach((value: string, key: string): void => { result.push(new ImAttributeEntry(key, value)); });
    return result;
  }

  private decodeAttributes(entries: ImAttributeEntry[]): Map<string, string> {
    const result: Map<string, string> = new Map<string, string>();
    for (let i: number = 0; i < entries.length; i++) result.set(entries[i].key, entries[i].value);
    return result;
  }
}

class FileImMessageStore implements ImMessageStore {
  private readonly backend: FileImStoreBackend;
  constructor(backend: FileImStoreBackend) { this.backend = backend; }
  put(message: ImMessage): Promise<void> { return this.backend.putMessageValue(message); }
  get(idOrClientId: string): Promise<ImMessage | undefined> { return this.backend.getMessageValue(idOrClientId); }
  updateStatus(idOrClientId: string, status: ImMessageStatus): Promise<void> {
    return this.backend.updateStatus(idOrClientId, status);
  }
  page(conversationId: string, request: ImPageRequest): Promise<ImMessagePage> {
    return this.backend.page(conversationId, request);
  }
}

class FileImConversationStore implements ImConversationStore {
  private readonly backend: FileImStoreBackend;
  constructor(backend: FileImStoreBackend) { this.backend = backend; }
  put(conversation: ImConversation): Promise<void> { return this.backend.putConversationValue(conversation); }
  get(id: string): Promise<ImConversation | undefined> { return this.backend.getConversationValue(id); }
  list(): Promise<ImConversation[]> { return this.backend.listConversations(); }
}

class FileImCursorStore implements ImCursorStore {
  private readonly backend: FileImStoreBackend;
  constructor(backend: FileImStoreBackend) { this.backend = backend; }
  get(): Promise<string> { return this.backend.getCursor(); }
  set(cursor: string): Promise<void> { return this.backend.setCursor(cursor); }
}

export class FileImStore {
  readonly messages: ImMessageStore;
  readonly conversations: ImConversationStore;
  readonly cursor: ImCursorStore;
  private readonly backend: FileImStoreBackend;

  constructor(directory: string, options: FileImStoreOptions = new FileImStoreOptions()) {
    this.backend = new FileImStoreBackend(directory, options);
    this.messages = new FileImMessageStore(this.backend);
    this.conversations = new FileImConversationStore(this.backend);
    this.cursor = new FileImCursorStore(this.backend);
  }

  exportSnapshot(): ImStoreSnapshot { return this.backend.exportSnapshot(); }
}
