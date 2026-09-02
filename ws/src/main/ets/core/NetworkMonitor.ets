export class WsNetworkObserver {
  readonly onAvailable: () => void;
  readonly onUnavailable: () => void;

  constructor(onAvailable: () => void = (): void => {}, onUnavailable: () => void = (): void => {}) {
    this.onAvailable = onAvailable;
    this.onUnavailable = onUnavailable;
  }
}

export interface WsNetworkMonitor {
  start(observer: WsNetworkObserver): void;
  stop(): void;
  isAvailable(): boolean;
}

