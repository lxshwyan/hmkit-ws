import { WsConnectionOptions, WsData, WsServer, WsServerCapability, WsServerFactory,
  WsServerObserver, WsServerOptions, WsServerPeer, WsTransport, WsTransportFactory,
  WsTransportObserver } from '@hmkit/ws';

export declare class NativeWsTransport implements WsTransport {
  setObserver(observer: WsTransportObserver): void;
  connect(url: string, options: WsConnectionOptions): Promise<void>;
  send(data: WsData): Promise<void>;
  ping(data?: ArrayBuffer): Promise<void>;
  close(code?: number, reason?: string): Promise<void>;
}

export declare class NativeWsTransportFactory implements WsTransportFactory {
  create(): WsTransport;
}

export declare class NativeWsServerCapability implements WsServerCapability {
  supported(): boolean;
  minimumApiLevel(): number;
}

export declare class NativeWsServer implements WsServer {
  constructor();
  setObserver(observer: WsServerObserver): void;
  start(options: WsServerOptions): Promise<void>;
  peers(): WsServerPeer[];
  send(peerId: string, data: WsData): Promise<void>;
  broadcast(data: WsData): Promise<void>;
  closePeer(peerId: string, code?: number, reason?: string): Promise<void>;
  stop(): Promise<void>;
}

export declare class NativeWsServerFactory implements WsServerFactory {
  create(): WsServer;
}
