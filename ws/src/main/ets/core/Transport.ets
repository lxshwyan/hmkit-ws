import { WsCloseInfo, WsConnectionOptions, WsData, WsError } from './Types';

export class WsTransportObserver {
  readonly onOpen: () => void;
  readonly onMessage: (data: WsData) => void;
  readonly onClose: (info: WsCloseInfo) => void;
  readonly onError: (error: WsError) => void;

  constructor(
    onOpen: () => void = (): void => {},
    onMessage: (data: WsData) => void = (_data: WsData): void => {},
    onClose: (info: WsCloseInfo) => void = (_info: WsCloseInfo): void => {},
    onError: (error: WsError) => void = (_error: WsError): void => {}
  ) {
    this.onOpen = onOpen;
    this.onMessage = onMessage;
    this.onClose = onClose;
    this.onError = onError;
  }
}

export interface WsTransport {
  setObserver(observer: WsTransportObserver): void;
  connect(url: string, options: WsConnectionOptions): Promise<void>;
  send(data: WsData): Promise<void>;
  close(code?: number, reason?: string): Promise<void>;
}

export interface WsTransportFactory {
  create(): WsTransport;
}

