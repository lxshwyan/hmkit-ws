import { http } from '@kit.NetworkKit';
import { WsBase64Codec } from '../../core/Bytes';
import { WsTransport, WsTransportFactory, WsTransportObserver } from '../../core/Transport';
import { WsCloseInfo, WsConnectionOptions, WsData, WsError, WsErrorCode } from '../../core/Types';
import { EngineIoCodec, EngineIoPacket, EngineIoPacketType } from './SocketIoCodec';

export enum PollingHttpMethod {
  GET = 'GET',
  POST = 'POST'
}

export class PollingHttpRequest {
  readonly url: string;
  readonly method: PollingHttpMethod;
  readonly body: string;
  readonly headers: Record<string, string>;

  constructor(url: string, method: PollingHttpMethod, body: string = '',
    headers: Record<string, string> = {}) {
    this.url = url; this.method = method; this.body = body; this.headers = headers;
  }
}

export class PollingHttpResponse {
  readonly status: number;
  readonly body: string;
  constructor(status: number, body: string) { this.status = status; this.body = body; }
}

export interface PollingHttpExecutor {
  execute(request: PollingHttpRequest): Promise<PollingHttpResponse>;
  cancel(): void;
}

export class NetworkKitPollingHttpExecutor implements PollingHttpExecutor {
  private readonly active: http.HttpRequest[] = [];

  async execute(request: PollingHttpRequest): Promise<PollingHttpResponse> {
    const client: http.HttpRequest = http.createHttp();
    this.active.push(client);
    const options: http.HttpRequestOptions = {
      method: request.method === PollingHttpMethod.GET ? http.RequestMethod.GET : http.RequestMethod.POST,
      header: request.headers,
      expectDataType: http.HttpDataType.STRING,
      usingCache: false
    };
    if (request.method === PollingHttpMethod.POST) options.extraData = request.body;
    try {
      const response: http.HttpResponse = await client.request(request.url, options);
      const value: string = typeof response.result === 'string' ? response.result : `${response.result}`;
      return new PollingHttpResponse(response.responseCode, value);
    } finally {
      const index: number = this.active.indexOf(client);
      if (index >= 0) this.active.splice(index, 1);
      client.destroy();
    }
  }

  cancel(): void {
    const requests: http.HttpRequest[] = this.active.splice(0, this.active.length);
    for (let i: number = 0; i < requests.length; i++) requests[i].destroy();
  }
}

export class EngineIoPollingPayloadCodec {
  private readonly engine: EngineIoCodec = new EngineIoCodec();

  encode(packets: WsData[]): string {
    const values: string[] = [];
    for (let i: number = 0; i < packets.length; i++) {
      const packet: WsData = packets[i];
      if (typeof packet === 'string') values.push(packet);
      else values.push(`b${WsBase64Codec.encode(new Uint8Array(packet))}`);
    }
    return values.join('\u001e');
  }

  decode(payload: string): WsData[] {
    if (payload.length === 0) return [];
    const encoded: string[] = payload.split('\u001e');
    const packets: WsData[] = [];
    for (let i: number = 0; i < encoded.length; i++) {
      const value: string = encoded[i];
      if (value.startsWith('b')) packets.push(this.copyBuffer(WsBase64Codec.decode(value.substring(1))));
      else packets.push(value);
    }
    return packets;
  }

  sessionId(payload: string): string {
    const packets: WsData[] = this.decode(payload);
    if (packets.length === 0 || typeof packets[0] !== 'string') throw new Error('Polling 握手缺少 OPEN packet');
    const packet: EngineIoPacket = this.engine.decode(packets[0]);
    return this.engine.decodeOpen(packet).sid;
  }

  private copyBuffer(bytes: Uint8Array): ArrayBuffer {
    const copy: Uint8Array = new Uint8Array(bytes.byteLength); copy.set(bytes); return copy.buffer;
  }
}

export class EngineIoPollingTransportOptions {
  executor: PollingHttpExecutor = new NetworkKitPollingHttpExecutor();
  timestampRequests: boolean = true;
  timestampParameter: string = 't';
  extraQuery: Record<string, string> = {};
}

export class EngineIoPollingTransport implements WsTransport {
  private readonly options: EngineIoPollingTransportOptions;
  private readonly payloadCodec: EngineIoPollingPayloadCodec = new EngineIoPollingPayloadCodec();
  private observer: WsTransportObserver = new WsTransportObserver();
  private url: string = '';
  private headers: Record<string, string> = {};
  private sid: string = '';
  private active: boolean = false;
  private requestCounter: number = 0;
  private postTail: Promise<void> = Promise.resolve();

  constructor(options: EngineIoPollingTransportOptions = new EngineIoPollingTransportOptions()) {
    this.options = options;
  }

  setObserver(observer: WsTransportObserver): void { this.observer = observer; }

