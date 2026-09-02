import { HmWebSocketClient } from '../../core/Client';
import { SystemWsScheduler, WsScheduler } from '../../core/Scheduler';
import { WsClientObserver, WsData, WsError, WsState } from '../../core/Types';
import { EngineIoCodec, EngineIoOpenPacket, EngineIoPacket, EngineIoPacketType, SocketIoCodec,
  SocketIoEvent, SocketIoPacket, SocketIoPacketDecoder, SocketIoPacketType,
  SocketIoWireCodec } from './SocketIoCodec';

export enum SocketIoClientState {
  IDLE = 'idle',
  ENGINE_CONNECTING = 'engine_connecting',
  NAMESPACE_CONNECTING = 'namespace_connecting',
  CONNECTED = 'connected',
  CLOSED = 'closed',
  ERROR = 'error'
}

export class SocketIoClientOptions {
  scheduler: WsScheduler = new SystemWsScheduler();
  acknowledgementTimeoutMs: number = 10000;
  acknowledgementRetries: number = 0;
  defaultNamespace: string = '/';
  defaultAuthJson: string = '{}';
}

export class SocketIoIncomingEvent {
  readonly name: string;
  readonly argumentsJson: string;
  readonly namespace: string;
  readonly attachments: ArrayBuffer[];
  private readonly acknowledge: (argumentsJson: string) => Promise<void>;
  private acknowledged: boolean = false;

  constructor(event: SocketIoEvent, acknowledge: (argumentsJson: string) => Promise<void>) {
    this.name = event.name; this.argumentsJson = event.argumentsJson; this.namespace = event.namespace;
    this.attachments = event.attachments; this.acknowledge = acknowledge;
  }

  async ack(argumentsJson: string = '[]'): Promise<void> {
    if (this.acknowledged) throw new Error('Socket.IO event 已响应 ACK');
    await this.acknowledge(argumentsJson); this.acknowledged = true;
  }
}

export type SocketIoEventHandler = (event: SocketIoIncomingEvent) => void;

export class SocketIoClientObserver {
  readonly onStateChange: (state: SocketIoClientState) => void;
  readonly onEngineOpen: (handshake: EngineIoOpenPacket) => void;
  readonly onNamespaceConnected: (namespace: string, dataJson: string) => void;
  readonly onNamespaceDisconnected: (namespace: string) => void;
  readonly onError: (error: Error) => void;

  constructor(onStateChange: (state: SocketIoClientState) => void = (_state: SocketIoClientState): void => {},
    onEngineOpen: (handshake: EngineIoOpenPacket) => void = (_handshake: EngineIoOpenPacket): void => {},
    onNamespaceConnected: (namespace: string, dataJson: string) => void =
      (_namespace: string, _dataJson: string): void => {},
    onNamespaceDisconnected: (namespace: string) => void = (_namespace: string): void => {},
    onError: (error: Error) => void = (_error: Error): void => {}) {
    this.onStateChange = onStateChange; this.onEngineOpen = onEngineOpen;
    this.onNamespaceConnected = onNamespaceConnected; this.onNamespaceDisconnected = onNamespaceDisconnected;
    this.onError = onError;
  }
}

class SocketIoNamespaceConfig {
  readonly namespace: string;
  authJson: string;
  connected: boolean = false;
  constructor(namespace: string, authJson: string) { this.namespace = namespace; this.authJson = authJson; }
}

class PendingSocketIoAck {
  readonly id: number;
  readonly packet: SocketIoPacket;
  readonly resolve: (json: string) => void;
  readonly reject: (error: Error) => void;
  attempts: number = 0;
  timer: number = -1;
  constructor(id: number, packet: SocketIoPacket, resolve: (json: string) => void,
    reject: (error: Error) => void) {
    this.id = id; this.packet = packet; this.resolve = resolve; this.reject = reject;
  }
}

export class SocketIoClient {
  private readonly socket: HmWebSocketClient;
  private readonly options: SocketIoClientOptions;
  private readonly observer: SocketIoClientObserver;
  private readonly engineCodec: EngineIoCodec = new EngineIoCodec();
  private readonly socketCodec: SocketIoCodec = new SocketIoCodec();
  private readonly wireCodec: SocketIoWireCodec = new SocketIoWireCodec();
  private readonly decoder: SocketIoPacketDecoder = new SocketIoPacketDecoder();
  private readonly namespaces: Map<string, SocketIoNamespaceConfig> = new Map<string, SocketIoNamespaceConfig>();
  private readonly handlers: Map<string, SocketIoEventHandler[]> = new Map<string, SocketIoEventHandler[]>();
  private readonly pendingAcks: Map<number, PendingSocketIoAck> = new Map<number, PendingSocketIoAck>();
  private readonly rawObserver: WsClientObserver;
  private stateValue: SocketIoClientState = SocketIoClientState.IDLE;
  private nextAckId: number = 1;
  private engineOpen: boolean = false;
  private lastEnginePacketAt: number = 0;
  private watchdogTimer: number = -1;
  private handshake?: EngineIoOpenPacket;
  private active: boolean = false;

