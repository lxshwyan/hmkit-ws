import { describe, expect, it } from '@ohos/hypium';
import { HmWebSocketClient, HmWebSocketClientOptions } from '../main/ets/core/Client';
import { WsScheduler } from '../main/ets/core/Scheduler';
import { WsTransport, WsTransportFactory, WsTransportObserver } from '../main/ets/core/Transport';
import { StaticWsEndpointProvider, WsCloseInfo, WsConnectionOptions, WsData } from '../main/ets/core/Types';
import { MqttClient, MqttClientOptions, MqttClientState, MqttMessage } from '../main/ets/protocol/mqtt/MqttClient';
import { MqttCodec, MqttConnectOptions, MqttDecodedPacket, MqttPacketType, MqttProtocolVersion,
  MqttQoS, MqttSubscription } from '../main/ets/protocol/mqtt/MqttCodec';
import { SocketIoClient, SocketIoClientOptions, SocketIoClientState,
  SocketIoIncomingEvent } from '../main/ets/protocol/socketio/SocketIoClient';
import { StompAckMode, StompClient, StompClientOptions, StompClientState,
  StompMessage } from '../main/ets/protocol/stomp/StompClient';
import { StompCodec, StompCommand, StompFrame } from '../main/ets/protocol/stomp/StompCodec';

class ProtocolTimer {
  readonly id: number; readonly at: number; readonly callback: () => void; cancelled: boolean = false;
  constructor(id: number, at: number, callback: () => void) { this.id = id; this.at = at; this.callback = callback; }
}

class ProtocolScheduler implements WsScheduler {
  private time: number = 0; private nextId: number = 1; private readonly timers: ProtocolTimer[] = [];
  now(): number { return this.time; }
  schedule(delayMs: number, callback: () => void): number {
    const timer: ProtocolTimer = new ProtocolTimer(this.nextId++, this.time + delayMs, callback);
    this.timers.push(timer); return timer.id;
  }
  cancel(id: number): void {
    for (let i: number = 0; i < this.timers.length; i++) if (this.timers[i].id === id) this.timers[i].cancelled = true;
  }
}

class ProtocolTransport implements WsTransport {
  observer: WsTransportObserver = new WsTransportObserver(); readonly sent: WsData[] = [];
  setObserver(observer: WsTransportObserver): void { this.observer = observer; }
  connect(_url: string, _options: WsConnectionOptions): Promise<void> {
    this.observer.onOpen(); return Promise.resolve();
  }
  send(data: WsData): Promise<void> { this.sent.push(data); return Promise.resolve(); }
  close(code: number = 1000, reason: string = ''): Promise<void> {
    this.observer.onClose(new WsCloseInfo(code, reason, code === 1000)); return Promise.resolve();
  }
  receive(data: WsData): void { this.observer.onMessage(data); }
}

class ProtocolTransportFactory implements WsTransportFactory {
  readonly transport: ProtocolTransport = new ProtocolTransport();
  create(): WsTransport { return this.transport; }
}

function createSocket(factory: ProtocolTransportFactory, scheduler: ProtocolScheduler): HmWebSocketClient {
  const options: HmWebSocketClientOptions = new HmWebSocketClientOptions(); options.scheduler = scheduler;
  return new HmWebSocketClient(new StaticWsEndpointProvider('ws://test'), factory, options);
}

function bufferOf(values: number[]): ArrayBuffer {
  const buffer: ArrayBuffer = new ArrayBuffer(values.length); new Uint8Array(buffer).set(values); return buffer;
}

async function waitForSent(transport: ProtocolTransport, count: number): Promise<void> {
  for (let i: number = 0; i < 8 && transport.sent.length < count; i++) await Promise.resolve();
}