  async connect(url: string, connectionOptions: WsConnectionOptions): Promise<void> {
    if (this.active) throw new WsError(WsErrorCode.INVALID_STATE, 'Polling transport 已连接');
    this.active = true; this.url = this.toHttpUrl(url); this.headers = connectionOptions.headers;
    try {
      const response: PollingHttpResponse = await this.options.executor.execute(
        new PollingHttpRequest(this.requestUrl(false), PollingHttpMethod.GET, '', this.headers));
      this.requireSuccess(response);
      this.sid = this.payloadCodec.sessionId(response.body);
      this.observer.onOpen();
      this.dispatch(response.body);
      this.poll().catch((error: Object): void => this.fail(error));
    } catch (error) {
      this.active = false;
      throw this.mapError(error, WsErrorCode.CONNECT_FAILED, 'Engine.IO polling 握手失败');
    }
  }

  async send(data: WsData): Promise<void> {
    if (!this.active || this.sid.length === 0) throw new WsError(WsErrorCode.INVALID_STATE, 'Polling 尚未连接');
    const operation: Promise<void> = this.postTail.then((): Promise<void> => this.post(data));
    this.postTail = operation.catch((_error: Object): void => {});
    await operation;
  }

  private async post(data: WsData): Promise<void> {
    if (!this.active || this.sid.length === 0) throw new WsError(WsErrorCode.INVALID_STATE, 'Polling 已关闭');
    const response: PollingHttpResponse = await this.options.executor.execute(new PollingHttpRequest(
      this.requestUrl(true), PollingHttpMethod.POST, this.payloadCodec.encode([data]), this.postHeaders()));
    this.requireSuccess(response);
  }

  async close(code: number = 1000, reason: string = ''): Promise<void> {
    if (!this.active) return;
    this.active = false;
    if (this.sid.length > 0) {
      try {
        const closePacket: WsData = new EngineIoCodec().encode(new EngineIoPacket(EngineIoPacketType.CLOSE));
        await this.options.executor.execute(new PollingHttpRequest(this.requestUrl(true), PollingHttpMethod.POST,
          this.payloadCodec.encode([closePacket]), this.postHeaders()));
      } catch (_error) {}
    }
    this.options.executor.cancel(); this.sid = '';
    this.observer.onClose(new WsCloseInfo(code, reason, code === 1000));
  }

  private async poll(): Promise<void> {
    while (this.active) {
      const response: PollingHttpResponse = await this.options.executor.execute(
        new PollingHttpRequest(this.requestUrl(true), PollingHttpMethod.GET, '', this.headers));
      if (!this.active) return;
      this.requireSuccess(response); this.dispatch(response.body);
    }
  }

  private dispatch(payload: string): void {
    const packets: WsData[] = this.payloadCodec.decode(payload);
    for (let i: number = 0; i < packets.length; i++) this.observer.onMessage(packets[i]);
  }

  private requestUrl(withSid: boolean): string {
    const separator: string = this.url.indexOf('?') >= 0 ? '&' : '?';
    let query: string = 'EIO=4&transport=polling';
    if (withSid && this.sid.length > 0) query += `&sid=${encodeURIComponent(this.sid)}`;
    const keys: string[] = Object.keys(this.options.extraQuery);
    for (let i: number = 0; i < keys.length; i++) {
      query += `&${encodeURIComponent(keys[i])}=${encodeURIComponent(this.options.extraQuery[keys[i]])}`;
    }
    if (this.options.timestampRequests) {
      query += `&${encodeURIComponent(this.options.timestampParameter)}=${Date.now()}-${this.requestCounter++}`;
    }
    return `${this.url}${separator}${query}`;
  }

  private postHeaders(): Record<string, string> {
    const result: Record<string, string> = {};
    const keys: string[] = Object.keys(this.headers);
    for (let i: number = 0; i < keys.length; i++) result[keys[i]] = this.headers[keys[i]];
    result['Content-Type'] = 'text/plain;charset=UTF-8';
    return result;
  }

  private toHttpUrl(value: string): string {
    if (value.startsWith('ws://')) return `http://${value.substring(5)}`;
    if (value.startsWith('wss://')) return `https://${value.substring(6)}`;
    return value;
  }

  private requireSuccess(response: PollingHttpResponse): void {
    if (response.status < 200 || response.status >= 300) {
      throw new WsError(WsErrorCode.TRANSPORT, `Engine.IO polling HTTP ${response.status}`);
    }
  }

  private fail(error: Object): void {
    if (!this.active) return;
    this.active = false; this.options.executor.cancel();
    this.observer.onError(this.mapError(error, WsErrorCode.TRANSPORT, 'Engine.IO polling 失败'));
  }

  private mapError(error: Object, code: WsErrorCode, fallback: string): WsError {
    if (error instanceof WsError) return error;
    if (error instanceof Error) return new WsError(code, error.message);
    return new WsError(code, fallback);
  }
}

export class EngineIoPollingTransportFactory implements WsTransportFactory {
  private readonly createOptions: () => EngineIoPollingTransportOptions;
  constructor(createOptions: () => EngineIoPollingTransportOptions =
    (): EngineIoPollingTransportOptions => new EngineIoPollingTransportOptions()) {
    this.createOptions = createOptions;
  }
  create(): WsTransport { return new EngineIoPollingTransport(this.createOptions()); }
}
