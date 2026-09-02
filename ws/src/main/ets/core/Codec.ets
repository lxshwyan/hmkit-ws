import { HmWebSocketClient } from './Client';
import { WsClientObserver, WsData, WsError } from './Types';

export interface WsMessageCodec<T> {
  encode(value: T): WsData;
  decode(data: WsData): T;
}

export class TextWsCodec implements WsMessageCodec<string> {
  encode(value: string): WsData { return value; }
  decode(data: WsData): string {
    if (typeof data !== 'string') throw new Error('期望文本 WebSocket 消息');
    return data;
  }
}

export class BinaryWsCodec implements WsMessageCodec<ArrayBuffer> {
  encode(value: ArrayBuffer): WsData { return value; }
  decode(data: WsData): ArrayBuffer {
    if (typeof data === 'string') throw new Error('期望二进制 WebSocket 消息');
    return data;
  }
}

export class JsonWsCodec<T> implements WsMessageCodec<T> {
  private readonly fromJson: (json: string) => T;
  private readonly toJson: (value: T) => string;

  constructor(fromJson: (json: string) => T,
    toJson: (value: T) => string = (value: T): string => JSON.stringify(value)) {
    this.fromJson = fromJson;
    this.toJson = toJson;
  }

  encode(value: T): WsData { return this.toJson(value); }

  decode(data: WsData): T {
    if (typeof data !== 'string') throw new Error('JSON Codec 只接受文本消息');
    return this.fromJson(data);
  }
}

export class TypedWsObserver<T> {
  readonly onMessage: (value: T) => void;
  readonly onDecodeError: (error: Error, data: WsData) => void;

  constructor(onMessage: (value: T) => void = (_value: T): void => {},
    onDecodeError: (error: Error, data: WsData) => void = (_error: Error, _data: WsData): void => {}) {
    this.onMessage = onMessage;
    this.onDecodeError = onDecodeError;
  }
}

export class TypedWsClient<T> {
  private readonly client: HmWebSocketClient;
  private readonly codec: WsMessageCodec<T>;
  private readonly observer: TypedWsObserver<T>;
  private readonly rawObserver: WsClientObserver;

  constructor(client: HmWebSocketClient, codec: WsMessageCodec<T>, observer: TypedWsObserver<T>) {
    this.client = client;
    this.codec = codec;
    this.observer = observer;
    this.rawObserver = new WsClientObserver(undefined, undefined, (data: WsData): void => this.consume(data),
      undefined, (error: WsError): void => {});
    this.client.addObserver(this.rawObserver);
  }

  connect(): Promise<void> { return this.client.connect(); }
  close(code: number = 1000, reason: string = 'client closed'): Promise<void> {
    return this.client.close(code, reason);
  }
  send(value: T): Promise<number> { return this.client.send(this.codec.encode(value)); }
  dispose(): void { this.client.removeObserver(this.rawObserver); }

  private consume(data: WsData): void {
    try {
      this.observer.onMessage(this.codec.decode(data));
    } catch (error) {
      const mapped: Error = error instanceof Error ? error : new Error('消息解码失败');
      this.observer.onDecodeError(mapped, data);
    }
  }
}

