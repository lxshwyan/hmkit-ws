import { WsScheduler, SystemWsScheduler } from './Scheduler';
import { WsNetworkMonitor, WsNetworkObserver } from './NetworkMonitor';
import { WsTransport, WsTransportFactory, WsTransportObserver } from './Transport';
import { StaticWsEndpointProvider, WsClientObserver, WsCloseInfo, WsData, WsEndpointProvider,
  WsError, WsErrorCode, WsState } from './Types';
import { WsHeartbeatStrategy } from '../policy/Heartbeat';
import { ExponentialBackoffPolicy, WsReconnectContext, WsReconnectDecision,
  WsReconnectPolicy } from '../policy/Reconnect';
import { MemoryWsOutboundQueue, WsDisconnectedSendMode, WsOutboundMessage,
  WsOutboundQueue, WsQueueOptions, WsQueueResult } from '../policy/Queue';

export class HmWebSocketClientOptions {
  reconnectPolicy: WsReconnectPolicy = new ExponentialBackoffPolicy();
  heartbeat?: WsHeartbeatStrategy;
  queue: WsOutboundQueue = new MemoryWsOutboundQueue(new WsQueueOptions());
  disconnectedSendMode: WsDisconnectedSendMode = WsDisconnectedSendMode.QUEUE;
  scheduler: WsScheduler = new SystemWsScheduler();
  networkMonitor?: WsNetworkMonitor;
  connectionTimeoutMs: number = 10000;
  messageTtlMs: number = 5 * 60 * 1000;
}

export class HmWebSocketClient {
  private readonly endpointProvider: WsEndpointProvider;
  private readonly transportFactory: WsTransportFactory;
  private readonly options: HmWebSocketClientOptions;
  private readonly observers: WsClientObserver[] = [];
  private transport?: WsTransport;
  private stateValue: WsState = WsState.IDLE;
  private generation: number = 0;
  private reconnectAttempt: number = 0;
  private openedAt: number = 0;
  private nextMessageId: number = 1;
  private reconnectTimer: number = -1;
  private connectionTimer: number = -1;
  private heartbeatTimer: number = -1;
  private pongTimer: number = -1;
  private intentionalClose: boolean = false;
  private networkAvailable: boolean = true;
  private monitoringNetwork: boolean = false;
  private flushing: boolean = false;
  private sendTail: Promise<void> = Promise.resolve();

  constructor(endpointProvider: WsEndpointProvider, transportFactory: WsTransportFactory,
    options: HmWebSocketClientOptions = new HmWebSocketClientOptions()) {
    this.endpointProvider = endpointProvider;
    this.transportFactory = transportFactory;
    this.options = options;
  }

  static withUrl(url: string, transportFactory: WsTransportFactory,
    options: HmWebSocketClientOptions = new HmWebSocketClientOptions()): HmWebSocketClient {
    return new HmWebSocketClient(new StaticWsEndpointProvider(url), transportFactory, options);
  }

  state(): WsState { return this.stateValue; }
  queuedMessages(): number { return this.options.queue.size(); }
  queuedBytes(): number { return this.options.queue.bytes(); }

  addObserver(observer: WsClientObserver): void {
    if (this.observers.indexOf(observer) < 0) this.observers.push(observer);
  }

  removeObserver(observer: WsClientObserver): void {
    const index: number = this.observers.indexOf(observer);
    if (index >= 0) this.observers.splice(index, 1);
  }

  async connect(): Promise<void> {
    if (this.stateValue === WsState.OPEN || this.stateValue === WsState.CONNECTING) return;
    this.intentionalClose = false;
    this.startNetworkMonitor();
    if (!this.networkAvailable) {
      this.changeState(WsState.OFFLINE_WAIT);
      return;
    }
    this.cancelReconnectTimer();
    await this.beginConnect();
  }

  async reconnect(code: number = 1000, reason: string = 'manual reconnect'): Promise<void> {
    this.intentionalClose = false;
    this.startNetworkMonitor();
    this.cancelAllTimers();
    this.generation += 1;
    const current: WsTransport | undefined = this.transport;
    this.transport = undefined;
    if (current !== undefined) {
      try { await current.close(code, reason); } catch (_error) {}
    }
    if (this.networkAvailable) await this.beginConnect();
    else this.changeState(WsState.OFFLINE_WAIT);
  }

