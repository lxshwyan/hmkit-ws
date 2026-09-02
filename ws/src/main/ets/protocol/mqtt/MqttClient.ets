import { HmWebSocketClient } from '../../core/Client';
import { SystemWsScheduler, WsScheduler } from '../../core/Scheduler';
import { WsClientObserver, WsData, WsError, WsState } from '../../core/Types';
import { MqttCodec, MqttConnectOptions, MqttDecodedPacket, MqttPacketDecoder, MqttPacketType,
  MqttProperty, MqttPropertyId, MqttPropertyType, MqttProtocolVersion, MqttPublishPacket, MqttQoS,
  MqttSubscription } from './MqttCodec';

export enum MqttClientState {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  AUTHENTICATING = 'authenticating',
  CONNECTED = 'connected',
  DISCONNECTING = 'disconnecting',
  CLOSED = 'closed',
  ERROR = 'error'
}

export class MqttAuthResponse {
  readonly reasonCode: number;
  readonly properties: MqttProperty[];
  constructor(reasonCode: number = 0x18, properties: MqttProperty[] = []) {
    this.reasonCode = reasonCode; this.properties = properties;
  }
}

export interface MqttAuthenticationHandler {
  authenticate(reasonCode: number, method: string, data: ArrayBuffer,
    properties: MqttProperty[]): Promise<MqttAuthResponse | undefined>;
}

export class MqttV5Capabilities {
  receiveMaximum: number = 65535;
  maximumPacketSize: number = 268435460;
  topicAliasMaximum: number = 0;
  maximumQos: MqttQoS = MqttQoS.EXACTLY_ONCE;
  retainAvailable: boolean = true;
  wildcardSubscriptionsAvailable: boolean = true;
  subscriptionIdentifiersAvailable: boolean = true;
  sharedSubscriptionsAvailable: boolean = true;
  serverKeepAliveSeconds: number = -1;
}

export enum MqttOutgoingState {
  WAIT_PUBACK = 'wait_puback',
  WAIT_PUBREC = 'wait_pubrec',
  WAIT_PUBCOMP = 'wait_pubcomp'
}

export class MqttOutgoingRecord {
  readonly packetId: number;
  readonly publish: MqttPublishPacket;
  state: MqttOutgoingState;

  constructor(packetId: number, publish: MqttPublishPacket, state: MqttOutgoingState) {
    this.packetId = packetId; this.publish = publish; this.state = state;
  }
}

export interface MqttSessionStore {
  putOutgoing(record: MqttOutgoingRecord): void;
  getOutgoing(packetId: number): MqttOutgoingRecord | undefined;
  removeOutgoing(packetId: number): MqttOutgoingRecord | undefined;
  listOutgoing(): MqttOutgoingRecord[];
  putIncoming(packet: MqttDecodedPacket): void;
  getIncoming(packetId: number): MqttDecodedPacket | undefined;
  removeIncoming(packetId: number): MqttDecodedPacket | undefined;
  clear(): void;
}

export class MemoryMqttSessionStore implements MqttSessionStore {
  private readonly outgoing: Map<number, MqttOutgoingRecord> = new Map<number, MqttOutgoingRecord>();
  private readonly incoming: Map<number, MqttDecodedPacket> = new Map<number, MqttDecodedPacket>();
  putOutgoing(record: MqttOutgoingRecord): void { this.outgoing.set(record.packetId, record); }
  getOutgoing(packetId: number): MqttOutgoingRecord | undefined { return this.outgoing.get(packetId); }
  removeOutgoing(packetId: number): MqttOutgoingRecord | undefined {
    const record: MqttOutgoingRecord | undefined = this.outgoing.get(packetId); this.outgoing.delete(packetId); return record;
  }
  listOutgoing(): MqttOutgoingRecord[] { return Array.from(this.outgoing.values()); }
  putIncoming(packet: MqttDecodedPacket): void { this.incoming.set(packet.packetId, packet); }
  getIncoming(packetId: number): MqttDecodedPacket | undefined { return this.incoming.get(packetId); }
  removeIncoming(packetId: number): MqttDecodedPacket | undefined {
    const packet: MqttDecodedPacket | undefined = this.incoming.get(packetId); this.incoming.delete(packetId); return packet;
  }
  clear(): void { this.outgoing.clear(); this.incoming.clear(); }
}

export class MqttClientOptions {
  readonly connect: MqttConnectOptions;
  scheduler: WsScheduler = new SystemWsScheduler();
  sessionStore: MqttSessionStore = new MemoryMqttSessionStore();
  acknowledgementTimeoutMs: number = 30000;
  resubscribeWhenSessionPresent: boolean = false;
  authenticationHandler?: MqttAuthenticationHandler;
  autoAssignTopicAliases: boolean = false;
  maxFlowControlledPublishes: number = 1000;

  constructor(connect: MqttConnectOptions) { this.connect = connect; }
}

