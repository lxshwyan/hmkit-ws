import { WsCloseInfo, WsError } from '../core/Types';

export class WsReconnectContext {
  readonly attempt: number;
  readonly closeInfo?: WsCloseInfo;
  readonly error?: WsError;
  readonly uptimeMs: number;

  constructor(attempt: number, closeInfo?: WsCloseInfo, error?: WsError, uptimeMs: number = 0) {
    this.attempt = attempt;
    this.closeInfo = closeInfo;
    this.error = error;
    this.uptimeMs = uptimeMs;
  }
}

export class WsReconnectDecision {
  readonly retry: boolean;
  readonly delayMs: number;

  constructor(retry: boolean, delayMs: number = 0) {
    this.retry = retry;
    this.delayMs = delayMs;
  }
}

export interface WsReconnectPolicy {
  decide(context: WsReconnectContext): WsReconnectDecision;
}

export class ExponentialBackoffOptions {
  initialDelayMs: number = 1000;
  maxDelayMs: number = 30000;
  multiplier: number = 2;
  maxAttempts: number = -1;
  stableUptimeMs: number = 5000;
  fullJitter: boolean = true;
  retryNormalClosure: boolean = false;
}

export class ExponentialBackoffPolicy implements WsReconnectPolicy {
  private readonly options: ExponentialBackoffOptions;
  private readonly random: () => number;

  constructor(options: ExponentialBackoffOptions = new ExponentialBackoffOptions(),
    random: () => number = (): number => Math.random()) {
    this.options = options;
    this.random = random;
  }

  decide(context: WsReconnectContext): WsReconnectDecision {
    if (context.closeInfo?.code === 1000 && !this.options.retryNormalClosure) {
      return new WsReconnectDecision(false);
    }
    if (this.options.maxAttempts >= 0 && context.attempt > this.options.maxAttempts) {
      return new WsReconnectDecision(false);
    }
    const effectiveAttempt: number = context.uptimeMs >= this.options.stableUptimeMs ? 1 : context.attempt;
    const rawDelay: number = this.options.initialDelayMs *
      Math.pow(this.options.multiplier, Math.max(0, effectiveAttempt - 1));
    const cappedDelay: number = Math.min(this.options.maxDelayMs, rawDelay);
    const delay: number = this.options.fullJitter ? Math.floor(cappedDelay * this.random()) : Math.floor(cappedDelay);
    return new WsReconnectDecision(true, Math.max(0, delay));
  }
}

export class NeverReconnectPolicy implements WsReconnectPolicy {
  decide(_context: WsReconnectContext): WsReconnectDecision {
    return new WsReconnectDecision(false);
  }
}