  async close(code: number = 1000, reason: string = 'client closed'): Promise<void> {
    if (this.stateValue === WsState.CLOSED) return;
    this.intentionalClose = true;
    this.stopNetworkMonitor();
    this.cancelAllTimers();
    this.changeState(WsState.CLOSING);
    this.generation += 1;
    const current: WsTransport | undefined = this.transport;
    this.transport = undefined;
    if (current !== undefined) {
      try {
        await current.close(code, reason);
      } catch (error) {
        const mapped: WsError = this.asWsError(error, WsErrorCode.CLOSE_FAILED, '关闭连接失败');
        this.emitError(mapped);
        this.changeState(WsState.CLOSED);
        throw mapped;
      }
    }
    this.changeState(WsState.CLOSED);
  }

  async send(data: WsData): Promise<number> {
    const id: number = this.nextMessageId++;
    const operation: Promise<void> = this.sendTail.then(async (): Promise<void> => {
      await this.sendOne(id, data);
    });
    this.sendTail = operation.catch((_error: Object): void => {});
    await operation;
    return id;
  }

  private async sendOne(id: number, data: WsData): Promise<void> {
    if (this.stateValue === WsState.OPEN && this.transport !== undefined && !this.flushing) {
      try {
        await this.transport.send(data);
        this.emitSent(id);
        return;
      } catch (error) {
        const mapped: WsError = this.asWsError(error, WsErrorCode.SEND_FAILED, '发送消息失败');
        if (this.options.disconnectedSendMode !== WsDisconnectedSendMode.QUEUE) {
          this.emitError(mapped);
          throw mapped;
        }
        this.emitError(mapped);
        this.failActiveConnection(mapped);
      }
    }
    this.handleDisconnectedSend(id, data);
  }

  clearQueue(): number {
    return this.options.queue.clear().length;
  }

  private async beginConnect(): Promise<void> {
    const connectGeneration: number = ++this.generation;
    this.changeState(WsState.CONNECTING);
    const transport: WsTransport = this.transportFactory.create();
    this.transport = transport;
    transport.setObserver(new WsTransportObserver(
      (): void => this.handleOpen(connectGeneration),
      (data: WsData): void => this.handleMessage(connectGeneration, data),
      (info: WsCloseInfo): void => this.handleClose(connectGeneration, info),
      (error: WsError): void => this.handleTransportError(connectGeneration, error)
    ));
    this.connectionTimer = this.options.scheduler.schedule(this.options.connectionTimeoutMs, (): void => {
      this.handleConnectionTimeout(connectGeneration);
    });
    try {
      const endpoint = await this.endpointProvider.resolve();
      if (connectGeneration !== this.generation || this.intentionalClose) return;
      await transport.connect(endpoint.url, endpoint.options);
    } catch (error) {
      if (connectGeneration !== this.generation || this.intentionalClose) return;
      this.cancelConnectionTimer();
      const mapped: WsError = this.asWsError(error, WsErrorCode.CONNECT_FAILED, '建立连接失败');
      this.emitError(mapped);
      this.scheduleReconnect(undefined, mapped);
    }
  }

  private handleOpen(eventGeneration: number): void {
    if (eventGeneration !== this.generation || this.intentionalClose) return;
    this.cancelConnectionTimer();
    this.openedAt = this.options.scheduler.now();
    this.changeState(WsState.OPEN);
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onOpen();
    this.startHeartbeat();
    this.flushQueue().catch((error: Object): void => {
      this.emitError(this.asWsError(error, WsErrorCode.SEND_FAILED, '刷新离线队列失败'));
    });
  }

  private handleMessage(eventGeneration: number, data: WsData): void {
    if (eventGeneration !== this.generation || this.stateValue !== WsState.OPEN) return;
    const heartbeat: WsHeartbeatStrategy | undefined = this.options.heartbeat;
    if (heartbeat !== undefined && heartbeat.isPong(data)) {
      this.cancelPongTimer();
      this.scheduleHeartbeat();
      if (heartbeat.consumePong()) return;
    }
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onMessage(data);
  }

  private handleClose(eventGeneration: number, info: WsCloseInfo): void {
    if (eventGeneration !== this.generation) return;
    this.cancelConnectionTimer();
    this.cancelHeartbeatTimers();
    this.transport = undefined;
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onClose(info);
    if (this.intentionalClose) {
      this.changeState(WsState.CLOSED);
      return;
    }
    this.scheduleReconnect(info, undefined);
  }

  private handleTransportError(eventGeneration: number, error: WsError): void {
    if (eventGeneration !== this.generation || this.intentionalClose) return;
    this.emitError(error);
    this.failActiveConnection(error);
  }

  private handleConnectionTimeout(eventGeneration: number): void {
    if (eventGeneration !== this.generation || this.stateValue !== WsState.CONNECTING) return;
    const error: WsError = new WsError(WsErrorCode.CONNECTION_TIMEOUT, 'WebSocket 连接超时');
    this.emitError(error);
    this.generation += 1;
    const current: WsTransport | undefined = this.transport;
    this.transport = undefined;
    if (current !== undefined) current.close(1001, 'connection timeout').catch((_error: Object): void => {});
    this.scheduleReconnect(undefined, error);
  }

