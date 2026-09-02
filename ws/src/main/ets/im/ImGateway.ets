import { ImMessage, ImPresence, ImReceipt, ImSyncBatch, ImTyping } from './ImTypes';

export class ImGatewayObserver {
  readonly onMessage: (message: ImMessage) => void;
  readonly onReceipt: (receipt: ImReceipt) => void;
  readonly onPresence: (presence: ImPresence) => void;
  readonly onTyping: (typing: ImTyping) => void;
  readonly onError: (error: Error) => void;

  constructor(onMessage: (message: ImMessage) => void = (_message: ImMessage): void => {},
    onReceipt: (receipt: ImReceipt) => void = (_receipt: ImReceipt): void => {},
    onPresence: (presence: ImPresence) => void = (_presence: ImPresence): void => {},
    onTyping: (typing: ImTyping) => void = (_typing: ImTyping): void => {},
    onError: (error: Error) => void = (_error: Error): void => {}) {
    this.onMessage = onMessage;
    this.onReceipt = onReceipt;
    this.onPresence = onPresence;
    this.onTyping = onTyping;
    this.onError = onError;
  }
}

export interface ImGateway {
  setObserver(observer: ImGatewayObserver): void;
  connect(): Promise<void>;
  disconnect(): Promise<void>;
  sendMessage(message: ImMessage): Promise<ImMessage>;
  sendReceipt(receipt: ImReceipt): Promise<void>;
  sendTyping(typing: ImTyping): Promise<void>;
  sync(cursor: string, limit: number): Promise<ImSyncBatch>;
}

export interface ImAuthProvider {
  accessToken(): Promise<string>;
}

export interface ImAttachmentUploader {
  upload(localUri: string, contentType: string): Promise<string>;
}

export interface ImModerationPolicy {
  validate(message: ImMessage): Promise<void>;
}

export interface ImPushBridge {
  registerToken(token: string): Promise<void>;
  unregisterToken(token: string): Promise<void>;
}
