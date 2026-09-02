export interface WsScheduler {
  now(): number;
  schedule(delayMs: number, callback: () => void): number;
  cancel(timerId: number): void;
}

export class SystemWsScheduler implements WsScheduler {
  now(): number {
    return Date.now();
  }

  schedule(delayMs: number, callback: () => void): number {
    return setTimeout(callback, Math.max(0, delayMs));
  }

  cancel(timerId: number): void {
    if (timerId >= 0) clearTimeout(timerId);
  }
}

