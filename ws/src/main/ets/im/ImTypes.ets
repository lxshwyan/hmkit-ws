import { WsData } from '../core/Types';

export enum ImConversationKind {
  DIRECT = 'direct',
  GROUP = 'group'
}

export enum ImMessageStatus {
  PENDING = 'pending',
  SENT = 'sent',
  DELIVERED = 'delivered',
  READ = 'read',
  FAILED = 'failed'
}

export enum ImReceiptKind {
  DELIVERED = 'delivered',
  READ = 'read'
}

export enum ImPresenceState {
  OFFLINE = 'offline',
  ONLINE = 'online',
  AWAY = 'away',
  BUSY = 'busy'
}

export class ImConversation {
  readonly id: string;
  readonly kind: ImConversationKind;
  readonly title: string;
  readonly memberIds: string[];
  readonly attributes: Map<string, string>;

  constructor(id: string, kind: ImConversationKind, title: string = '', memberIds: string[] = [],
    attributes: Map<string, string> = new Map<string, string>()) {
    this.id = id;
    this.kind = kind;
    this.title = title;
    this.memberIds = [...memberIds];
    this.attributes = attributes;
  }
}

export class ImMessage {
  readonly id: string;
  readonly clientId: string;
  readonly conversationId: string;
  readonly senderId: string;
  readonly sequence: number;
  readonly createdAt: number;
  readonly contentType: string;
  readonly payload: WsData;
  readonly attributes: Map<string, string>;
  status: ImMessageStatus;

  constructor(clientId: string, conversationId: string, senderId: string, contentType: string,
    payload: WsData, createdAt: number, id: string = '', sequence: number = 0,
    status: ImMessageStatus = ImMessageStatus.PENDING,
    attributes: Map<string, string> = new Map<string, string>()) {
    this.clientId = clientId;
    this.conversationId = conversationId;
    this.senderId = senderId;
    this.contentType = contentType;
    this.payload = payload;
    this.createdAt = createdAt;
    this.id = id;
    this.sequence = sequence;
    this.status = status;
    this.attributes = attributes;
  }
}

export class ImReceipt {
  readonly conversationId: string;
  readonly messageId: string;
  readonly userId: string;
  readonly kind: ImReceiptKind;
  readonly at: number;

  constructor(conversationId: string, messageId: string, userId: string, kind: ImReceiptKind, at: number) {
    this.conversationId = conversationId;
    this.messageId = messageId;
    this.userId = userId;
    this.kind = kind;
    this.at = at;
  }
}

export class ImPresence {
  readonly userId: string;
  readonly state: ImPresenceState;
  readonly at: number;
  readonly detail: string;

  constructor(userId: string, state: ImPresenceState, at: number, detail: string = '') {
    this.userId = userId;
    this.state = state;
    this.at = at;
    this.detail = detail;
  }
}

export class ImTyping {
  readonly conversationId: string;
  readonly userId: string;
  readonly active: boolean;
  readonly expiresAt: number;

  constructor(conversationId: string, userId: string, active: boolean, expiresAt: number) {
    this.conversationId = conversationId;
    this.userId = userId;
    this.active = active;
    this.expiresAt = expiresAt;
  }
}

export class ImPageRequest {
  readonly beforeSequence: number;
  readonly limit: number;

  constructor(beforeSequence: number = 0, limit: number = 50) {
    this.beforeSequence = beforeSequence;
    this.limit = limit;
  }
}

export class ImMessagePage {
  readonly messages: ImMessage[];
  readonly hasMore: boolean;

  constructor(messages: ImMessage[], hasMore: boolean) {
    this.messages = messages;
    this.hasMore = hasMore;
  }
}

export class ImSyncBatch {
  readonly messages: ImMessage[];
  readonly receipts: ImReceipt[];
  readonly conversations: ImConversation[];
  readonly nextCursor: string;
  readonly hasMore: boolean;

  constructor(messages: ImMessage[] = [], receipts: ImReceipt[] = [], conversations: ImConversation[] = [],
    nextCursor: string = '', hasMore: boolean = false) {
    this.messages = messages;
    this.receipts = receipts;
    this.conversations = conversations;
    this.nextCursor = nextCursor;
    this.hasMore = hasMore;
  }
}