  private scheduleReconnect(closeInfo?: WsCloseInfo, error?: WsError): void {
    if (this.intentionalClose || this.reconnectTimer >= 0) return;
    this.cancelConnectionTimer();
    this.cancelHeartbeatTimers();
    if (!this.networkAvailable) {
      this.changeState(WsState.OFFLINE_WAIT);
      return;
    }
    this.reconnectAttempt += 1;
    const uptime: number = this.openedAt > 0 ? this.options.scheduler.now() - this.openedAt : 0;
    const context: WsReconnectContext = new WsReconnectContext(this.reconnectAttempt, closeInfo, error, uptime);
    const decision: WsReconnectDecision = this.options.reconnectPolicy.decide(context);
    if (!decision.retry) {
      this.changeState(closeInfo?.code === 1000 ? WsState.CLOSED : WsState.FAILED);
      return;
    }
    this.changeState(WsState.RECONNECT_WAIT);
    for (let i: number = 0; i < this.observers.length; i++) {
      this.observers[i].onReconnectScheduled(this.reconnectAttempt, decision.delayMs);
    }
    this.reconnectTimer = this.options.scheduler.schedule(decision.delayMs, (): void => {
      this.reconnectTimer = -1;
      this.beginConnect().catch((connectError: Object): void => {
        this.emitError(this.asWsError(connectError, WsErrorCode.CONNECT_FAILED, '重连失败'));
      });
    });
  }

  private handleDisconnectedSend(id: number, data: WsData): number {
    if (this.options.disconnectedSendMode === WsDisconnectedSendMode.FAIL_FAST) {
      const error: WsError = new WsError(WsErrorCode.INVALID_STATE, '连接未打开');
      this.emitDropped(id, error);
      throw error;
    }
    if (this.options.disconnectedSendMode === WsDisconnectedSendMode.DROP) {
      this.emitDropped(id, new WsError(WsErrorCode.INVALID_STATE, '连接未打开，消息已丢弃'));
      return id;
    }
    const now: number = this.options.scheduler.now();
    const expiresAt: number = this.options.messageTtlMs > 0 ? now + this.options.messageTtlMs : 0;
    const result: WsQueueResult = this.options.queue.enqueue(new WsOutboundMessage(id, data, now, expiresAt));
    if (result.dropped !== undefined) {
      this.emitDropped(result.dropped.id, new WsError(WsErrorCode.QUEUE_FULL, '队列溢出，旧消息已丢弃'));
    }
    if (!result.accepted) {
      const error: WsError = result.error ?? new WsError(WsErrorCode.QUEUE_FULL, '离线消息入队失败');
      this.emitDropped(id, error);
      throw error;
    }
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onQueued(id);
    return id;
  }

  private async flushQueue(): Promise<void> {
    if (this.flushing || this.stateValue !== WsState.OPEN || this.transport === undefined) return;
    this.flushing = true;
    try {
      const expired: WsOutboundMessage[] = this.options.queue.removeExpired(this.options.scheduler.now());
      for (let i: number = 0; i < expired.length; i++) {
        this.emitDropped(expired[i].id, new WsError(WsErrorCode.MESSAGE_EXPIRED, '离线消息已过期'));
      }
      while (this.stateValue === WsState.OPEN && this.transport !== undefined) {
        const message: WsOutboundMessage | undefined = this.options.queue.peek();
        if (message === undefined) break;
        await this.transport.send(message.data);
        this.options.queue.removeFirst();
        this.emitSent(message.id);
      }
    } finally {
      this.flushing = false;
    }
  }

  private startHeartbeat(): void {
    this.cancelHeartbeatTimers();
    this.scheduleHeartbeat();
  }

  private scheduleHeartbeat(): void {
    const heartbeat: WsHeartbeatStrategy | undefined = this.options.heartbeat;
    if (heartbeat === undefined || heartbeat.intervalMs() <= 0 || this.stateValue !== WsState.OPEN) return;
    this.cancelHeartbeatTimer();
    const currentGeneration: number = this.generation;
    this.heartbeatTimer = this.options.scheduler.schedule(heartbeat.intervalMs(), (): void => {
      if (currentGeneration !== this.generation || this.stateValue !== WsState.OPEN || this.transport === undefined) return;
      this.heartbeatTimer = -1;
      this.transport.send(heartbeat.createPing()).then((): void => {
        this.startPongTimeout(currentGeneration, heartbeat.timeoutMs());
      }).catch((error: Object): void => {
        this.handleTransportError(currentGeneration,
          this.asWsError(error, WsErrorCode.SEND_FAILED, '发送心跳失败'));
      });
    });
  }

