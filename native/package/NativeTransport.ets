import { NativeClientConfig, NativeCloseEvent, NativePeerCloseEvent, NativePeerMessage,
  NativeWebSocketClient, NativeWebSocketServer } from 'libhmkit_ws_native.so';
import { WsCloseInfo, WsConnectionOptions, WsData, WsError, WsErrorCode, WsServer,
  WsServerCapability, WsServerFactory, WsServerObserver, WsServerOptions, WsServerPeer,
  WsTransport, WsTransportFactory, WsTransportObserver } from '@hmkit/ws';

export class NativeWsTransport implements WsTransport {
  private observer: WsTransportObserver = new WsTransportObserver();
  private client?: NativeWebSocketClient;

  setObserver(observer: WsTransportObserver): void { this.observer = observer; }

  async connect(url: string, options: WsConnectionOptions): Promise<void> {
    if (this.client !== undefined) throw new WsError(WsErrorCode.INVALID_STATE, 'Native transport 已连接');
    const config: NativeClientConfig = { headers: options.headers };
    const client: NativeWebSocketClient = new NativeWebSocketClient(url, config);
    this.client = client;
    client.onOpen((): void => this.observer.onOpen());
    client.onMessage((data: string | ArrayBuffer): void => this.observer.onMessage(data));
    client.onClose((event: NativeCloseEvent): void => {
      this.client = undefined;
      this.observer.onClose(new WsCloseInfo(event.code, event.reason, event.clean));
    });
    client.onError((message: string): void => {
      this.observer.onError(new WsError(WsErrorCode.TRANSPORT, message));
    });
    try { await client.connect(); }
    catch (error) {
      this.client = undefined;
      throw error instanceof Error ? error : new WsError(WsErrorCode.CONNECT_FAILED, 'Native WebSocket 连接失败');
    }
  }

  async send(data: WsData): Promise<void> {
    const client: NativeWebSocketClient | undefined = this.client;
    if (client === undefined) throw new WsError(WsErrorCode.INVALID_STATE, 'Native transport 尚未连接');
    await client.send(data);
  }

  async ping(data: ArrayBuffer = new ArrayBuffer(0)): Promise<void> {
    const client: NativeWebSocketClient | undefined = this.client;
    if (client === undefined) throw new WsError(WsErrorCode.INVALID_STATE, 'Native transport 尚未连接');
    await client.ping(data);
  }

  async close(code: number = 1000, reason: string = ''): Promise<void> {
    const client: NativeWebSocketClient | undefined = this.client;
    if (client === undefined) return;
    await client.close(code, reason);
  }
}

export class NativeWsTransportFactory implements WsTransportFactory {
  create(): WsTransport { return new NativeWsTransport(); }
}

export class NativeWsServerCapability implements WsServerCapability {
  supported(): boolean { return true; }
  minimumApiLevel(): number { return 12; }
}

export class NativeWsServer implements WsServer {
  private readonly server: NativeWebSocketServer = new NativeWebSocketServer();
  private readonly peerMap: Map<string, WsServerPeer> = new Map<string, WsServerPeer>();
  private observer: WsServerObserver = new WsServerObserver();

  constructor() {
    this.server.onPeerOpen((peerId: number): void => {
      const peer: WsServerPeer = new WsServerPeer(`${peerId}`, '', 0);
      this.peerMap.set(peer.id, peer); this.observer.onPeerConnected(peer);
    });
    this.server.onPeerMessage((event: NativePeerMessage): void => {
      const peer: WsServerPeer | undefined = this.peerMap.get(`${event.peerId}`);
      if (peer !== undefined) this.observer.onMessage(peer, event.data);
    });
    this.server.onPeerClose((event: NativePeerCloseEvent): void => {
      const id: string = `${event.peerId}`;
      const peer: WsServerPeer | undefined = this.peerMap.get(id);
      this.peerMap.delete(id);
      if (peer !== undefined) this.observer.onPeerClosed(peer,
        new WsCloseInfo(event.code, event.reason, event.clean));
    });
    this.server.onError((message: string): void => {
      this.observer.onError(new WsError(WsErrorCode.TRANSPORT, message));
    });
  }

  setObserver(observer: WsServerObserver): void { this.observer = observer; }
  async start(options: WsServerOptions): Promise<void> {
    if (options.certificate !== undefined) {
      throw new WsError(WsErrorCode.INVALID_STATE, '当前 Native Server 尚未配置服务端证书');
    }
    await this.server.start(options.host, options.port); this.observer.onStarted();
  }
  peers(): WsServerPeer[] { return Array.from(this.peerMap.values()); }
  async send(peerId: string, data: WsData): Promise<void> { await this.server.send(parseInt(peerId, 10), data); }
  async broadcast(data: WsData): Promise<void> { await this.server.broadcast(data); }
  async closePeer(peerId: string, code: number = 1000, reason: string = ''): Promise<void> {
    await this.server.closePeer(parseInt(peerId, 10), code, reason);
  }
  async stop(): Promise<void> { await this.server.stop(); this.peerMap.clear(); }
}

export class NativeWsServerFactory implements WsServerFactory {
  create(): WsServer { return new NativeWsServer(); }
}