export class MqttMessage {
  readonly topic: string;
  readonly payload: ArrayBuffer;
  readonly qos: MqttQoS;
  readonly retain: boolean;
  readonly duplicate: boolean;
  readonly properties: MqttProperty[];

  constructor(packet: MqttDecodedPacket) {
    this.topic = packet.topic; this.payload = packet.payload; this.qos = packet.qos;
    this.retain = packet.retain; this.duplicate = packet.duplicate; this.properties = packet.properties;
  }
}

export type MqttMessageHandler = (message: MqttMessage) => void;

export class MqttClientObserver {
  readonly onStateChange: (state: MqttClientState) => void;
  readonly onConnect: (sessionPresent: boolean, properties: MqttProperty[]) => void;
  readonly onMessage: (message: MqttMessage) => void;
  readonly onDisconnect: (reasonCode: number, properties: MqttProperty[]) => void;
  readonly onError: (error: Error) => void;

  constructor(onStateChange: (state: MqttClientState) => void = (_state: MqttClientState): void => {},
    onConnect: (sessionPresent: boolean, properties: MqttProperty[]) => void =
      (_sessionPresent: boolean, _properties: MqttProperty[]): void => {},
    onMessage: (message: MqttMessage) => void = (_message: MqttMessage): void => {},
    onDisconnect: (reasonCode: number, properties: MqttProperty[]) => void =
      (_reasonCode: number, _properties: MqttProperty[]): void => {},
    onError: (error: Error) => void = (_error: Error): void => {}) {
    this.onStateChange = onStateChange; this.onConnect = onConnect; this.onMessage = onMessage;
    this.onDisconnect = onDisconnect; this.onError = onError;
  }
}

class MqttSubscriptionRecord {
  readonly subscription: MqttSubscription;
  readonly handler: MqttMessageHandler;
  constructor(subscription: MqttSubscription, handler: MqttMessageHandler) {
    this.subscription = subscription; this.handler = handler;
  }
}

class PendingMqttOperation {
  readonly packetId: number;
  readonly resolve: (reasonCodes: number[]) => void;
  readonly reject: (error: Error) => void;
  timer: number = -1;
  constructor(packetId: number, resolve: (reasonCodes: number[]) => void, reject: (error: Error) => void) {
    this.packetId = packetId; this.resolve = resolve; this.reject = reject;
  }
}

class PendingMqttPublish {
  readonly resolve: () => void;
  readonly reject: (error: Error) => void;
  timer: number = -1;
  sent: boolean = false;
  constructor(resolve: () => void, reject: (error: Error) => void) { this.resolve = resolve; this.reject = reject; }
}

export class MqttClient {
  private readonly socket: HmWebSocketClient;
  private readonly options: MqttClientOptions;
  private readonly observer: MqttClientObserver;
  private readonly codec: MqttCodec = new MqttCodec();
  private readonly decoder: MqttPacketDecoder;
  private readonly rawObserver: WsClientObserver;
  private readonly subscriptions: Map<string, MqttSubscriptionRecord> = new Map<string, MqttSubscriptionRecord>();
  private readonly pendingOperations: Map<number, PendingMqttOperation> = new Map<number, PendingMqttOperation>();
  private readonly pendingPublishes: Map<number, PendingMqttPublish> = new Map<number, PendingMqttPublish>();
  private readonly outgoingInflight: Set<number> = new Set<number>();
  private readonly queuedOutgoing: number[] = [];
  private readonly incomingQos2: Set<number> = new Set<number>();
  private readonly incomingAliases: Map<number, string> = new Map<number, string>();
  private readonly outgoingAliases: Map<string, number> = new Map<string, number>();
  private readonly registeredOutgoingAliases: Set<number> = new Set<number>();
  private capabilitiesValue: MqttV5Capabilities = new MqttV5Capabilities();
  private nextTopicAlias: number = 1;
  private stateValue: MqttClientState = MqttClientState.IDLE;
  private nextPacketId: number = 1;
  private keepAliveTimer: number = -1;
  private pingTimeoutTimer: number = -1;
  private lastActivityAt: number = 0;
  private active: boolean = false;

  constructor(socket: HmWebSocketClient, options: MqttClientOptions,
    observer: MqttClientObserver = new MqttClientObserver()) {
    this.socket = socket; this.options = options; this.observer = observer;
    this.decoder = new MqttPacketDecoder(options.connect.protocolVersion);
    const incomingMaximum: number = this.propertyNumber(options.connect.properties,
      MqttPropertyId.MAXIMUM_PACKET_SIZE, 268435460);
    this.decoder.setMaximumPacketSize(incomingMaximum);
    this.rawObserver = new WsClientObserver(
      (state: WsState, _previous: WsState): void => this.handleSocketState(state),
      (): void => this.handleSocketOpen(),
      (data: WsData): void => this.handleData(data),
      undefined,
      (error: WsError): void => this.fail(new Error(error.message))
    );
    this.socket.addObserver(this.rawObserver);
  }