  constructor(socket: HmWebSocketClient, options: SocketIoClientOptions = new SocketIoClientOptions(),
    observer: SocketIoClientObserver = new SocketIoClientObserver()) {
    this.socket = socket; this.options = options; this.observer = observer;
    this.namespaces.set(options.defaultNamespace,
      new SocketIoNamespaceConfig(options.defaultNamespace, options.defaultAuthJson));
    this.rawObserver = new WsClientObserver(
      (state: WsState, _previous: WsState): void => this.handleSocketState(state),
      (): void => this.handleSocketOpen(),
      (data: WsData): void => this.handleData(data),
      undefined,
      (error: WsError): void => this.fail(new Error(error.message))
    );
    this.socket.addObserver(this.rawObserver);
  }

  state(): SocketIoClientState { return this.stateValue; }
  sessionId(): string { return this.handshake?.sid ?? ''; }

  async connect(): Promise<void> {
    if (this.active) return;
    this.active = true; this.changeState(SocketIoClientState.ENGINE_CONNECTING);
    await this.socket.connect();
  }

  async close(): Promise<void> {
    if (!this.active) return;
    this.active = false; this.cancelWatchdog(); this.rejectAllAcks(new Error('Socket.IO client closed'));
    const namespaceValues: SocketIoNamespaceConfig[] = Array.from(this.namespaces.values());
    for (let i: number = 0; i < namespaceValues.length; i++) {
      if (namespaceValues[i].connected) {
        const packet: SocketIoPacket = new SocketIoPacket(SocketIoPacketType.DISCONNECT);
        packet.namespace = namespaceValues[i].namespace;
        try { await this.sendSocketPacket(packet); } catch (_error) {}
      }
      namespaceValues[i].connected = false;
    }
    await this.socket.close(1000, 'Socket.IO client closed');
    this.changeState(SocketIoClientState.CLOSED);
  }

  async connectNamespace(namespace: string, authJson: string = '{}'): Promise<void> {
    this.validateNamespace(namespace);
    let config: SocketIoNamespaceConfig | undefined = this.namespaces.get(namespace);
    if (config === undefined) {
      config = new SocketIoNamespaceConfig(namespace, authJson); this.namespaces.set(namespace, config);
    } else config.authJson = authJson;
    if (this.engineOpen) await this.sendNamespaceConnect(config);
  }

  async disconnectNamespace(namespace: string): Promise<void> {
    const config: SocketIoNamespaceConfig | undefined = this.namespaces.get(namespace);
    if (config === undefined) return;
    if (config.connected) {
      const packet: SocketIoPacket = new SocketIoPacket(SocketIoPacketType.DISCONNECT);
      packet.namespace = namespace; await this.sendSocketPacket(packet);
    }
    this.namespaces.delete(namespace);
    this.observer.onNamespaceDisconnected(namespace);
  }

  on(eventName: string, handler: SocketIoEventHandler, namespace: string = '/'): void {
    const key: string = this.handlerKey(namespace, eventName);
    const values: SocketIoEventHandler[] = this.handlers.get(key) ?? [];
    if (values.indexOf(handler) < 0) values.push(handler);
    this.handlers.set(key, values);
  }

  off(eventName: string, handler?: SocketIoEventHandler, namespace: string = '/'): void {
    const key: string = this.handlerKey(namespace, eventName);
    if (handler === undefined) { this.handlers.delete(key); return; }
    const values: SocketIoEventHandler[] = this.handlers.get(key) ?? [];
    const index: number = values.indexOf(handler);
    if (index >= 0) values.splice(index, 1);
    if (values.length === 0) this.handlers.delete(key); else this.handlers.set(key, values);
  }

  async emit(eventName: string, argumentsJson: string = '[]', namespace: string = '/',
    attachments: ArrayBuffer[] = []): Promise<void> {
    this.requireNamespace(namespace);
    await this.sendSocketPacket(this.socketCodec.eventToPacket(
      new SocketIoEvent(eventName, argumentsJson, namespace, -1, attachments)));
  }

