import { describe, expect, it } from '@ohos/hypium';
import { HmWebSocketClient, HmWebSocketClientOptions } from '../main/ets/core/Client';
import { JsonWsCodec } from '../main/ets/core/Codec';
import { WsScheduler } from '../main/ets/core/Scheduler';
import { WsTransport, WsTransportFactory, WsTransportObserver } from '../main/ets/core/Transport';
import { StaticWsEndpointProvider, WsClientObserver, WsCloseInfo, WsConnectionOptions,
  WsData, WsError, WsErrorCode, WsState } from '../main/ets/core/Types';
import { TextHeartbeatStrategy } from '../main/ets/policy/Heartbeat';
import { ExponentialBackoffOptions, ExponentialBackoffPolicy,
  WsReconnectContext } from '../main/ets/policy/Reconnect';
import { MemoryWsOutboundQueue, WsOutboundMessage, WsQueueOptions,
  WsQueueOverflowPolicy } from '../main/ets/policy/Queue';

class ManualTimer {
  readonly id: number;
  readonly at: number;
  readonly callback: () => void;
  cancelled: boolean = false;
  constructor(id: number, at: number, callback: () => void) {
    this.id = id; this.at = at; this.callback = callback;
  }
}

class ManualScheduler implements WsScheduler {
  private time: number = 0;
  private nextId: number = 1;
  private readonly timers: ManualTimer[] = [];
  now(): number { return this.time; }
  schedule(delayMs: number, callback: () => void): number {
    const timer: ManualTimer = new ManualTimer(this.nextId++, this.time + delayMs, callback);
    this.timers.push(timer);
    return timer.id;
  }
  cancel(timerId: number): void {
    for (let i: number = 0; i < this.timers.length; i++) {
      if (this.timers[i].id === timerId) this.timers[i].cancelled = true;
    }
  }
  advance(delayMs: number): void {
    this.time += delayMs;
    let invoked: boolean = true;
    while (invoked) {
      invoked = false;
      for (let i: number = 0; i < this.timers.length; i++) {
        const timer: ManualTimer = this.timers[i];
        if (!timer.cancelled && timer.at <= this.time) {
          timer.cancelled = true;
          timer.callback();
          invoked = true;
        }
      }
    }
  }
}

class MockTransport implements WsTransport {
  observer: WsTransportObserver = new WsTransportObserver();
  readonly sent: WsData[] = [];
  connectError?: WsError;
  autoOpen: boolean = true;
  setObserver(observer: WsTransportObserver): void { this.observer = observer; }
  connect(_url: string, _options: WsConnectionOptions): Promise<void> {
    if (this.connectError !== undefined) return Promise.reject(this.connectError);
    if (this.autoOpen) this.observer.onOpen();
    return Promise.resolve();
  }
  send(data: WsData): Promise<void> { this.sent.push(data); return Promise.resolve(); }
  close(code: number = 1000, reason: string = ''): Promise<void> {
    this.observer.onClose(new WsCloseInfo(code, reason, code === 1000));
    return Promise.resolve();
  }
  emitMessage(data: WsData): void { this.observer.onMessage(data); }
  emitClose(code: number = 1006): void { this.observer.onClose(new WsCloseInfo(code)); }
}

class SerialProbeTransport extends MockTransport {
  readonly completed: WsData[] = [];
  private releaseFirst?: () => void;
  send(data: WsData): Promise<void> {
    this.sent.push(data);
    if (this.sent.length > 1) { this.completed.push(data); return Promise.resolve(); }
    return new Promise<void>((resolve: () => void): void => {
      this.releaseFirst = (): void => { this.completed.push(data); resolve(); };
    });
  }
  release(): void { if (this.releaseFirst !== undefined) this.releaseFirst(); }
}

class SerialProbeFactory implements WsTransportFactory {
  readonly transport: SerialProbeTransport = new SerialProbeTransport();
  create(): WsTransport { return this.transport; }
}

class MockTransportFactory implements WsTransportFactory {
  readonly transports: MockTransport[] = [];
  create(): WsTransport {
    const transport: MockTransport = new MockTransport();
    this.transports.push(transport);
    return transport;
  }
}

class JsonEvent {
  type: string = '';
  value: string = '';
}

