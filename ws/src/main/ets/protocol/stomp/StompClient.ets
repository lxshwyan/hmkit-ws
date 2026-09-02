import { HmWebSocketClient } from '../../core/Client';
import { SystemWsScheduler, WsScheduler } from '../../core/Scheduler';
import { WsClientObserver, WsData, WsError, WsState } from '../../core/Types';
import { StompCodec, StompCommand, StompDecodeBatch, StompFrame, StompFrameDecoder } from './StompCodec';

export enum StompClientState {
  INACTIVE = 'inactive',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  DISCONNECTING = 'disconnecting',
  ERROR = 'error'
}

export enum StompAckMode {
  AUTO = 'auto',
  CLIENT = 'client',
  CLIENT_INDIVIDUAL = 'client-individual'
}

export class StompClientOptions {
  connectHeaders: Record<string, string> = {};
  acceptVersions: string = '1.2,1.1,1.0';
  host: string = '/';
  heartbeatOutgoingMs: number = 10000;
  heartbeatIncomingMs: number = 10000;
  heartbeatToleranceMultiplier: number = 2;
  scheduler: WsScheduler = new SystemWsScheduler();
}

export class StompMessage {
  readonly frame: StompFrame;
  private readonly acknowledge: (negative: boolean, transaction: string) => Promise<void>;

  constructor(frame: StompFrame, acknowledge: (negative: boolean, transaction: string) => Promise<void>) {
    this.frame = frame;
    this.acknowledge = acknowledge;
  }

  ack(transaction: string = ''): Promise<void> { return this.acknowledge(false, transaction); }
  nack(transaction: string = ''): Promise<void> { return this.acknowledge(true, transaction); }
}

export type StompMessageHandler = (message: StompMessage) => void;

export class StompSubscription {
  readonly id: string;
  readonly destination: string;
  readonly ackMode: StompAckMode;
  readonly headers: Record<string, string>;
  readonly handler: StompMessageHandler;

  constructor(id: string, destination: string, handler: StompMessageHandler,
    ackMode: StompAckMode = StompAckMode.AUTO, headers: Record<string, string> = {}) {
    this.id = id; this.destination = destination; this.handler = handler;
    this.ackMode = ackMode; this.headers = headers;
  }
}

export class StompClientObserver {
  readonly onStateChange: (state: StompClientState) => void;
  readonly onConnect: (frame: StompFrame) => void;
  readonly onDisconnect: () => void;
  readonly onReceipt: (receiptId: string) => void;
  readonly onError: (error: Error, frame?: StompFrame) => void;

  constructor(onStateChange: (state: StompClientState) => void = (_state: StompClientState): void => {},
    onConnect: (frame: StompFrame) => void = (_frame: StompFrame): void => {},
    onDisconnect: () => void = (): void => {},
    onReceipt: (receiptId: string) => void = (_receiptId: string): void => {},
    onError: (error: Error, frame?: StompFrame) => void = (_error: Error, _frame?: StompFrame): void => {}) {
    this.onStateChange = onStateChange; this.onConnect = onConnect; this.onDisconnect = onDisconnect;
    this.onReceipt = onReceipt; this.onError = onError;
  }
}

export class StompTransaction {
  readonly id: string;
  private readonly client: StompClient;
  private completed: boolean = false;

  constructor(id: string, client: StompClient) { this.id = id; this.client = client; }
  async commit(): Promise<void> {
    if (this.completed) throw new Error('STOMP transaction 已结束');
    await this.client.completeTransaction(this.id, true); this.completed = true;
  }
  async abort(): Promise<void> {
    if (this.completed) throw new Error('STOMP transaction 已结束');
    await this.client.completeTransaction(this.id, false); this.completed = true;
  }
}