  emitWithAck(eventName: string, argumentsJson: string = '[]', namespace: string = '/',
    attachments: ArrayBuffer[] = []): Promise<string> {
    this.requireNamespace(namespace);
    const id: number = this.nextAckId++;
    const packet: SocketIoPacket = this.socketCodec.eventToPacket(
      new SocketIoEvent(eventName, argumentsJson, namespace, id, attachments));
    return new Promise<string>((resolve: (value: string) => void, reject: (error: Error) => void): void => {
      const pending: PendingSocketIoAck = new PendingSocketIoAck(id, packet, resolve, reject);
      this.pendingAcks.set(id, pending);
      this.sendPendingAck(pending);
    });
  }

  dispose(): void { this.cancelWatchdog(); this.socket.removeObserver(this.rawObserver); }

  private handleSocketState(state: WsState): void {
    if (!this.active) return;
    if (state === WsState.CONNECTING || state === WsState.RECONNECT_WAIT || state === WsState.OFFLINE_WAIT) {
      this.engineOpen = false; this.decoder.reset(); this.cancelWatchdog();
      const configs: SocketIoNamespaceConfig[] = Array.from(this.namespaces.values());
      for (let i: number = 0; i < configs.length; i++) configs[i].connected = false;
      this.changeState(SocketIoClientState.ENGINE_CONNECTING);
    }
  }

  private handleSocketOpen(): void {
    if (!this.active) return;
    this.lastEnginePacketAt = this.options.scheduler.now();
    this.changeState(SocketIoClientState.ENGINE_CONNECTING);
  }

  private handleData(data: WsData): void {
    try {
      const enginePacket: EngineIoPacket = this.engineCodec.decode(data);
      this.lastEnginePacketAt = this.options.scheduler.now();
      if (enginePacket.type === EngineIoPacketType.OPEN) {
        this.handshake = this.engineCodec.decodeOpen(enginePacket); this.engineOpen = true;
        this.observer.onEngineOpen(this.handshake); this.changeState(SocketIoClientState.NAMESPACE_CONNECTING);
        this.connectAllNamespaces(); this.scheduleWatchdog(); return;
      }
      if (enginePacket.type === EngineIoPacketType.PING) {
        this.socket.send(this.engineCodec.encode(new EngineIoPacket(EngineIoPacketType.PONG,
          enginePacket.data))).catch((error: Object): void => this.fail(
          error instanceof Error ? error : new Error('Engine.IO PONG 发送失败')));
        this.scheduleWatchdog(); return;
      }
      if (enginePacket.type === EngineIoPacketType.CLOSE) {
        this.socket.reconnect(4001, 'Engine.IO close').catch((_error: Object): void => {}); return;
      }
      if (enginePacket.type !== EngineIoPacketType.MESSAGE) return;
      const socketData: WsData = enginePacket.data;
      const packets: SocketIoPacket[] = this.decoder.push(socketData);
      for (let i: number = 0; i < packets.length; i++) this.handleSocketPacket(packets[i]);
    } catch (error) {
      this.fail(error instanceof Error ? error : new Error('Socket.IO packet 解析失败'));
    }
  }

  private handleSocketPacket(packet: SocketIoPacket): void {
    if (packet.type === SocketIoPacketType.CONNECT) {
      const config: SocketIoNamespaceConfig | undefined = this.namespaces.get(packet.namespace);
      if (config !== undefined) config.connected = true;
      this.changeState(SocketIoClientState.CONNECTED);
      this.observer.onNamespaceConnected(packet.namespace, packet.dataJson);
      return;
    }
    if (packet.type === SocketIoPacketType.DISCONNECT) {
      const config: SocketIoNamespaceConfig | undefined = this.namespaces.get(packet.namespace);
      if (config !== undefined) config.connected = false;
      this.observer.onNamespaceDisconnected(packet.namespace); return;
    }
    if (packet.type === SocketIoPacketType.CONNECT_ERROR) {
      this.fail(new Error(`Socket.IO namespace connect error: ${packet.dataJson}`)); return;
    }
    if (packet.type === SocketIoPacketType.ACK || packet.type === SocketIoPacketType.BINARY_ACK) {
      const pending: PendingSocketIoAck | undefined = this.pendingAcks.get(packet.ackId);
      if (pending !== undefined) {
        this.pendingAcks.delete(packet.ackId); this.options.scheduler.cancel(pending.timer);
        pending.resolve(packet.dataJson);
      }
      return;
    }
    if (packet.type === SocketIoPacketType.EVENT || packet.type === SocketIoPacketType.BINARY_EVENT) {
      const event: SocketIoEvent = this.socketCodec.packetToEvent(packet);
      const incoming: SocketIoIncomingEvent = new SocketIoIncomingEvent(event,
        (argumentsJson: string): Promise<void> => this.sendAck(event, argumentsJson));
      const values: SocketIoEventHandler[] = this.handlers.get(this.handlerKey(event.namespace, event.name)) ?? [];
      for (let i: number = 0; i < values.length; i++) values[i](incoming);
    }
  }

