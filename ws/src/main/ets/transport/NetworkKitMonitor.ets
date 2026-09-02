import { BusinessError } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import { WsNetworkMonitor, WsNetworkObserver } from '../core/NetworkMonitor';

export class NetworkKitWsNetworkMonitor implements WsNetworkMonitor {
  private netConnection?: connection.NetConnection;
  private observer: WsNetworkObserver = new WsNetworkObserver();
  private available: boolean = true;
  private readonly onAvailableHandler: (handle: connection.NetHandle) => void;
  private readonly onUnavailableHandler: () => void;

  constructor() {
    this.onAvailableHandler = (_handle: connection.NetHandle): void => {
      this.available = true;
      this.observer.onAvailable();
    };
    this.onUnavailableHandler = (): void => {
      this.available = false;
      this.observer.onUnavailable();
    };
  }

  start(observer: WsNetworkObserver): void {
    if (this.netConnection !== undefined) return;
    this.observer = observer;
    try {
      this.available = connection.hasDefaultNetSync();
    } catch (_error) {
      this.available = true;
    }
    const netConnection: connection.NetConnection = connection.createNetConnection();
    this.netConnection = netConnection;
    netConnection.on('netAvailable', this.onAvailableHandler);
    netConnection.on('netUnavailable', this.onUnavailableHandler);
    netConnection.register((error: BusinessError): void => {
      if (error) {
        this.netConnection = undefined;
      }
    });
  }

  stop(): void {
    const netConnection: connection.NetConnection | undefined = this.netConnection;
    if (netConnection === undefined) return;
    netConnection.unregister((_error: BusinessError): void => {});
    this.netConnection = undefined;
  }

  isAvailable(): boolean { return this.available; }
}
