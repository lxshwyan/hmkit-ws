import { WsCloseInfo, WsData, WsError } from '../core/Types';

export class WsServerCertificate {
  readonly certPath: string;
  readonly keyPath: string;
  constructor(certPath: string, keyPath: string) { this.certPath = certPath; this.keyPath = keyPath; }
}

export class WsServerOptions {
  host: string = '0.0.0.0';
  port: number = 8080;
  maxClients: number = 128;
  maxConnectionsPerClient: number = 8;
  protocol: string = '';
  certificate?: WsServerCertificate;
}

export class WsServerPeer {
  readonly id: string;
  readonly address: string;
  readonly port: number;
  constructor(id: string, address: string, port: number) {
    this.id = id; this.address = address; this.port = port;
  }
}

export class WsServerObserver {
  readonly onStarted: () => void;
  readonly onPeerConnected: (peer: WsServerPeer) => void;
  readonly onMessage: (peer: WsServerPeer, data: WsData) => void;
  readonly onPeerClosed: (peer: WsServerPeer, info: WsCloseInfo) => void;
  readonly onError: (error: WsError) => void;

  constructor(onStarted: () => void = (): void => {},
    onPeerConnected: (peer: WsServerPeer) => void = (_peer: WsServerPeer): void => {},
    onMessage: (peer: WsServerPeer, data: WsData) => void = (_peer: WsServerPeer, _data: WsData): void => {},
    onPeerClosed: (peer: WsServerPeer, info: WsCloseInfo) => void =
      (_peer: WsServerPeer, _info: WsCloseInfo): void => {},
    onError: (error: WsError) => void = (_error: WsError): void => {}) {
    this.onStarted = onStarted;
    this.onPeerConnected = onPeerConnected;
    this.onMessage = onMessage;
    this.onPeerClosed = onPeerClosed;
    this.onError = onError;
  }
}

export interface WsServer {
  setObserver(observer: WsServerObserver): void;
  start(options: WsServerOptions): Promise<void>;
  peers(): WsServerPeer[];
  send(peerId: string, data: WsData): Promise<void>;
  broadcast(data: WsData): Promise<void>;
  closePeer(peerId: string, code?: number, reason?: string): Promise<void>;
  stop(): Promise<void>;
}

export interface WsServerFactory {
  create(): WsServer;
}

export interface WsServerCapability {
  supported(): boolean;
  minimumApiLevel(): number;
}