  private startPongTimeout(eventGeneration: number, timeoutMs: number): void {
    this.cancelPongTimer();
    this.pongTimer = this.options.scheduler.schedule(timeoutMs, (): void => {
      if (eventGeneration !== this.generation || this.stateValue !== WsState.OPEN) return;
      const error: WsError = new WsError(WsErrorCode.HEARTBEAT_TIMEOUT, '心跳响应超时');
      this.emitError(error);
      const current: WsTransport | undefined = this.transport;
      if (current !== undefined) current.close(4000, 'heartbeat timeout').catch((_error: Object): void => {});
    });
  }

  private changeState(next: WsState): void {
    if (this.stateValue === next) return;
    const previous: WsState = this.stateValue;
    this.stateValue = next;
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onStateChange(next, previous);
  }

  private emitError(error: WsError): void {
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onError(error);
  }

  private emitSent(id: number): void {
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onSent(id);
  }

  private emitDropped(id: number, error: WsError): void {
    for (let i: number = 0; i < this.observers.length; i++) this.observers[i].onDropped(id, error);
  }

  private asWsError(error: Object, code: WsErrorCode, fallback: string): WsError {
    if (error instanceof WsError) return error;
    if (error instanceof Error) return new WsError(code, error.message);
    return new WsError(code, fallback);
  }

  private cancelReconnectTimer(): void {
    if (this.reconnectTimer >= 0) this.options.scheduler.cancel(this.reconnectTimer);
    this.reconnectTimer = -1;
  }

  private cancelConnectionTimer(): void {
    if (this.connectionTimer >= 0) this.options.scheduler.cancel(this.connectionTimer);
    this.connectionTimer = -1;
  }

  private cancelHeartbeatTimer(): void {
    if (this.heartbeatTimer >= 0) this.options.scheduler.cancel(this.heartbeatTimer);
    this.heartbeatTimer = -1;
  }

  private cancelPongTimer(): void {
    if (this.pongTimer >= 0) this.options.scheduler.cancel(this.pongTimer);
    this.pongTimer = -1;
  }

  private cancelHeartbeatTimers(): void {
    this.cancelHeartbeatTimer();
    this.cancelPongTimer();
  }

  private cancelAllTimers(): void {
    this.cancelReconnectTimer();
    this.cancelConnectionTimer();
    this.cancelHeartbeatTimers();
  }

  private startNetworkMonitor(): void {
    const monitor: WsNetworkMonitor | undefined = this.options.networkMonitor;
    if (monitor === undefined || this.monitoringNetwork) return;
    this.monitoringNetwork = true;
    monitor.start(new WsNetworkObserver(
      (): void => this.handleNetworkAvailable(),
      (): void => this.handleNetworkUnavailable()
    ));
    this.networkAvailable = monitor.isAvailable();
  }

  private stopNetworkMonitor(): void {
    const monitor: WsNetworkMonitor | undefined = this.options.networkMonitor;
    if (monitor !== undefined && this.monitoringNetwork) monitor.stop();
    this.monitoringNetwork = false;
  }

  private handleNetworkAvailable(): void {
    this.networkAvailable = true;
    if (this.intentionalClose || this.stateValue !== WsState.OFFLINE_WAIT) return;
    this.beginConnect().catch((error: Object): void => {
      this.emitError(this.asWsError(error, WsErrorCode.CONNECT_FAILED, '网络恢复后重连失败'));
    });
  }

  private handleNetworkUnavailable(): void {
    this.networkAvailable = false;
    if (this.intentionalClose || this.stateValue === WsState.CLOSED || this.stateValue === WsState.IDLE) return;
    this.cancelAllTimers();
    this.generation += 1;
    const current: WsTransport | undefined = this.transport;
    this.transport = undefined;
    if (current !== undefined) current.close(1001, 'network unavailable').catch((_error: Object): void => {});
    this.changeState(WsState.OFFLINE_WAIT);
  }

  private failActiveConnection(error: WsError): void {
    if (this.intentionalClose || this.stateValue === WsState.RECONNECT_WAIT ||
      this.stateValue === WsState.OFFLINE_WAIT || this.stateValue === WsState.FAILED) return;
    this.generation += 1;
    const current: WsTransport | undefined = this.transport;
    this.transport = undefined;
    this.cancelConnectionTimer();
    this.cancelHeartbeatTimers();
    if (current !== undefined) current.close(1011, 'transport failure').catch((_error: Object): void => {});
    this.scheduleReconnect(undefined, error);
  }
}
