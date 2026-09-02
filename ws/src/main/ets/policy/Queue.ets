import { WsData, WsError, WsErrorCode } from '../core/Types';

export enum WsDisconnectedSendMode {
  QUEUE = 'queue',
  FAIL_FAST = 'fail_fast',
  DROP = 'drop'
}

export enum WsQueueOverflowPolicy {
  REJECT_NEW = 'reject_new',
  DROP_OLDEST = 'drop_oldest'
}

export class WsQueueOptions {
  maxMessages: number = 1000;
  maxBytes: number = 4 * 1024 * 1024;
  ttlMs: number = 5 * 60 * 1000;
  overflowPolicy: WsQueueOverflowPolicy = WsQueueOverflowPolicy.REJECT_NEW;
}

export class WsOutboundMessage {
  readonly id: number;
  readonly data: WsData;
  readonly createdAt: number;
  readonly expiresAt: number;
  readonly bytes: number;

  constructor(id: number, data: WsData, createdAt: number, expiresAt: number) {
    this.id = id;
    this.data = data;
    this.createdAt = createdAt;
    this.expiresAt = expiresAt;
    this.bytes = typeof data === 'string' ? data.length * 2 : data.byteLength;
  }
}

export class WsQueueResult {
  readonly accepted: boolean;
  readonly dropped?: WsOutboundMessage;
  readonly error?: WsError;

  constructor(accepted: boolean, dropped?: WsOutboundMessage, error?: WsError) {
    this.accepted = accepted;
    this.dropped = dropped;
    this.error = error;
  }
}

export interface WsOutboundQueue {
  enqueue(message: WsOutboundMessage): WsQueueResult;
  peek(): WsOutboundMessage | undefined;
  removeFirst(): WsOutboundMessage | undefined;
  removeExpired(now: number): WsOutboundMessage[];
  size(): number;
  bytes(): number;
  list(): WsOutboundMessage[];
  clear(): WsOutboundMessage[];
}

export class MemoryWsOutboundQueue implements WsOutboundQueue {
  private readonly options: WsQueueOptions;
  private readonly messages: WsOutboundMessage[] = [];
  private totalBytes: number = 0;

  constructor(options: WsQueueOptions = new WsQueueOptions()) {
    this.options = options;
  }

  enqueue(message: WsOutboundMessage): WsQueueResult {
    if (message.bytes > this.options.maxBytes) {
      return new WsQueueResult(false, undefined,
        new WsError(WsErrorCode.QUEUE_FULL, '消息超过队列字节上限'));
    }
    let dropped: WsOutboundMessage | undefined;
    while (this.messages.length >= this.options.maxMessages ||
      this.totalBytes + message.bytes > this.options.maxBytes) {
      if (this.options.overflowPolicy === WsQueueOverflowPolicy.REJECT_NEW) {
        return new WsQueueResult(false, undefined,
          new WsError(WsErrorCode.QUEUE_FULL, '离线消息队列已满'));
      }
      dropped = this.removeFirst();
      if (dropped === undefined) break;
    }
    this.messages.push(message);
    this.totalBytes += message.bytes;
    return new WsQueueResult(true, dropped);
  }

  peek(): WsOutboundMessage | undefined { return this.messages[0]; }

  removeFirst(): WsOutboundMessage | undefined {
    if (this.messages.length === 0) return undefined;
    const removed: WsOutboundMessage = this.messages.shift() as WsOutboundMessage;
    this.totalBytes -= removed.bytes;
    return removed;
  }

  removeExpired(now: number): WsOutboundMessage[] {
    const removed: WsOutboundMessage[] = [];
    while (this.messages.length > 0) {
      const first: WsOutboundMessage = this.messages[0];
      if (first.expiresAt <= 0 || first.expiresAt > now) break;
      const expired: WsOutboundMessage | undefined = this.removeFirst();
      if (expired !== undefined) removed.push(expired);
    }
    return removed;
  }

  size(): number { return this.messages.length; }
  bytes(): number { return this.totalBytes; }
  list(): WsOutboundMessage[] { return [...this.messages]; }

  clear(): WsOutboundMessage[] {
    const removed: WsOutboundMessage[] = this.messages.splice(0, this.messages.length);
    this.totalBytes = 0;
    return removed;
  }
}