export class StompClient {
  private readonly socket: HmWebSocketClient;
  private readonly options: StompClientOptions;
  private readonly observer: StompClientObserver;
  private readonly codec: StompCodec = new StompCodec();
  private readonly decoder: StompFrameDecoder = new StompFrameDecoder();
  private readonly subscriptions: Map<string, StompSubscription> = new Map<string, StompSubscription>();
  private readonly receiptHandlers: Map<string, () => void> = new Map<string, () => void>();
  private readonly rawObserver: WsClientObserver;
  private stateValue: StompClientState = StompClientState.INACTIVE;
  private nextSubscriptionId: number = 1;
  private nextTransactionId: number = 1;
  private heartbeatSendTimer: number = -1;
  private heartbeatCheckTimer: number = -1;
  private negotiatedOutgoingMs: number = 0;
  private negotiatedIncomingMs: number = 0;
  private lastReceivedAt: number = 0;
  private active: boolean = false;

  constructor(socket: HmWebSocketClient, options: StompClientOptions = new StompClientOptions(),
    observer: StompClientObserver = new StompClientObserver()) {
    this.socket = socket; this.options = options; this.observer = observer;
    this.rawObserver = new WsClientObserver(
      (state: WsState, _previous: WsState): void => this.handleSocketState(state),
      (): void => this.handleSocketOpen(),
      (data: WsData): void => this.handleData(data),
      undefined,
      (error: WsError): void => this.emitError(new Error(error.message))
    );
    this.socket.addObserver(this.rawObserver);
  }

  state(): StompClientState { return this.stateValue; }

  async activate(): Promise<void> {
    if (this.active) return;
    this.active = true;
    this.changeState(StompClientState.CONNECTING);
    await this.socket.connect();
  }

  async deactivate(): Promise<void> {
    if (!this.active) return;
    const wasConnected: boolean = this.stateValue === StompClientState.CONNECTED;
    this.changeState(StompClientState.DISCONNECTING);
    this.cancelHeartbeats();
    if (wasConnected) {
      try { await this.sendFrame(new StompFrame(StompCommand.DISCONNECT)); } catch (_error) {}
    }
    this.active = false;
    await this.socket.close(1000, 'STOMP client deactivated');
    this.changeState(StompClientState.INACTIVE);
    this.observer.onDisconnect();
  }

  async publish(destination: string, body: WsData = '', headers: Record<string, string> = {},
    transaction: string = ''): Promise<void> {
    this.requireConnected();
    const frameHeaders: Record<string, string> = this.copyHeaders(headers);
    frameHeaders['destination'] = destination;
    if (transaction.length > 0) frameHeaders['transaction'] = transaction;
    await this.sendFrame(new StompFrame(StompCommand.SEND, frameHeaders, body));
  }

  async subscribe(destination: string, handler: StompMessageHandler,
    ackMode: StompAckMode = StompAckMode.AUTO, headers: Record<string, string> = {}): Promise<StompSubscription> {
    const id: string = headers['id'] ?? `hmkit-sub-${this.nextSubscriptionId++}`;
    const subscription: StompSubscription = new StompSubscription(id, destination, handler, ackMode,
      this.copyHeaders(headers));
    this.subscriptions.set(id, subscription);
    if (this.stateValue === StompClientState.CONNECTED) await this.sendSubscription(subscription);
    return subscription;
  }

  async unsubscribe(id: string, receipt: string = ''): Promise<void> {
    this.subscriptions.delete(id);
    if (this.stateValue !== StompClientState.CONNECTED) return;
    const headers: Record<string, string> = { 'id': id };
    if (receipt.length > 0) headers['receipt'] = receipt;
    await this.sendFrame(new StompFrame(StompCommand.UNSUBSCRIBE, headers));
  }

  async begin(): Promise<StompTransaction> {
    this.requireConnected();
    const id: string = `hmkit-tx-${this.nextTransactionId++}`;
    await this.sendFrame(new StompFrame(StompCommand.BEGIN, { 'transaction': id }));
    return new StompTransaction(id, this);
  }

  watchReceipt(receiptId: string, handler: () => void): void { this.receiptHandlers.set(receiptId, handler); }