  state(): MqttClientState { return this.stateValue; }
  capabilities(): MqttV5Capabilities { return this.capabilitiesValue; }

  async connect(): Promise<void> {
    if (this.active) return;
    this.active = true; this.changeState(MqttClientState.CONNECTING); await this.socket.connect();
  }

  async disconnect(reasonCode: number = 0, properties: MqttProperty[] = []): Promise<void> {
    if (!this.active) return;
    this.changeState(MqttClientState.DISCONNECTING); this.cancelKeepAlive();
    if (this.stateValue === MqttClientState.CONNECTED || this.socket.state() === WsState.OPEN) {
      try { await this.sendRaw(this.codec.encodeDisconnect(this.options.connect.protocolVersion,
        reasonCode, properties)); } catch (_error) {}
    }
    this.active = false; this.rejectPending(new Error('MQTT client disconnected'));
    await this.socket.close(1000, 'MQTT client disconnected'); this.changeState(MqttClientState.CLOSED);
  }

  publish(topic: string, payload: ArrayBuffer, qos: MqttQoS = MqttQoS.AT_MOST_ONCE,
    retain: boolean = false, properties: MqttProperty[] = []): Promise<void> {
    this.requireConnected();
    const packet: MqttPublishPacket = new MqttPublishPacket(topic, payload);
    packet.qos = qos; packet.retain = retain; packet.properties = [...properties];
    this.validatePublishAgainstCapabilities(packet);
    if (qos === MqttQoS.AT_MOST_ONCE) {
      return this.sendChecked(this.codec.encodePublish(this.preparePublish(packet), this.options.connect.protocolVersion));
    }
    packet.packetId = this.allocatePacketId();
    const state: MqttOutgoingState = qos === MqttQoS.AT_LEAST_ONCE ?
      MqttOutgoingState.WAIT_PUBACK : MqttOutgoingState.WAIT_PUBREC;
    this.options.sessionStore.putOutgoing(new MqttOutgoingRecord(packet.packetId, packet, state));
    return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      const pending: PendingMqttPublish = new PendingMqttPublish(resolve, reject);
      this.pendingPublishes.set(packet.packetId, pending);
      if (this.queuedOutgoing.length >= this.options.maxFlowControlledPublishes) {
        this.pendingPublishes.delete(packet.packetId); this.options.sessionStore.removeOutgoing(packet.packetId);
        reject(new Error('MQTT 流控等待队列已满')); return;
      }
      this.dispatchOrQueue(packet.packetId);
    });
  }

  async reauthenticate(properties: MqttProperty[]): Promise<void> {
    this.requireConnected();
    if (this.options.connect.protocolVersion !== MqttProtocolVersion.V5) {
      throw new Error('MQTT 重新认证仅适用于 MQTT 5');
    }
    await this.sendChecked(this.codec.encodeAuth(0x19, properties));
    this.changeState(MqttClientState.AUTHENTICATING);
  }

  subscribe(subscription: MqttSubscription, handler: MqttMessageHandler,
    properties: MqttProperty[] = []): Promise<number[]> {
    this.requireConnected();
    this.validateSubscription(subscription);
    const packetId: number = this.allocatePacketId();
    this.subscriptions.set(subscription.topicFilter, new MqttSubscriptionRecord(subscription, handler));
    return this.pendingOperation(packetId, this.codec.encodeSubscribe(packetId, [subscription],
      this.options.connect.protocolVersion, properties));
  }

  unsubscribe(topicFilter: string, properties: MqttProperty[] = []): Promise<number[]> {
    this.requireConnected();
    const packetId: number = this.allocatePacketId();
    this.subscriptions.delete(topicFilter);
    return this.pendingOperation(packetId, this.codec.encodeUnsubscribe(packetId, [topicFilter],
      this.options.connect.protocolVersion, properties));
  }

  dispose(): void { this.cancelKeepAlive(); this.socket.removeObserver(this.rawObserver); }

  static matchesTopic(filter: string, topic: string): boolean {
    const filterLevels: string[] = filter.split('/'); const topicLevels: string[] = topic.split('/');
    for (let i: number = 0; i < filterLevels.length; i++) {
      if (filterLevels[i] === '#') return i === filterLevels.length - 1;
      if (i >= topicLevels.length) return false;
      if (filterLevels[i] !== '+' && filterLevels[i] !== topicLevels[i]) return false;
    }
    return filterLevels.length === topicLevels.length;
  }

  private handleSocketState(state: WsState): void {
    if (!this.active) return;
    if (state === WsState.CONNECTING || state === WsState.RECONNECT_WAIT || state === WsState.OFFLINE_WAIT) {
      this.cancelKeepAlive(); this.decoder.reset(); this.resetNegotiatedState();
      this.changeState(MqttClientState.CONNECTING);
    }
  }

  private handleSocketOpen(): void {
    if (!this.active) return;
    this.changeState(MqttClientState.CONNECTING); this.lastActivityAt = this.options.scheduler.now();
    this.sendRaw(this.codec.encodeConnect(this.options.connect)).catch((error: Object): void => this.fail(
      error instanceof Error ? error : new Error('MQTT CONNECT 发送失败')));
  }

  private handleData(data: WsData): void {
    try {
      const packets: MqttDecodedPacket[] = this.decoder.push(data);
      this.lastActivityAt = this.options.scheduler.now();
      for (let i: number = 0; i < packets.length; i++) this.handlePacket(packets[i]);
    } catch (error) { this.fail(error instanceof Error ? error : new Error('MQTT packet 解析失败')); }
  }

  private handlePacket(packet: MqttDecodedPacket): void {
    if (packet.type === MqttPacketType.CONNACK) {
      if (packet.reasonCode !== 0) {
        this.fail(new Error(`MQTT CONNACK rejected: ${packet.reasonCode}`)); return;
      }
      this.applyCapabilities(packet.properties);
      this.changeState(MqttClientState.CONNECTED); this.observer.onConnect(packet.sessionPresent, packet.properties);
      this.startKeepAlive(); this.restoreSession(packet.sessionPresent); return;
    }
    if (packet.type === MqttPacketType.AUTH) { this.handleAuth(packet); return; }
    if (packet.type === MqttPacketType.PUBLISH) { this.handlePublish(packet); return; }
    if (packet.type === MqttPacketType.PUBACK) {
      if (packet.reasonCode >= 0x80) this.failOutgoing(packet.packetId, packet.reasonCode);
      else this.completeOutgoing(packet.packetId);
      return;
    }
    if (packet.type === MqttPacketType.PUBREC) {
      if (packet.reasonCode >= 0x80) { this.failOutgoing(packet.packetId, packet.reasonCode); return; }
      const record: MqttOutgoingRecord | undefined = this.options.sessionStore.getOutgoing(packet.packetId);
      if (record !== undefined) {
        record.state = MqttOutgoingState.WAIT_PUBCOMP; this.options.sessionStore.putOutgoing(record);
        this.sendChecked(this.codec.encodeAck(MqttPacketType.PUBREL, packet.packetId,
          this.options.connect.protocolVersion)).catch((error: Object): void => this.fail(
          error instanceof Error ? error : new Error('MQTT PUBREL 发送失败')));
      }
      return;
    }
    if (packet.type === MqttPacketType.PUBREL) {
      const incoming: MqttDecodedPacket | undefined = this.options.sessionStore.removeIncoming(packet.packetId);
      this.incomingQos2.delete(packet.packetId);
      if (incoming !== undefined) this.deliver(incoming);
      this.sendChecked(this.codec.encodeAck(MqttPacketType.PUBCOMP, packet.packetId,
        this.options.connect.protocolVersion)).catch((error: Object): void => this.fail(
        error instanceof Error ? error : new Error('MQTT PUBCOMP 发送失败')));
      return;
    }
    if (packet.type === MqttPacketType.PUBCOMP) {
      if (packet.reasonCode >= 0x80) this.failOutgoing(packet.packetId, packet.reasonCode);
      else this.completeOutgoing(packet.packetId);
      return;
    }
    if (packet.type === MqttPacketType.SUBACK || packet.type === MqttPacketType.UNSUBACK) {
      const pending: PendingMqttOperation | undefined = this.pendingOperations.get(packet.packetId);
      if (pending !== undefined) {
        this.pendingOperations.delete(packet.packetId); this.options.scheduler.cancel(pending.timer);
        pending.resolve(packet.reasonCodes);
      }
      return;
    }
    if (packet.type === MqttPacketType.PINGRESP) {
      if (this.pingTimeoutTimer >= 0) this.options.scheduler.cancel(this.pingTimeoutTimer);
      this.pingTimeoutTimer = -1; this.startKeepAlive(); return;
    }
    if (packet.type === MqttPacketType.DISCONNECT) {
      this.observer.onDisconnect(packet.reasonCode, packet.properties);
      this.socket.reconnect(4002, `MQTT disconnect ${packet.reasonCode}`).catch((_error: Object): void => {});
    }
  }

  private handlePublish(packet: MqttDecodedPacket): void {
    if (this.options.connect.protocolVersion === MqttProtocolVersion.V5 && !this.resolveIncomingAlias(packet)) return;
    if (packet.qos === MqttQoS.AT_MOST_ONCE) { this.deliver(packet); return; }
    if (packet.qos === MqttQoS.AT_LEAST_ONCE) {
      this.deliver(packet);
      this.sendChecked(this.codec.encodeAck(MqttPacketType.PUBACK, packet.packetId,
        this.options.connect.protocolVersion)).catch((error: Object): void => this.fail(
        error instanceof Error ? error : new Error('MQTT PUBACK 发送失败')));
      return;
    }
    if (this.options.sessionStore.getIncoming(packet.packetId) === undefined) {
      const receiveMaximum: number = this.propertyNumber(this.options.connect.properties,
        MqttPropertyId.RECEIVE_MAXIMUM, 65535);
      if (this.incomingQos2.size >= receiveMaximum) {
        this.protocolError(0x93, 'MQTT Receive Maximum exceeded'); return;
      }
      this.incomingQos2.add(packet.packetId);
      this.options.sessionStore.putIncoming(packet);
    }
    this.sendChecked(this.codec.encodeAck(MqttPacketType.PUBREC, packet.packetId,
      this.options.connect.protocolVersion)).catch((error: Object): void => this.fail(
      error instanceof Error ? error : new Error('MQTT PUBREC 发送失败')));
  }

  private deliver(packet: MqttDecodedPacket): void {
    const message: MqttMessage = new MqttMessage(packet); this.observer.onMessage(message);
    const records: MqttSubscriptionRecord[] = Array.from(this.subscriptions.values());
    for (let i: number = 0; i < records.length; i++) {
      if (MqttClient.matchesTopic(records[i].subscription.topicFilter, packet.topic)) records[i].handler(message);
    }
  }

  private completeOutgoing(packetId: number): void {
    this.options.sessionStore.removeOutgoing(packetId);
    this.outgoingInflight.delete(packetId);
    const pending: PendingMqttPublish | undefined = this.pendingPublishes.get(packetId);
    if (pending !== undefined) {
      this.pendingPublishes.delete(packetId); this.options.scheduler.cancel(pending.timer); pending.resolve();
    }
    this.drainOutgoing();
  }

  private restoreSession(sessionPresent: boolean): void {
    const outgoing: MqttOutgoingRecord[] = this.options.sessionStore.listOutgoing();
    for (let i: number = 0; i < outgoing.length; i++) {
      const record: MqttOutgoingRecord = outgoing[i];
      if (record.state === MqttOutgoingState.WAIT_PUBCOMP) {
        if (this.outgoingInflight.size < this.capabilitiesValue.receiveMaximum) {
          this.outgoingInflight.add(record.packetId);
          this.sendChecked(this.codec.encodeAck(MqttPacketType.PUBREL, record.packetId,
            this.options.connect.protocolVersion)).catch((_error: Object): void => {});
        } else this.queuedOutgoing.push(record.packetId);
      } else {
        record.publish.duplicate = true;
        this.dispatchOrQueue(record.packetId);
      }
    }
    if (!sessionPresent || this.options.resubscribeWhenSessionPresent) {
      const records: MqttSubscriptionRecord[] = Array.from(this.subscriptions.values());
      for (let i: number = 0; i < records.length; i++) {
        const packetId: number = this.allocatePacketId();
        this.sendChecked(this.codec.encodeSubscribe(packetId, [records[i].subscription],
          this.options.connect.protocolVersion)).catch((_error: Object): void => {});
      }
    }
  }

  private pendingOperation(packetId: number, data: ArrayBuffer): Promise<number[]> {
    return new Promise<number[]>((resolve: (codes: number[]) => void, reject: (error: Error) => void): void => {
      const pending: PendingMqttOperation = new PendingMqttOperation(packetId, resolve, reject);
      this.pendingOperations.set(packetId, pending);
      pending.timer = this.options.scheduler.schedule(this.options.acknowledgementTimeoutMs, (): void => {
        this.pendingOperations.delete(packetId); reject(new Error(`MQTT acknowledgement timeout: ${packetId}`));
      });
      this.sendChecked(data).catch((error: Object): void => {
        this.pendingOperations.delete(packetId); this.options.scheduler.cancel(pending.timer);
        reject(error instanceof Error ? error : new Error('MQTT operation 发送失败'));
      });
    });
  }

  private armPublishTimeout(packetId: number, pending: PendingMqttPublish): void {
    pending.timer = this.options.scheduler.schedule(this.options.acknowledgementTimeoutMs, (): void => {
      this.pendingPublishes.delete(packetId);
      pending.reject(new Error(`MQTT publish acknowledgement timeout: ${packetId}`));
    });
  }

  private startKeepAlive(): void {
    this.cancelKeepAlive();
    const keepAliveSeconds: number = this.capabilitiesValue.serverKeepAliveSeconds >= 0 ?
      this.capabilitiesValue.serverKeepAliveSeconds : this.options.connect.keepAliveSeconds;
    if (keepAliveSeconds <= 0 || this.stateValue !== MqttClientState.CONNECTED) return;
    const interval: number = keepAliveSeconds * 1000;
    this.keepAliveTimer = this.options.scheduler.schedule(interval, (): void => {
      this.keepAliveTimer = -1;
      if (this.options.scheduler.now() - this.lastActivityAt < interval) { this.startKeepAlive(); return; }
      this.sendRaw(this.codec.encodePingRequest()).then((): void => {
        this.pingTimeoutTimer = this.options.scheduler.schedule(Math.floor(interval * 1.5), (): void => {
          this.pingTimeoutTimer = -1; this.fail(new Error('MQTT PINGRESP timeout'));
          this.socket.reconnect(4000, 'MQTT keepalive timeout').catch((_error: Object): void => {});
        });
      }).catch((error: Object): void => this.fail(
        error instanceof Error ? error : new Error('MQTT PINGREQ 发送失败')));
    });
  }

  private cancelKeepAlive(): void {
    if (this.keepAliveTimer >= 0) this.options.scheduler.cancel(this.keepAliveTimer);
    if (this.pingTimeoutTimer >= 0) this.options.scheduler.cancel(this.pingTimeoutTimer);
    this.keepAliveTimer = -1; this.pingTimeoutTimer = -1;
  }

  private async sendRaw(data: ArrayBuffer): Promise<void> {
    await this.socket.send(data); this.lastActivityAt = this.options.scheduler.now();
  }

  private async sendChecked(data: ArrayBuffer): Promise<void> {
    if (data.byteLength > this.capabilitiesValue.maximumPacketSize) {
      throw new Error(`MQTT packet 超过服务端 Maximum Packet Size：${data.byteLength}`);
    }
    await this.sendRaw(data);
  }

  private applyCapabilities(properties: MqttProperty[]): void {
    const capabilities: MqttV5Capabilities = new MqttV5Capabilities();
    if (this.options.connect.protocolVersion === MqttProtocolVersion.V5) {
      capabilities.receiveMaximum = this.propertyNumber(properties, MqttPropertyId.RECEIVE_MAXIMUM, 65535);
      capabilities.maximumPacketSize = this.propertyNumber(properties, MqttPropertyId.MAXIMUM_PACKET_SIZE, 268435460);
      capabilities.topicAliasMaximum = this.propertyNumber(properties, MqttPropertyId.TOPIC_ALIAS_MAXIMUM, 0);
      capabilities.maximumQos = this.propertyNumber(properties, MqttPropertyId.MAXIMUM_QOS,
        MqttQoS.EXACTLY_ONCE) as MqttQoS;
      capabilities.retainAvailable = this.propertyNumber(properties, MqttPropertyId.RETAIN_AVAILABLE, 1) !== 0;
      capabilities.wildcardSubscriptionsAvailable = this.propertyNumber(properties,
        MqttPropertyId.WILDCARD_SUBSCRIPTION_AVAILABLE, 1) !== 0;
      capabilities.subscriptionIdentifiersAvailable = this.propertyNumber(properties,
        MqttPropertyId.SUBSCRIPTION_IDENTIFIERS_AVAILABLE, 1) !== 0;
      capabilities.sharedSubscriptionsAvailable = this.propertyNumber(properties,
        MqttPropertyId.SHARED_SUBSCRIPTION_AVAILABLE, 1) !== 0;
      capabilities.serverKeepAliveSeconds = this.propertyNumber(properties,
        MqttPropertyId.SERVER_KEEP_ALIVE, -1);
      if (capabilities.receiveMaximum <= 0 || capabilities.maximumPacketSize <= 0 ||
        capabilities.maximumQos > MqttQoS.EXACTLY_ONCE) {
        throw new Error('MQTT 5 CONNACK capabilities 非法');
      }
    }
    this.capabilitiesValue = capabilities;
  }

  private validatePublishAgainstCapabilities(packet: MqttPublishPacket): void {
    if (packet.qos > this.capabilitiesValue.maximumQos) throw new Error('PUBLISH QoS 超过服务端 Maximum QoS');
    if (packet.retain && !this.capabilitiesValue.retainAvailable) throw new Error('服务端不支持 retained message');
    const alias: MqttProperty | undefined = this.findProperty(packet.properties, MqttPropertyId.TOPIC_ALIAS);
    if (alias !== undefined && (alias.numberValue <= 0 ||
      alias.numberValue > this.capabilitiesValue.topicAliasMaximum)) {
      throw new Error('PUBLISH Topic Alias 超过服务端上限');
    }
  }

  private validateSubscription(subscription: MqttSubscription): void {
    if (subscription.qos > this.capabilitiesValue.maximumQos) throw new Error('订阅 QoS 超过服务端 Maximum QoS');
    if (!this.capabilitiesValue.wildcardSubscriptionsAvailable &&
      (subscription.topicFilter.indexOf('+') >= 0 || subscription.topicFilter.indexOf('#') >= 0)) {
      throw new Error('服务端不支持 wildcard subscription');
    }
    if (!this.capabilitiesValue.sharedSubscriptionsAvailable && subscription.topicFilter.startsWith('$share/')) {
      throw new Error('服务端不支持 shared subscription');
    }
  }

  private preparePublish(source: MqttPublishPacket): MqttPublishPacket {
    const packet: MqttPublishPacket = new MqttPublishPacket(source.topic, source.payload);
    packet.qos = source.qos; packet.retain = source.retain; packet.duplicate = source.duplicate;
    packet.packetId = source.packetId; packet.properties = [...source.properties];
    if (this.options.connect.protocolVersion !== MqttProtocolVersion.V5 ||
      !this.options.autoAssignTopicAliases || this.capabilitiesValue.topicAliasMaximum <= 0 ||
      this.findProperty(packet.properties, MqttPropertyId.TOPIC_ALIAS) !== undefined) return packet;
    let alias: number = this.outgoingAliases.get(source.topic) ?? 0;
    if (alias === 0 && this.nextTopicAlias <= this.capabilitiesValue.topicAliasMaximum) {
      alias = this.nextTopicAlias++; this.outgoingAliases.set(source.topic, alias);
    }
    if (alias > 0) {
      packet.properties.push(MqttProperty.number(MqttPropertyId.TOPIC_ALIAS, MqttPropertyType.UINT16, alias));
      if (this.registeredOutgoingAliases.has(alias)) packet.topic = '';
      else this.registeredOutgoingAliases.add(alias);
    }
    return packet;
  }

  private resolveIncomingAlias(packet: MqttDecodedPacket): boolean {
    const aliasProperty: MqttProperty | undefined = this.findProperty(packet.properties, MqttPropertyId.TOPIC_ALIAS);
    if (aliasProperty === undefined) {
      if (packet.topic.length === 0) { this.protocolError(0x82, 'PUBLISH topic 和 Topic Alias 均为空'); return false; }
      return true;
    }
    const maximum: number = this.propertyNumber(this.options.connect.properties,
      MqttPropertyId.TOPIC_ALIAS_MAXIMUM, 0);
    const alias: number = aliasProperty.numberValue;
    if (alias <= 0 || alias > maximum) { this.protocolError(0x94, '收到非法 Topic Alias'); return false; }
    if (packet.topic.length > 0) this.incomingAliases.set(alias, packet.topic);
    else {
      const resolved: string | undefined = this.incomingAliases.get(alias);
      if (resolved === undefined) { this.protocolError(0x82, 'Topic Alias 尚未注册'); return false; }
      packet.topic = resolved;
    }
    return true;
  }

  private dispatchOrQueue(packetId: number): void {
    if (this.outgoingInflight.has(packetId) || this.queuedOutgoing.indexOf(packetId) >= 0) return;
    if (this.outgoingInflight.size >= this.capabilitiesValue.receiveMaximum) {
      this.queuedOutgoing.push(packetId); return;
    }
    const record: MqttOutgoingRecord | undefined = this.options.sessionStore.getOutgoing(packetId);
    if (record === undefined) return;
    this.outgoingInflight.add(packetId);
    const pending: PendingMqttPublish | undefined = this.pendingPublishes.get(packetId);
    if (pending !== undefined) { pending.sent = true; this.armPublishTimeout(packetId, pending); }
    const data: ArrayBuffer = record.state === MqttOutgoingState.WAIT_PUBCOMP ?
      this.codec.encodeAck(MqttPacketType.PUBREL, packetId, this.options.connect.protocolVersion) :
      this.codec.encodePublish(this.preparePublish(record.publish), this.options.connect.protocolVersion);
    this.sendChecked(data).catch((error: Object): void => {
      this.failOutgoingError(packetId, error instanceof Error ? error : new Error('MQTT PUBLISH 发送失败'));
    });
  }

  private drainOutgoing(): void {
    while (this.outgoingInflight.size < this.capabilitiesValue.receiveMaximum && this.queuedOutgoing.length > 0) {
      const packetId: number | undefined = this.queuedOutgoing.shift();
      if (packetId !== undefined) this.dispatchOrQueue(packetId);
    }
  }

  private failOutgoing(packetId: number, reasonCode: number): void {
    this.failOutgoingError(packetId, new Error(`MQTT publish rejected: ${reasonCode}`));
  }

  private failOutgoingError(packetId: number, error: Error): void {
    this.options.sessionStore.removeOutgoing(packetId); this.outgoingInflight.delete(packetId);
    const pending: PendingMqttPublish | undefined = this.pendingPublishes.get(packetId);
    if (pending !== undefined) {
      this.pendingPublishes.delete(packetId); this.options.scheduler.cancel(pending.timer); pending.reject(error);
    }
    this.drainOutgoing();
  }

  private handleAuth(packet: MqttDecodedPacket): void {
    if (this.options.connect.protocolVersion !== MqttProtocolVersion.V5) {
      this.protocolError(0x82, 'MQTT 3.1.1 不支持 AUTH'); return;
    }
    const handler: MqttAuthenticationHandler | undefined = this.options.authenticationHandler;
    if (handler === undefined) { this.protocolError(0x8C, '未配置 MQTT enhanced authentication handler'); return; }
    const configuredMethod: string = this.propertyText(this.options.connect.properties,
      MqttPropertyId.AUTHENTICATION_METHOD, '');
    const method: string = this.propertyText(packet.properties, MqttPropertyId.AUTHENTICATION_METHOD,
      configuredMethod);
    if (configuredMethod.length > 0 && method !== configuredMethod) {
      this.protocolError(0x8C, 'MQTT Authentication Method 不一致'); return;
    }
    const data: ArrayBuffer = this.propertyBinary(packet.properties, MqttPropertyId.AUTHENTICATION_DATA);
    this.changeState(MqttClientState.AUTHENTICATING);
    handler.authenticate(packet.reasonCode, method, data, packet.properties).then(
      (response: MqttAuthResponse | undefined): void => {
        if (response === undefined) {
          if (packet.reasonCode === 0) this.changeState(MqttClientState.CONNECTED);
          return;
        }
        this.sendChecked(this.codec.encodeAuth(response.reasonCode, response.properties)).then((): void => {
          if (response.reasonCode === 0) this.changeState(MqttClientState.CONNECTED);
        }).catch((error: Object): void => this.fail(
          error instanceof Error ? error : new Error('MQTT AUTH 发送失败')));
      }).catch((error: Object): void => this.protocolError(0x87,
        error instanceof Error ? error.message : 'MQTT enhanced authentication 失败'));
  }

  private protocolError(reasonCode: number, message: string): void {
    const error: Error = new Error(message); this.fail(error);
    if (this.options.connect.protocolVersion === MqttProtocolVersion.V5 && this.socket.state() === WsState.OPEN) {
      this.sendRaw(this.codec.encodeDisconnect(MqttProtocolVersion.V5, reasonCode)).finally((): void => {
        this.socket.reconnect(4003, message).catch((_error: Object): void => {});
      });
    }
  }

  private resetNegotiatedState(): void {
    this.capabilitiesValue = new MqttV5Capabilities(); this.outgoingInflight.clear();
    this.queuedOutgoing.splice(0, this.queuedOutgoing.length); this.incomingAliases.clear();
    this.outgoingAliases.clear(); this.registeredOutgoingAliases.clear(); this.nextTopicAlias = 1;
    const pending: PendingMqttPublish[] = Array.from(this.pendingPublishes.values());
    for (let i: number = 0; i < pending.length; i++) {
      if (pending[i].timer >= 0) this.options.scheduler.cancel(pending[i].timer);
      pending[i].timer = -1; pending[i].sent = false;
    }
  }

  private findProperty(properties: MqttProperty[], id: number): MqttProperty | undefined {
    for (let i: number = 0; i < properties.length; i++) if (properties[i].id === id) return properties[i];
    return undefined;
  }

  private propertyNumber(properties: MqttProperty[], id: number, fallback: number): number {
    const property: MqttProperty | undefined = this.findProperty(properties, id);
    return property === undefined ? fallback : property.numberValue;
  }

  private propertyText(properties: MqttProperty[], id: number, fallback: string): string {
    const property: MqttProperty | undefined = this.findProperty(properties, id);
    return property === undefined ? fallback : property.stringValue;
  }

  private propertyBinary(properties: MqttProperty[], id: number): ArrayBuffer {
    const property: MqttProperty | undefined = this.findProperty(properties, id);
    return property === undefined ? new ArrayBuffer(0) : property.binaryValue;
  }

  private allocatePacketId(): number {
    for (let count: number = 0; count < 65535; count++) {
      const candidate: number = this.nextPacketId;
      this.nextPacketId = this.nextPacketId >= 65535 ? 1 : this.nextPacketId + 1;
      if (this.options.sessionStore.getOutgoing(candidate) === undefined &&
        !this.pendingOperations.has(candidate)) return candidate;
    }
    throw new Error('MQTT packetId 已耗尽');
  }

  private rejectPending(error: Error): void {
    const operations: PendingMqttOperation[] = Array.from(this.pendingOperations.values());
    this.pendingOperations.clear();
    for (let i: number = 0; i < operations.length; i++) {
      this.options.scheduler.cancel(operations[i].timer); operations[i].reject(error);
    }
    const publishes: PendingMqttPublish[] = Array.from(this.pendingPublishes.values());
    this.pendingPublishes.clear();
    for (let i: number = 0; i < publishes.length; i++) {
      this.options.scheduler.cancel(publishes[i].timer); publishes[i].reject(error);
    }
  }

  private requireConnected(): void {
    if (this.stateValue !== MqttClientState.CONNECTED) throw new Error('MQTT 尚未连接');
  }
  private changeState(state: MqttClientState): void {
    if (this.stateValue === state) return; this.stateValue = state; this.observer.onStateChange(state);
  }
  private fail(error: Error): void { this.changeState(MqttClientState.ERROR); this.observer.onError(error); }
}
