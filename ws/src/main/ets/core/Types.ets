export type WsData = string | ArrayBuffer;

export enum WsState {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  OPEN = 'open',
  RECONNECT_WAIT = 'reconnect_wait',
  OFFLINE_WAIT = 'offline_wait',
  CLOSING = 'closing',
  CLOSED = 'closed',
  FAILED = 'failed'
}

export enum WsErrorCode {
  INVALID_STATE = 'invalid_state',
  CONNECT_FAILED = 'connect_failed',
  SEND_FAILED = 'send_failed',
  CLOSE_FAILED = 'close_failed',
  CONNECTION_TIMEOUT = 'connection_timeout',
  HEARTBEAT_TIMEOUT = 'heartbeat_timeout',
  QUEUE_FULL = 'queue_full',
  MESSAGE_EXPIRED = 'message_expired',
  TRANSPORT = 'transport'
}

export class WsError extends Error {
  readonly code: WsErrorCode;
  readonly causeMessage: string;

  constructor(code: WsErrorCode, message: string, causeMessage: string = '') {
    super(message);
    this.name = 'WsError';
    this.code = code;
    this.causeMessage = causeMessage;
  }
}

export class WsCloseInfo {
  readonly code: number;
  readonly reason: string;
  readonly clean: boolean;

  constructor(code: number = 1006, reason: string = '', clean: boolean = false) {
    this.code = code;
    this.reason = reason;
    this.clean = clean;
  }
}

export class WsConnectionOptions {
  headers: Record<string, string> = {};
  caPath: string = '';
  protocol: string = '';
  clientCertificate?: WsClientCertificate;
  proxy?: WsProxyOptions;
}

export class WsClientCertificate {
  readonly certPath: string;
  readonly keyPath: string;
  readonly keyPassword: string;

  constructor(certPath: string, keyPath: string, keyPassword: string = '') {
    this.certPath = certPath;
    this.keyPath = keyPath;
    this.keyPassword = keyPassword;
  }
}

export enum WsProxyMode {
  SYSTEM = 'system',
  NO_PROXY = 'no_proxy',
  CUSTOM = 'custom'
}

export class WsProxyOptions {
  readonly mode: WsProxyMode;
  host: string = '';
  port: number = 0;
  username: string = '';
  password: string = '';
  exclusionList: string[] = [];

  constructor(mode: WsProxyMode = WsProxyMode.SYSTEM) {
    this.mode = mode;
  }
}

export class WsEndpoint {
  readonly url: string;
  readonly options: WsConnectionOptions;

  constructor(url: string, options: WsConnectionOptions = new WsConnectionOptions()) {
    this.url = url;
    this.options = options;
  }
}

export interface WsEndpointProvider {
  resolve(): Promise<WsEndpoint>;
}

export class StaticWsEndpointProvider implements WsEndpointProvider {
  private readonly endpoint: WsEndpoint;

  constructor(url: string, options: WsConnectionOptions = new WsConnectionOptions()) {
    this.endpoint = new WsEndpoint(url, options);
  }

  resolve(): Promise<WsEndpoint> {
    return Promise.resolve(this.endpoint);
  }
}

export class WsClientObserver {
  readonly onStateChange: (state: WsState, previous: WsState) => void;
  readonly onOpen: () => void;
  readonly onMessage: (data: WsData) => void;
  readonly onClose: (info: WsCloseInfo) => void;
  readonly onError: (error: WsError) => void;
  readonly onReconnectScheduled: (attempt: number, delayMs: number) => void;
  readonly onQueued: (messageId: number) => void;
  readonly onSent: (messageId: number) => void;
  readonly onDropped: (messageId: number, error: WsError) => void;

  constructor(
    onStateChange: (state: WsState, previous: WsState) => void =
      (_state: WsState, _previous: WsState): void => {},
    onOpen: () => void = (): void => {},
    onMessage: (data: WsData) => void = (_data: WsData): void => {},
    onClose: (info: WsCloseInfo) => void = (_info: WsCloseInfo): void => {},
    onError: (error: WsError) => void = (_error: WsError): void => {},
    onReconnectScheduled: (attempt: number, delayMs: number) => void =
      (_attempt: number, _delayMs: number): void => {},
    onQueued: (messageId: number) => void = (_messageId: number): void => {},
    onSent: (messageId: number) => void = (_messageId: number): void => {},
    onDropped: (messageId: number, error: WsError) => void =
      (_messageId: number, _error: WsError): void => {}
  ) {
    this.onStateChange = onStateChange;
    this.onOpen = onOpen;
    this.onMessage = onMessage;
    this.onClose = onClose;
    this.onError = onError;
    this.onReconnectScheduled = onReconnectScheduled;
    this.onQueued = onQueued;
    this.onSent = onSent;
    this.onDropped = onDropped;
  }
}