  async completeTransaction(id: string, commit: boolean): Promise<void> {
    this.requireConnected();
    await this.sendFrame(new StompFrame(commit ? StompCommand.COMMIT : StompCommand.ABORT,
      { 'transaction': id }));
  }

  dispose(): void {
    this.cancelHeartbeats();
    this.socket.removeObserver(this.rawObserver);
  }

  private handleSocketState(state: WsState): void {
    if (!this.active) return;
    if (state === WsState.CONNECTING || state === WsState.RECONNECT_WAIT || state === WsState.OFFLINE_WAIT) {
      this.cancelHeartbeats();
      this.changeState(StompClientState.CONNECTING);
    }
  }

  private handleSocketOpen(): void {
    if (!this.active) return;
    this.decoder.reset();
    this.changeState(StompClientState.CONNECTING);
    const headers: Record<string, string> = this.copyHeaders(this.options.connectHeaders);
    headers['accept-version'] = this.options.acceptVersions;
    headers['host'] = this.options.host;
    headers['heart-beat'] = `${this.options.heartbeatOutgoingMs},${this.options.heartbeatIncomingMs}`;
    this.sendFrame(new StompFrame(StompCommand.STOMP, headers)).catch((error: Object): void => {
      this.emitError(error instanceof Error ? error : new Error('发送 STOMP CONNECT 失败'));
    });
  }

  private handleData(data: WsData): void {
    try {
      const batch: StompDecodeBatch = this.decoder.push(data);
      if (batch.heartbeatCount > 0 || batch.frames.length > 0) this.lastReceivedAt = this.options.scheduler.now();
      for (let i: number = 0; i < batch.frames.length; i++) this.handleFrame(batch.frames[i]);
    } catch (error) {
      this.emitError(error instanceof Error ? error : new Error('STOMP frame 解析失败'));
    }
  }

  private handleFrame(frame: StompFrame): void {
    if (frame.command === StompCommand.CONNECTED) {
      this.negotiateHeartbeat(frame.headers['heart-beat'] ?? '0,0');
      this.changeState(StompClientState.CONNECTED);
      this.observer.onConnect(frame);
      this.resubscribeAll().catch((error: Object): void => {
        this.emitError(error instanceof Error ? error : new Error('恢复 STOMP 订阅失败'));
      });
      return;
    }
    if (frame.command === StompCommand.MESSAGE) {
      const subscriptionId: string = frame.headers['subscription'] ?? '';
      const subscription: StompSubscription | undefined = this.subscriptions.get(subscriptionId);
      if (subscription !== undefined) {
        subscription.handler(new StompMessage(frame, (negative: boolean, transaction: string): Promise<void> =>
          this.acknowledge(frame, negative, transaction)));
      }
      return;
    }
    if (frame.command === StompCommand.RECEIPT) {
      const receiptId: string = frame.headers['receipt-id'] ?? '';
      const handler: (() => void) | undefined = this.receiptHandlers.get(receiptId);
      if (handler !== undefined) { this.receiptHandlers.delete(receiptId); handler(); }
      this.observer.onReceipt(receiptId);
      return;
    }
    if (frame.command === StompCommand.ERROR) {
      this.changeState(StompClientState.ERROR);
      this.observer.onError(new Error(frame.headers['message'] ?? 'STOMP broker error'), frame);
    }
  }

  private async acknowledge(frame: StompFrame, negative: boolean, transaction: string): Promise<void> {
    this.requireConnected();
    const ackId: string = frame.headers['ack'] ?? frame.headers['message-id'] ?? '';
    if (ackId.length === 0) throw new Error('STOMP MESSAGE 缺少 ack/message-id');
    const headers: Record<string, string> = { 'id': ackId };
    if (transaction.length > 0) headers['transaction'] = transaction;
    await this.sendFrame(new StompFrame(negative ? StompCommand.NACK : StompCommand.ACK, headers));
  }

