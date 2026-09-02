import { ImConversation, ImMessage, ImMessagePage, ImMessageStatus, ImPageRequest } from './ImTypes';

export interface ImMessageStore {
  put(message: ImMessage): Promise<void>;
  get(idOrClientId: string): Promise<ImMessage | undefined>;
  updateStatus(idOrClientId: string, status: ImMessageStatus): Promise<void>;
  page(conversationId: string, request: ImPageRequest): Promise<ImMessagePage>;
}

export interface ImConversationStore {
  put(conversation: ImConversation): Promise<void>;
  get(id: string): Promise<ImConversation | undefined>;
  list(): Promise<ImConversation[]>;
}

export interface ImCursorStore {
  get(): Promise<string>;
  set(cursor: string): Promise<void>;
}

export class MemoryImMessageStore implements ImMessageStore {
  private readonly messages: ImMessage[] = [];

  async put(message: ImMessage): Promise<void> {
    const index: number = this.findIndex(message.id.length > 0 ? message.id : message.clientId);
    if (index >= 0) this.messages[index] = message;
    else this.messages.push(message);
  }

  async get(idOrClientId: string): Promise<ImMessage | undefined> {
    const index: number = this.findIndex(idOrClientId);
    return index >= 0 ? this.messages[index] : undefined;
  }

  async updateStatus(idOrClientId: string, status: ImMessageStatus): Promise<void> {
    const message: ImMessage | undefined = await this.get(idOrClientId);
    if (message !== undefined) message.status = status;
  }

  async page(conversationId: string, request: ImPageRequest): Promise<ImMessagePage> {
    const matching: ImMessage[] = this.messages.filter((message: ImMessage): boolean => {
      return message.conversationId === conversationId &&
        (request.beforeSequence <= 0 || message.sequence < request.beforeSequence);
    });
    matching.sort((left: ImMessage, right: ImMessage): number => right.sequence - left.sequence);
    const hasMore: boolean = matching.length > request.limit;
    return new ImMessagePage(matching.slice(0, request.limit), hasMore);
  }

  private findIndex(idOrClientId: string): number {
    for (let i: number = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === idOrClientId || this.messages[i].clientId === idOrClientId) return i;
    }
    return -1;
  }
}

export class MemoryImConversationStore implements ImConversationStore {
  private readonly conversations: Map<string, ImConversation> = new Map<string, ImConversation>();
  async put(conversation: ImConversation): Promise<void> { this.conversations.set(conversation.id, conversation); }
  async get(id: string): Promise<ImConversation | undefined> { return this.conversations.get(id); }
  async list(): Promise<ImConversation[]> { return Array.from(this.conversations.values()); }
}

export class MemoryImCursorStore implements ImCursorStore {
  private cursor: string = '';
  async get(): Promise<string> { return this.cursor; }
  async set(cursor: string): Promise<void> { this.cursor = cursor; }
}
