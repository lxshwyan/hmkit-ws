import { ImGateway, ImGatewayObserver, ImModerationPolicy } from './ImGateway';
import { ImConversationStore, ImCursorStore, ImMessageStore, MemoryImConversationStore,
  MemoryImCursorStore, MemoryImMessageStore } from './ImStore';
import { ImConversation, ImMessage, ImMessagePage, ImMessageStatus, ImPageRequest, ImPresence,
  ImReceipt, ImReceiptKind, ImSyncBatch, ImTyping } from './ImTypes';

export class ImClientObserver {
  readonly onMessage: (message: ImMessage) => void;
  readonly onReceipt: (receipt: ImReceipt) => void;
  readonly onPresence: (presence: ImPresence) => void;
  readonly onTyping: (typing: ImTyping) => void;
  readonly onError: (error: Error) => void;

  constructor(onMessage: (message: ImMessage) => void = (_message: ImMessage): void => {},
    onReceipt: (receipt: ImReceipt) => void = (_receipt: ImReceipt): void => {},
    onPresence: (presence: ImPresence) => void = (_presence: ImPresence): void => {},
    onTyping: (typing: ImTyping) => void = (_typing: ImTyping): void => {},
    onError: (error: Error) => void = (_error: Error): void => {}) {
    this.onMessage = onMessage;
    this.onReceipt = onReceipt;
    this.onPresence = onPresence;
    this.onTyping = onTyping;
    this.onError = onError;
  }
}

export class ImClientOptions {
  messageStore: ImMessageStore = new MemoryImMessageStore();
  conversationStore: ImConversationStore = new MemoryImConversationStore();
  cursorStore: ImCursorStore = new MemoryImCursorStore();
  moderation?: ImModerationPolicy;
  syncPageSize: number = 100;
  now: () => number = (): number => Date.now();
  createClientId: () => string = (): string => `${Date.now()}-${Math.random()}`;
}

export class ImClient {
  private readonly gateway: ImGateway;
  private readonly userId: string;
  private readonly options: ImClientOptions;
  private readonly observers: ImClientObserver[] = [];
  private syncing: boolean = false;

  constructor(userId: string, gateway: ImGateway, options: ImClientOptions = new ImClientOptions()) {
    this.userId = userId;
    this.gateway = gateway;
    this.options = options;
    this.gateway.setObserver(new ImGatewayObserver(
      (message: ImMessage): void => { this.receiveMessage(message).catch((error: Error): void => this.emitError(error)); },
      (receipt: ImReceipt): void => { this.receiveReceipt(receipt).catch((error: Error): void => this.emitError(error)); },
      (presence: ImPresence): void => this.emitPresence(presence),
      (typing: ImTyping): void => this.emitTyping(typing),
      (error: Error): void => this.emitError(error)
    ));
  }

  addObserver(observer: ImClientObserver): void {
    if (this.observers.indexOf(observer) < 0) this.observers.push(observer);
  }

  removeObserver(observer: ImClientObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) this.observers.splice(index, 1);
  }

  async connect(syncAfterConnect: boolean = true): Promise<void> {
    await this.gateway.connect();
    if (syncAfterConnect) await this.sync();
  }

  async disconnect(): Promise<void> { await this.gateway.disconnect(); }

  async sendMessage(conversationId: string, contentType: string, payload: string | ArrayBuffer,
    attributes: Map<string, string> = new Map<string, string>()): Promise<ImMessage> {
    const message: ImMessage = new ImMessage(this.options.createClientId(), conversationId, this.userId,
      contentType, payload, this.options.now(), '', 0, ImMessageStatus.PENDING, attributes);
    const moderation: ImModerationPolicy | undefined = this.options.moderation;
    if (moderation !== undefined) await moderation.validate(message);
    await this.options.messageStore.put(message);
    try {
      const accepted: ImMessage = await this.gateway.sendMessage(message);
      accepted.status = ImMessageStatus.SENT;
      await this.options.messageStore.put(accepted);
      this.emitMessage(accepted);
      return accepted;
    } catch (error) {
      await this.options.messageStore.updateStatus(message.clientId, ImMessageStatus.FAILED);
      const mapped: Error = error instanceof Error ? error : new Error('发送 IM 消息失败');
      this.emitError(mapped);
      throw mapped;
    }
  }

  async markDelivered(message: ImMessage): Promise<void> {
    await this.sendReceipt(message, ImReceiptKind.DELIVERED);
  }

  async markRead(message: ImMessage): Promise<void> {
    await this.sendReceipt(message, ImReceiptKind.READ);
  }

  async setTyping(conversationId: string, active: boolean, ttlMs: number = 5000): Promise<void> {
    await this.gateway.sendTyping(new ImTyping(conversationId, this.userId, active,
      active ? this.options.now() + ttlMs : this.options.now()));
  }

  async history(conversationId: string, request: ImPageRequest = new ImPageRequest()): Promise<ImMessagePage> {
    return this.options.messageStore.page(conversationId, request);
  }

  async sync(): Promise<void> {
    if (this.syncing) return;
    this.syncing = true;
    try {
      let cursor: string = await this.options.cursorStore.get();
      let hasMore: boolean = true;
      while (hasMore) {
        const batch: ImSyncBatch = await this.gateway.sync(cursor, this.options.syncPageSize);
        for (let i: number = 0; i < batch.conversations.length; i++) {
          await this.options.conversationStore.put(batch.conversations[i]);
        }
        for (let i: number = 0; i < batch.messages.length; i++) await this.receiveMessage(batch.messages[i]);
        for (let i: number = 0; i < batch.receipts.length; i++) await this.receiveReceipt(batch.receipts[i]);
        cursor = batch.nextCursor;
        await this.options.cursorStore.set(cursor);
        hasMore = batch.hasMore;
      }
    } finally {
      this.syncing = false;
    }
  }

  private async sendReceipt(message: ImMessage, kind: ImReceiptKind): Promise<void> {
    if (message.id.length === 0) throw new Error('服务端消息 ID 为空，无法发送回执');
    const receipt: ImReceipt = new ImReceipt(message.conversationId, message.id, this.userId, kind, this.options.now());
    await this.gateway.sendReceipt(receipt);
    await this.receiveReceipt(receipt);
  }

  private async receiveMessage(message: ImMessage): Promise<void> {
    const key: string = message.id.length > 0 ? message.id : message.clientId;
    const existing: ImMessage | undefined = await this.options.messageStore.get(key);
    if (existing !== undefined && existing.sequence === message.sequence && existing.status === message.status) return;
    await this.options.messageStore.put(message);
    this.emitMessage(message);
  }

  private async receiveReceipt(receipt: ImReceipt): Promise<void> {
    const status: ImMessageStatus = receipt.kind === ImReceiptKind.READ ?
      ImMessageStatus.READ : ImMessageStatus.DELIVERED;
    await this.options.messageStore.updateStatus(receipt.messageId, status);
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onReceipt(receipt);
  }

  private emitMessage(message: ImMessage): void {
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onMessage(message);
  }

  private emitPresence(presence: ImPresence): void {
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onPresence(presence);
  }

  private emitTyping(typing: ImTyping): void {
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onTyping(typing);
  }

  private emitError(error: Error): void {
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onError(error);
  }
}