export default function protocolClientsTest(): void {
  describe('protocol clients', (): void => {
    it('negotiates STOMP and routes subscription messages', 0, async (): Promise<void> => {
      const factory: ProtocolTransportFactory = new ProtocolTransportFactory();
      const scheduler: ProtocolScheduler = new ProtocolScheduler();
      const stompOptions: StompClientOptions = new StompClientOptions(); stompOptions.scheduler = scheduler;
      stompOptions.heartbeatIncomingMs = 0; stompOptions.heartbeatOutgoingMs = 0;
      const client: StompClient = new StompClient(createSocket(factory, scheduler), stompOptions);
      await client.activate(); await Promise.resolve();
      expect(typeof factory.transport.sent[0] === 'string').assertTrue();
      const connectedHeaders: Record<string, string> = { 'version': '1.2', 'heart-beat': '0,0' };
      factory.transport.receive(new StompCodec().encode(
        new StompFrame(StompCommand.CONNECTED, connectedHeaders)));
      expect(client.state()).assertEqual(StompClientState.CONNECTED);
      const bodies: string[] = [];
      await client.subscribe('/queue/a', (message: StompMessage): void => {
        if (typeof message.frame.body === 'string') bodies.push(message.frame.body);
      }, StompAckMode.CLIENT_INDIVIDUAL);
      const messageHeaders: Record<string, string> = {
        'subscription': 'hmkit-sub-1', 'message-id': 'm1', 'ack': 'a1', 'destination': '/queue/a'
      };
      factory.transport.receive(new StompCodec().encode(
        new StompFrame(StompCommand.MESSAGE, messageHeaders, 'hello')));
      expect(bodies[0]).assertEqual('hello');
    });

    it('negotiates Socket.IO namespace and routes events', 0, async (): Promise<void> => {
      const factory: ProtocolTransportFactory = new ProtocolTransportFactory();
      const scheduler: ProtocolScheduler = new ProtocolScheduler();
      const options: SocketIoClientOptions = new SocketIoClientOptions(); options.scheduler = scheduler;
      const client: SocketIoClient = new SocketIoClient(createSocket(factory, scheduler), options);
      const values: string[] = [];
      client.on('chat', (event: SocketIoIncomingEvent): void => { values.push(event.argumentsJson); });
      await client.connect();
      factory.transport.receive('0{"sid":"s1","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000}');
      await Promise.resolve();
      expect(factory.transport.sent[0]).assertEqual('40{}');
      factory.transport.receive('40{"sid":"n1"}');
      expect(client.state()).assertEqual(SocketIoClientState.CONNECTED);
      factory.transport.receive('42["chat","hello"]');
      expect(values[0]).assertEqual('["hello"]');
    });

    it('completes MQTT QoS1 publish acknowledgement', 0, async (): Promise<void> => {
      const factory: ProtocolTransportFactory = new ProtocolTransportFactory();
      const scheduler: ProtocolScheduler = new ProtocolScheduler();
      const connect: MqttConnectOptions = new MqttConnectOptions('client');
      const options: MqttClientOptions = new MqttClientOptions(connect); options.scheduler = scheduler;
      const client: MqttClient = new MqttClient(createSocket(factory, scheduler), options);
      await client.connect();
      factory.transport.receive(bufferOf([0x20, 0x02, 0x00, 0x00]));
      expect(client.state()).assertEqual(MqttClientState.CONNECTED);
      const promise: Promise<void> = client.publish('a/b', bufferOf([1]), MqttQoS.AT_LEAST_ONCE);
      await waitForSent(factory.transport, 2);
      const sent: WsData = factory.transport.sent[1];
      expect(typeof sent === 'string').assertFalse();
      if (typeof sent !== 'string') {
        const publish: MqttDecodedPacket = new MqttCodec().decodePacket(new Uint8Array(sent),
          MqttProtocolVersion.V3_1_1);
        expect(publish.type).assertEqual(MqttPacketType.PUBLISH);
        factory.transport.receive(bufferOf([0x40, 0x02, (publish.packetId >> 8) & 0xFF, publish.packetId & 0xFF]));
      }
      await promise;
    });

    it('matches MQTT wildcard topic filters', 0, (): void => {
      expect(MqttClient.matchesTopic('devices/+/state', 'devices/a/state')).assertTrue();
      expect(MqttClient.matchesTopic('devices/#', 'devices/a/state')).assertTrue();
      expect(MqttClient.matchesTopic('devices/+/state', 'devices/a/data')).assertFalse();
    });

    it('honors MQTT 5 Receive Maximum for outgoing QoS messages', 0, async (): Promise<void> => {
      const factory: ProtocolTransportFactory = new ProtocolTransportFactory();
      const scheduler: ProtocolScheduler = new ProtocolScheduler();
      const connect: MqttConnectOptions = new MqttConnectOptions('flow-client');
      connect.protocolVersion = MqttProtocolVersion.V5;
      const client: MqttClient = new MqttClient(createSocket(factory, scheduler), new MqttClientOptions(connect));
      await client.connect();
      factory.transport.receive(bufferOf([0x20, 0x06, 0x00, 0x00, 0x03, 0x21, 0x00, 0x01]));
      const firstPromise: Promise<void> = client.publish('flow/one', bufferOf([1]), MqttQoS.AT_LEAST_ONCE);
      const secondPromise: Promise<void> = client.publish('flow/two', bufferOf([2]), MqttQoS.AT_LEAST_ONCE);
      await waitForSent(factory.transport, 2);
      expect(factory.transport.sent.length).assertEqual(2);
      const firstWire: WsData = factory.transport.sent[1];
      if (typeof firstWire !== 'string') {
        const firstPacket: MqttDecodedPacket = new MqttCodec().decodePacket(new Uint8Array(firstWire),
          MqttProtocolVersion.V5);
        factory.transport.receive(bufferOf([0x40, 0x02, (firstPacket.packetId >> 8) & 0xFF,
          firstPacket.packetId & 0xFF]));
      }
      await waitForSent(factory.transport, 3);
      expect(factory.transport.sent.length).assertEqual(3);
      const secondWire: WsData = factory.transport.sent[2];
      if (typeof secondWire !== 'string') {
        const secondPacket: MqttDecodedPacket = new MqttCodec().decodePacket(new Uint8Array(secondWire),
          MqttProtocolVersion.V5);
        factory.transport.receive(bufferOf([0x40, 0x02, (secondPacket.packetId >> 8) & 0xFF,
          secondPacket.packetId & 0xFF]));
      }
      await firstPromise; await secondPromise;
    });
  });
}