  private async sendSubscription(subscription: StompSubscription): Promise<void> {
    const headers: Record<string, string> = this.copyHeaders(subscription.headers);
    headers['id'] = subscription.id; headers['destination'] = subscription.destination;
    headers['ack'] = subscription.ackMode;
    await this.sendFrame(new StompFrame(StompCommand.SUBSCRIBE, headers));
  }

  private async resubscribeAll(): Promise<void> {
    const subscriptions: StompSubscription[] = Array.from(this.subscriptions.values());
    for (let i: number = 0; i < subscriptions.length; i++) await this.sendSubscription(subscriptions[i]);
  }

  private async sendFrame(frame: StompFrame): Promise<void> { await this.socket.send(this.codec.encode(frame)); }

  private negotiateHeartbeat(serverHeader: string): void {
    const parts: string[] = serverHeader.split(',');
    const serverOutgoing: number = parts.length > 0 ? parseInt(parts[0], 10) : 0;
    const serverIncoming: number = parts.length > 1 ? parseInt(parts[1], 10) : 0;
    this.negotiatedOutgoingMs = this.options.heartbeatOutgoingMs > 0 && serverIncoming > 0 ?
      Math.max(this.options.heartbeatOutgoingMs, serverIncoming) : 0;
    this.negotiatedIncomingMs = this.options.heartbeatIncomingMs > 0 && serverOutgoing > 0 ?
      Math.max(this.options.heartbeatIncomingMs, serverOutgoing) : 0;
    this.lastReceivedAt = this.options.scheduler.now();
    this.scheduleOutgoingHeartbeat();
    this.scheduleIncomingCheck();
  }

  private scheduleOutgoingHeartbeat(): void {
    if (this.negotiatedOutgoingMs <= 0 || this.stateValue !== StompClientState.CONNECTED) return;
    this.heartbeatSendTimer = this.options.scheduler.schedule(this.negotiatedOutgoingMs, (): void => {
      this.heartbeatSendTimer = -1;
      this.socket.send('\n').then((): void => this.scheduleOutgoingHeartbeat()).catch((error: Object): void => {
        this.emitError(error instanceof Error ? error : new Error('STOMP heartbeat 发送失败'));
      });
    });
  }

  private scheduleIncomingCheck(): void {
    if (this.negotiatedIncomingMs <= 0 || this.stateValue !== StompClientState.CONNECTED) return;
    this.heartbeatCheckTimer = this.options.scheduler.schedule(this.negotiatedIncomingMs, (): void => {
      this.heartbeatCheckTimer = -1;
      const tolerance: number = this.negotiatedIncomingMs * this.options.heartbeatToleranceMultiplier;
      if (this.options.scheduler.now() - this.lastReceivedAt > tolerance) {
        const error: Error = new Error('STOMP heartbeat timeout');
        this.emitError(error);
        this.socket.reconnect(4000, 'STOMP heartbeat timeout').catch((_error: Object): void => {});
        return;
      }
      this.scheduleIncomingCheck();
    });
  }

  private cancelHeartbeats(): void {
    if (this.heartbeatSendTimer >= 0) this.options.scheduler.cancel(this.heartbeatSendTimer);
    if (this.heartbeatCheckTimer >= 0) this.options.scheduler.cancel(this.heartbeatCheckTimer);
    this.heartbeatSendTimer = -1; this.heartbeatCheckTimer = -1;
  }

  private requireConnected(): void {
    if (this.stateValue !== StompClientState.CONNECTED) throw new Error('STOMP 尚未连接');
  }

  private copyHeaders(headers: Record<string, string>): Record<string, string> {
    const copy: Record<string, string> = {};
    const keys: string[] = Object.keys(headers);
    for (let i: number = 0; i < keys.length; i++) copy[keys[i]] = headers[keys[i]];
    return copy;
  }

  private changeState(state: StompClientState): void {
    if (this.stateValue === state) return;
    this.stateValue = state; this.observer.onStateChange(state);
  }

  private emitError(error: Error): void { this.observer.onError(error); }
}