export default function coreTest(): void {
  describe('hmkit ws core', (): void => {
    it('calculates bounded full-jitter reconnect delays', 0, (): void => {
      const options: ExponentialBackoffOptions = new ExponentialBackoffOptions();
      options.initialDelayMs = 1000; options.maxDelayMs = 2500; options.multiplier = 2;
      const policy: ExponentialBackoffPolicy = new ExponentialBackoffPolicy(options, (): number => 0.5);
      expect(policy.decide(new WsReconnectContext(1)).delayMs).assertEqual(500);
      expect(policy.decide(new WsReconnectContext(3)).delayMs).assertEqual(1250);
    });

    it('keeps JSON encoding replaceable and typed', 0, (): void => {
      const codec: JsonWsCodec<JsonEvent> = new JsonWsCodec<JsonEvent>((json: string): JsonEvent => {
        return JSON.parse(json) as JsonEvent;
      });
      const event: JsonEvent = new JsonEvent();
      event.type = 'message'; event.value = 'hello';
      const encoded: WsData = codec.encode(event);
      expect(typeof encoded === 'string').assertTrue();
      expect(codec.decode(encoded).value).assertEqual('hello');
    });

    it('bounds the memory queue and drops oldest when configured', 0, (): void => {
      const options: WsQueueOptions = new WsQueueOptions();
      options.maxMessages = 2; options.maxBytes = 100; options.overflowPolicy = WsQueueOverflowPolicy.DROP_OLDEST;
      const queue: MemoryWsOutboundQueue = new MemoryWsOutboundQueue(options);
      queue.enqueue(new WsOutboundMessage(1, 'a', 0, 0));
      queue.enqueue(new WsOutboundMessage(2, 'b', 0, 0));
      const result = queue.enqueue(new WsOutboundMessage(3, 'c', 0, 0));
      expect(result.accepted).assertTrue();
      expect(result.dropped?.id).assertEqual(1);
      expect(queue.size()).assertEqual(2);
    });

    it('queues while disconnected and flushes in FIFO order', 0, async (): Promise<void> => {
      const factory: MockTransportFactory = new MockTransportFactory();
      const scheduler: ManualScheduler = new ManualScheduler();
      const options: HmWebSocketClientOptions = new HmWebSocketClientOptions();
      options.scheduler = scheduler;
      const client: HmWebSocketClient = new HmWebSocketClient(
        new StaticWsEndpointProvider('ws://test'), factory, options);
      await client.send('first');
      await client.send('second');
      expect(client.queuedMessages()).assertEqual(2);
      await client.connect();
      await Promise.resolve();
      expect(client.state()).assertEqual(WsState.OPEN);
      expect(factory.transports[0].sent[0]).assertEqual('first');
      expect(factory.transports[0].sent[1]).assertEqual('second');
      expect(client.queuedMessages()).assertEqual(0);
    });

    it('consumes configured pong but forwards application messages', 0, async (): Promise<void> => {
      const factory: MockTransportFactory = new MockTransportFactory();
      const scheduler: ManualScheduler = new ManualScheduler();
      const received: string[] = [];
      const options: HmWebSocketClientOptions = new HmWebSocketClientOptions();
      options.scheduler = scheduler;
      options.heartbeat = new TextHeartbeatStrategy('PING', 'PONG', 10, 5, true);
      const client: HmWebSocketClient = new HmWebSocketClient(
        new StaticWsEndpointProvider('ws://test'), factory, options);
      client.addObserver(new WsClientObserver(undefined, undefined, (data: WsData): void => {
        if (typeof data === 'string') received.push(data);
      }));
      await client.connect();
      scheduler.advance(10);
      await Promise.resolve();
      expect(factory.transports[0].sent[0]).assertEqual('PING');
      factory.transports[0].emitMessage('PONG');
      factory.transports[0].emitMessage('hello');
      expect(received.length).assertEqual(1);
      expect(received[0]).assertEqual('hello');
    });

    it('schedules reconnect after abnormal close', 0, async (): Promise<void> => {
      const factory: MockTransportFactory = new MockTransportFactory();
      const scheduler: ManualScheduler = new ManualScheduler();
      const delays: number[] = [];
      const reconnectOptions: ExponentialBackoffOptions = new ExponentialBackoffOptions();
      reconnectOptions.initialDelayMs = 20; reconnectOptions.fullJitter = false;
      const options: HmWebSocketClientOptions = new HmWebSocketClientOptions();
      options.scheduler = scheduler;
      options.reconnectPolicy = new ExponentialBackoffPolicy(reconnectOptions);
      const client: HmWebSocketClient = new HmWebSocketClient(
        new StaticWsEndpointProvider('ws://test'), factory, options);
      client.addObserver(new WsClientObserver(undefined, undefined, undefined, undefined, undefined,
        (_attempt: number, delayMs: number): void => { delays.push(delayMs); }));
      await client.connect();
      factory.transports[0].emitClose(1006);
      expect(client.state()).assertEqual(WsState.RECONNECT_WAIT);
      expect(delays[0]).assertEqual(20);
      scheduler.advance(20);
      await Promise.resolve();
      expect(factory.transports.length).assertEqual(2);
      expect(client.state()).assertEqual(WsState.OPEN);
    });

    it('serializes concurrent application sends', 0, async (): Promise<void> => {
      const factory: SerialProbeFactory = new SerialProbeFactory();
      const client: HmWebSocketClient = HmWebSocketClient.withUrl('ws://test', factory);
      await client.connect();
      const first: Promise<number> = client.send('first');
      const second: Promise<number> = client.send('second');
      await Promise.resolve();
      expect(factory.transport.sent.length).assertEqual(1);
      factory.transport.release();
      await first;
      await second;
      expect(factory.transport.sent[0]).assertEqual('first');
      expect(factory.transport.sent[1]).assertEqual('second');
      expect(factory.transport.completed[0]).assertEqual('first');
      expect(factory.transport.completed[1]).assertEqual('second');
    });
  });
}
