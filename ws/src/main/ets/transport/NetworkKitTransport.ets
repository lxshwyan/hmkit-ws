import { BusinessError } from '@kit.BasicServicesKit';
import { connection, webSocket } from '@kit.NetworkKit';
import { WsTransport, WsTransportFactory, WsTransportObserver } from '../core/Transport';
import { WsClientCertificate, WsCloseInfo, WsConnectionOptions, WsData, WsError, WsErrorCode,
  WsProxyMode, WsProxyOptions } from '../core/Types';

export class NetworkKitWsTransport implements WsTransport {
  private socket?: webSocket.WebSocket;
  private observer: WsTransportObserver = new WsTransportObserver();
  private readonly onOpenHandler: (error: BusinessError, value: Object) => void;
  private readonly onMessageHandler: (error: BusinessError, value: string | ArrayBuffer) => void;
  private readonly onCloseHandler: (error: BusinessError, value: webSocket.CloseResult) => void;
  private readonly onErrorHandler: (error: BusinessError) => void;

  constructor() {
    this.onOpenHandler = (error: BusinessError, _value: Object): void => {
      if (error) { this.observer.onError(this.mapError(error, WsErrorCode.CONNECT_FAILED)); return; }
      this.observer.onOpen();
    };
    this.onMessageHandler = (error: BusinessError, value: string | ArrayBuffer): void => {
      if (error) { this.observer.onError(this.mapError(error, WsErrorCode.TRANSPORT)); return; }
      this.observer.onMessage(value);
    };
    this.onCloseHandler = (error: BusinessError, value: webSocket.CloseResult): void => {
      if (error) { this.observer.onError(this.mapError(error, WsErrorCode.TRANSPORT)); return; }
      this.observer.onClose(new WsCloseInfo(value.code, value.reason, value.code === 1000));
    };
    this.onErrorHandler = (error: BusinessError): void => {
      this.observer.onError(this.mapError(error, WsErrorCode.TRANSPORT));
    };
  }

  setObserver(observer: WsTransportObserver): void {
    this.observer = observer;
  }

  async connect(url: string, options: WsConnectionOptions): Promise<void> {
    if (this.socket !== undefined) {
      throw new WsError(WsErrorCode.INVALID_STATE, 'Transport 已创建连接');
    }
    const socket: webSocket.WebSocket = webSocket.createWebSocket();
    this.socket = socket;
    socket.on('open', this.onOpenHandler);
    socket.on('message', this.onMessageHandler);
    socket.on('close', this.onCloseHandler);
    socket.on('error', this.onErrorHandler);
    const request: webSocket.WebSocketRequestOptions = {};
    request.header = options.headers;
    if (options.caPath.length > 0) request.caPath = options.caPath;
    if (options.protocol.length > 0) request.protocol = options.protocol;
    const certificate: WsClientCertificate | undefined = options.clientCertificate;
    if (certificate !== undefined) {
      const clientCert: webSocket.ClientCert = {
        certPath: certificate.certPath,
        keyPath: certificate.keyPath,
        keyPassword: certificate.keyPassword
      };
      request.clientCert = clientCert;
    }
    const proxy: WsProxyOptions | undefined = options.proxy;
    if (proxy !== undefined) {
      if (proxy.mode === WsProxyMode.SYSTEM) request.proxy = 'system';
      else if (proxy.mode === WsProxyMode.NO_PROXY) request.proxy = 'no-proxy';
      else {
        const customProxy: connection.HttpProxy = {
          host: proxy.host,
          port: proxy.port,
          username: proxy.username,
          password: proxy.password,
          exclusionList: proxy.exclusionList
        };
        request.proxy = customProxy;
      }
    }
    try {
      await socket.connect(url, request);
    } catch (error) {
      this.disposeSocket();
      throw this.mapUnknown(error, WsErrorCode.CONNECT_FAILED, 'WebSocket 连接失败');
    }
  }

  async send(data: WsData): Promise<void> {
    if (this.socket === undefined) {
      throw new WsError(WsErrorCode.INVALID_STATE, 'Transport 尚未连接');
    }
    try {
      await this.socket.send(data);
    } catch (error) {
      throw this.mapUnknown(error, WsErrorCode.SEND_FAILED, 'WebSocket 发送失败');
    }
  }

  async close(code: number = 1000, reason: string = 'client closed'): Promise<void> {
    const socket: webSocket.WebSocket | undefined = this.socket;
    if (socket === undefined) return;
    try {
      await socket.close({ code: code, reason: reason });
    } catch (error) {
      throw this.mapUnknown(error, WsErrorCode.CLOSE_FAILED, 'WebSocket 关闭失败');
    } finally {
      this.disposeSocket();
    }
  }

  private disposeSocket(): void {
    const socket: webSocket.WebSocket | undefined = this.socket;
    if (socket === undefined) return;
    socket.off('open', this.onOpenHandler);
    socket.off('message', this.onMessageHandler);
    socket.off('close', this.onCloseHandler);
    socket.off('error', this.onErrorHandler);
    this.socket = undefined;
  }

  private mapError(error: BusinessError, code: WsErrorCode): WsError {
    return new WsError(code, error.message, `${error.code}`);
  }

  private mapUnknown(error: Object, code: WsErrorCode, fallback: string): WsError {
    if (error instanceof WsError) return error;
    if (error instanceof Error) return new WsError(code, error.message);
    return new WsError(code, fallback);
  }
}

export class NetworkKitWsTransportFactory implements WsTransportFactory {
  create(): WsTransport { return new NetworkKitWsTransport(); }
}
