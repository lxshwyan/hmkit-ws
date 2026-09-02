import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { webSocket } from '@kit.NetworkKit';
import { WsCloseInfo, WsData, WsError, WsErrorCode, WsServer, WsServerCapability, WsServerFactory,
  WsServerObserver, WsServerOptions, WsServerPeer } from '@hmkit/ws';

export class NetworkKitWsServerCapability implements WsServerCapability {
  supported(): boolean { return deviceInfo.sdkApiVersion >= this.minimumApiLevel(); }
  minimumApiLevel(): number { return 19; }
}

class NativePeerEntry {
  readonly peer: WsServerPeer;
  readonly connection: webSocket.WebSocketConnection;
  constructor(peer: WsServerPeer, connection: webSocket.WebSocketConnection) {
    this.peer = peer; this.connection = connection;
  }
}

export class NetworkKitWsServer implements WsServer {
  private readonly capability: WsServerCapability;
  private observer: WsServerObserver = new WsServerObserver();
  private nativeServer?: webSocket.WebSocketServer;
  private readonly entries: Map<string, NativePeerEntry> = new Map<string, NativePeerEntry>();

  constructor(capability: WsServerCapability = new NetworkKitWsServerCapability()) { this.capability = capability; }
  setObserver(observer: WsServerObserver): void { this.observer = observer; }

  async start(options: WsServerOptions): Promise<void> {
    if (!this.capability.supported()) {
      throw new WsError(WsErrorCode.INVALID_STATE,
        `官方 WebSocket Server 需要 API ${this.capability.minimumApiLevel()}+`);
    }
    if (this.nativeServer !== undefined) throw new WsError(WsErrorCode.INVALID_STATE, '服务端已经启动');
    const server: webSocket.WebSocketServer = webSocket.createWebSocketServer();
    this.nativeServer = server;
    server.on('connect', (connection: webSocket.WebSocketConnection): void => {
      const peer: WsServerPeer = this.toPeer(connection);
      this.entries.set(peer.id, new NativePeerEntry(peer, connection));
      this.observer.onPeerConnected(peer);
    });
    server.on('messageReceive', (message: webSocket.WebSocketMessage): void => {
      this.observer.onMessage(this.toPeer(message.clientConnection), message.data);
    });
    server.on('close', (connection: webSocket.WebSocketConnection, result: webSocket.CloseResult): void => {
      const peer: WsServerPeer = this.toPeer(connection);
      this.entries.delete(peer.id);
      this.observer.onPeerClosed(peer, new WsCloseInfo(result.code, result.reason, result.code === 1000));
    });
    server.on('error', (error: BusinessError): void => {
      this.observer.onError(new WsError(WsErrorCode.TRANSPORT, error.message, `${error.code}`));
    });
    const config: webSocket.WebSocketServerConfig = {
      serverIP: options.host,
      serverPort: options.port,
      maxConcurrentClientsNumber: options.maxClients,
      maxConnectionsForOneClient: options.maxConnectionsPerClient
    };
    if (options.protocol.length > 0) config.protocol = options.protocol;
    if (options.certificate !== undefined) {
      config.serverCert = { certPath: options.certificate.certPath, keyPath: options.certificate.keyPath };
    }
    try {
      const started: boolean = await server.start(config);
      if (!started) throw new WsError(WsErrorCode.CONNECT_FAILED, 'WebSocket Server 启动失败');
      this.observer.onStarted();
    } catch (error) {
      this.nativeServer = undefined;
      throw this.mapError(error, 'WebSocket Server 启动失败');
    }
  }

  peers(): WsServerPeer[] {
    const result: WsServerPeer[] = [];
    this.entries.forEach((entry: NativePeerEntry): void => { result.push(entry.peer); });
    return result;
  }

  async send(peerId: string, data: WsData): Promise<void> {
    const server: webSocket.WebSocketServer | undefined = this.nativeServer;
    const entry: NativePeerEntry | undefined = this.entries.get(peerId);
    if (server === undefined || entry === undefined) throw new WsError(WsErrorCode.INVALID_STATE, '连接不存在');
    try {
      const sent: boolean = await server.send(data, entry.connection);
      if (!sent) throw new WsError(WsErrorCode.SEND_FAILED, '服务端消息发送失败');
    } catch (error) { throw this.mapError(error, '服务端消息发送失败'); }
  }

  async broadcast(data: WsData): Promise<void> {
    const ids: string[] = [];
    this.entries.forEach((_entry: NativePeerEntry, id: string): void => { ids.push(id); });
    for (let i: number = 0; i < ids.length; i++) await this.send(ids[i], data);
  }

  async closePeer(peerId: string, code: number = 1000, reason: string = ''): Promise<void> {
    const server: webSocket.WebSocketServer | undefined = this.nativeServer;
    const entry: NativePeerEntry | undefined = this.entries.get(peerId);
    if (server === undefined || entry === undefined) return;
    try { await server.close(entry.connection, { code: code, reason: reason }); }
    catch (error) { throw this.mapError(error, '关闭客户端连接失败'); }
    this.entries.delete(peerId);
  }

  async stop(): Promise<void> {
    const server: webSocket.WebSocketServer | undefined = this.nativeServer;
    if (server === undefined) return;
    this.nativeServer = undefined;
    try { await server.stop(); }
    catch (error) { throw this.mapError(error, '停止 WebSocket Server 失败'); }
    finally { this.entries.clear(); }
  }

  private toPeer(connection: webSocket.WebSocketConnection): WsServerPeer {
    return new WsServerPeer(`${connection.clientIP}:${connection.clientPort}`,
      connection.clientIP, connection.clientPort);
  }

  private mapError(error: Object, fallback: string): WsError {
    if (error instanceof WsError) return error;
    if (error instanceof Error) return new WsError(WsErrorCode.TRANSPORT, error.message);
    return new WsError(WsErrorCode.TRANSPORT, fallback);
  }
}

export class NetworkKitWsServerFactory implements WsServerFactory {
  private readonly capability: WsServerCapability;
  constructor(capability: WsServerCapability = new NetworkKitWsServerCapability()) { this.capability = capability; }
  create(): WsServer { return new NetworkKitWsServer(this.capability); }
}
