import { WsData } from '../core/Types';

export interface WsHeartbeatStrategy {
  intervalMs(): number;
  timeoutMs(): number;
  createPing(): WsData;
  isPong(data: WsData): boolean;
  consumePong(): boolean;
}

export class TextHeartbeatStrategy implements WsHeartbeatStrategy {
  private readonly pingText: string;
  private readonly pongText: string;
  private readonly heartbeatIntervalMs: number;
  private readonly heartbeatTimeoutMs: number;
  private readonly shouldConsumePong: boolean;

  constructor(pingText: string = 'ping', pongText: string = 'pong', intervalMs: number = 30000,
    timeoutMs: number = 10000, consumePong: boolean = true) {
    this.pingText = pingText;
    this.pongText = pongText;
    this.heartbeatIntervalMs = intervalMs;
    this.heartbeatTimeoutMs = timeoutMs;
    this.shouldConsumePong = consumePong;
  }

  intervalMs(): number { return this.heartbeatIntervalMs; }
  timeoutMs(): number { return this.heartbeatTimeoutMs; }
  createPing(): WsData { return this.pingText; }
  isPong(data: WsData): boolean { return typeof data === 'string' && data === this.pongText; }
  consumePong(): boolean { return this.shouldConsumePong; }
}