  private async sendAck(event: SocketIoEvent, argumentsJson: string): Promise<void> {
    if (event.ackId < 0) throw new Error('该 Socket.IO event 未请求 ACK');
    const args: string = argumentsJson.trim();
    if (!args.startsWith('[') || !args.endsWith(']')) throw new Error('ACK 参数必须是 JSON 数组');
    const packet: SocketIoPacket = new SocketIoPacket(event.attachments.length > 0 ?
      SocketIoPacketType.BINARY_ACK : SocketIoPacketType.ACK);
    packet.namespace = event.namespace; packet.ackId = event.ackId; packet.dataJson = args;
    await this.sendSocketPacket(packet);
  }

  private async sendSocketPacket(packet: SocketIoPacket): Promise<void> {
    const frames: WsData[] = this.wireCodec.encodePacket(packet);
    for (let i: number = 0; i < frames.length; i++) await this.socket.send(frames[i]);
  }

  private sendPendingAck(pending: PendingSocketIoAck): void {
    pending.attempts += 1;
    this.sendSocketPacket(pending.packet).then((): void => {
      pending.timer = this.options.scheduler.schedule(this.options.acknowledgementTimeoutMs, (): void => {
        pending.timer = -1;
        if (!this.pendingAcks.has(pending.id)) return;
        if (pending.attempts <= this.options.acknowledgementRetries) this.sendPendingAck(pending);
        else {
          this.pendingAcks.delete(pending.id);
          pending.reject(new Error(`Socket.IO ACK timeout: ${pending.id}`));
        }
      });
    }).catch((error: Object): void => {
      this.pendingAcks.delete(pending.id);
      pending.reject(error instanceof Error ? error : new Error('Socket.IO event 发送失败'));
    });
  }

  private connectAllNamespaces(): void {
    const configs: SocketIoNamespaceConfig[] = Array.from(this.namespaces.values());
    for (let i: number = 0; i < configs.length; i++) {
      this.sendNamespaceConnect(configs[i]).catch((error: Object): void => this.fail(
        error instanceof Error ? error : new Error('Socket.IO namespace 连接失败')));
    }
  }

  private async sendNamespaceConnect(config: SocketIoNamespaceConfig): Promise<void> {
    const packet: SocketIoPacket = new SocketIoPacket(SocketIoPacketType.CONNECT);
    packet.namespace = config.namespace; packet.dataJson = config.authJson;
    await this.sendSocketPacket(packet);
  }

  private scheduleWatchdog(): void {
    this.cancelWatchdog();
    const handshake: EngineIoOpenPacket | undefined = this.handshake;
    if (handshake === undefined) return;
    const timeout: number = handshake.pingInterval + handshake.pingTimeout;
    this.watchdogTimer = this.options.scheduler.schedule(timeout, (): void => {
      this.watchdogTimer = -1;
      if (this.options.scheduler.now() - this.lastEnginePacketAt >= timeout) {
        this.fail(new Error('Engine.IO heartbeat timeout'));
        this.socket.reconnect(4000, 'Engine.IO heartbeat timeout').catch((_error: Object): void => {});
      } else this.scheduleWatchdog();
    });
  }

  private cancelWatchdog(): void {
    if (this.watchdogTimer >= 0) this.options.scheduler.cancel(this.watchdogTimer);
    this.watchdogTimer = -1;
  }

  private rejectAllAcks(error: Error): void {
    const values: PendingSocketIoAck[] = Array.from(this.pendingAcks.values()); this.pendingAcks.clear();
    for (let i: number = 0; i < values.length; i++) {
      this.options.scheduler.cancel(values[i].timer); values[i].reject(error);
    }
  }

  private requireNamespace(namespace: string): void {
    const config: SocketIoNamespaceConfig | undefined = this.namespaces.get(namespace);
    if (config === undefined || !config.connected) throw new Error(`Socket.IO namespace 未连接：${namespace}`);
  }

  private validateNamespace(namespace: string): void {
    if (!namespace.startsWith('/')) throw new Error('Socket.IO namespace 必须以 / 开头');
  }
  private handlerKey(namespace: string, event: string): string { return `${namespace}\u0000${event}`; }
  private changeState(state: SocketIoClientState): void {
    if (this.stateValue === state) return; this.stateValue = state; this.observer.onStateChange(state);
  }
  private fail(error: Error): void { this.changeState(SocketIoClientState.ERROR); this.observer.onError(error); }
}
