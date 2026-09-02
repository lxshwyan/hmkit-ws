import { WsData } from '../../core/Types';
import { Utf8Codec } from '../../core/Bytes';

export enum StompCommand {
  CONNECT = 'CONNECT',
  STOMP = 'STOMP',
  CONNECTED = 'CONNECTED',
  SEND = 'SEND',
  SUBSCRIBE = 'SUBSCRIBE',
  UNSUBSCRIBE = 'UNSUBSCRIBE',
  ACK = 'ACK',
  NACK = 'NACK',
  BEGIN = 'BEGIN',
  COMMIT = 'COMMIT',
  ABORT = 'ABORT',
  DISCONNECT = 'DISCONNECT',
  MESSAGE = 'MESSAGE',
  RECEIPT = 'RECEIPT',
  ERROR = 'ERROR'
}

export class StompFrame {
  readonly command: string;
  readonly headers: Record<string, string>;
  readonly body: WsData;

  constructor(command: string, headers: Record<string, string> = {}, body: WsData = '') {
    this.command = command;
    this.headers = headers;
    this.body = body;
  }
}

export class StompDecodeBatch {
  readonly frames: StompFrame[];
  readonly heartbeatCount: number;

  constructor(frames: StompFrame[], heartbeatCount: number) {
    this.frames = frames;
    this.heartbeatCount = heartbeatCount;
  }
}

export class StompCodec {
  encode(frame: StompFrame): WsData {
    const bodyBytes: Uint8Array = typeof frame.body === 'string' ? this.encodeText(frame.body) :
      new Uint8Array(frame.body);
    const headers: Record<string, string> = {};
    const keys: string[] = Object.keys(frame.headers);
    for (let i: number = 0; i < keys.length; i++) headers[keys[i]] = frame.headers[keys[i]];
    if (typeof frame.body !== 'string' && headers['content-length'] === undefined) {
      headers['content-length'] = `${bodyBytes.byteLength}`;
    }
    let head: string = `${frame.command}\n`;
    const headerKeys: string[] = Object.keys(headers);
    const escapeHeaders: boolean = frame.command !== StompCommand.CONNECT &&
      frame.command !== StompCommand.STOMP && frame.command !== StompCommand.CONNECTED;
    for (let i: number = 0; i < headerKeys.length; i++) {
      const key: string = escapeHeaders ? this.escapeHeader(headerKeys[i]) : headerKeys[i];
      const value: string = escapeHeaders ? this.escapeHeader(headers[headerKeys[i]]) : headers[headerKeys[i]];
      head += `${key}:${value}\n`;
    }
    head += '\n';
    const headBytes: Uint8Array = this.encodeText(head);
    const encoded: Uint8Array = new Uint8Array(headBytes.byteLength + bodyBytes.byteLength + 1);
    encoded.set(headBytes, 0);
    encoded.set(bodyBytes, headBytes.byteLength);
    encoded[encoded.byteLength - 1] = 0;
    if (typeof frame.body === 'string') return this.decodeText(encoded);
    return encoded.buffer;
  }

  escapeHeader(value: string): string {
    return value.split('\\').join('\\\\').split('\r').join('\\r')
      .split('\n').join('\\n').split(':').join('\\c');
  }

  unescapeHeader(value: string): string {
    let result: string = '';
    for (let i: number = 0; i < value.length; i++) {
      if (value[i] !== '\\') { result += value[i]; continue; }
      if (i + 1 >= value.length) throw new Error('STOMP header 转义不完整');
      const escaped: string = value[++i];
      if (escaped === 'r') result += '\r';
      else if (escaped === 'n') result += '\n';
      else if (escaped === 'c') result += ':';
      else if (escaped === '\\') result += '\\';
      else throw new Error(`非法 STOMP header 转义：\\${escaped}`);
    }
    return result;
  }

  encodeText(value: string): Uint8Array {
    return Utf8Codec.encode(value);
  }

  decodeText(value: Uint8Array): string {
    return Utf8Codec.decode(value);
  }
}

export class StompFrameDecoder {
  private readonly codec: StompCodec = new StompCodec();
  private buffer: Uint8Array = new Uint8Array(0);

  push(data: WsData): StompDecodeBatch {
    const incoming: Uint8Array = typeof data === 'string' ? this.codec.encodeText(data) : new Uint8Array(data);
    const joined: Uint8Array = new Uint8Array(this.buffer.byteLength + incoming.byteLength);
    joined.set(this.buffer, 0);
    joined.set(incoming, this.buffer.byteLength);
    this.buffer = joined;
    const frames: StompFrame[] = [];
    let heartbeatCount: number = 0;
    let progress: boolean = true;
    while (progress) {
      progress = false;
      while (this.buffer.byteLength > 0 && (this.buffer[0] === 10 || this.buffer[0] === 13)) {
        if (this.buffer[0] === 13 && this.buffer.byteLength > 1 && this.buffer[1] === 10) {
          this.buffer = this.buffer.slice(2);
        } else {
          this.buffer = this.buffer.slice(1);
        }
        heartbeatCount += 1;
        progress = true;
      }
      const headerBoundary: number[] = this.findHeaderBoundary();
      if (headerBoundary[0] < 0) break;
      const headBytes: Uint8Array = this.buffer.slice(0, headerBoundary[0]);
      const head: string = this.codec.decodeText(headBytes).split('\r\n').join('\n');
      const lines: string[] = head.split('\n');
      if (lines.length === 0 || lines[0].length === 0) throw new Error('STOMP command 不能为空');
      const command: string = lines[0];
      const headers: Record<string, string> = {};
      for (let i: number = 1; i < lines.length; i++) {
        const separator: number = lines[i].indexOf(':');
        if (separator < 0) throw new Error('STOMP header 缺少分隔符');
        const rawKey: string = lines[i].substring(0, separator);
        const rawValue: string = lines[i].substring(separator + 1);
        const escapeHeaders: boolean = command !== StompCommand.CONNECT && command !== StompCommand.STOMP &&
          command !== StompCommand.CONNECTED;
        const key: string = escapeHeaders ? this.codec.unescapeHeader(rawKey) : rawKey;
        if (headers[key] === undefined) headers[key] = escapeHeaders ? this.codec.unescapeHeader(rawValue) : rawValue;
      }
      const bodyStart: number = headerBoundary[0] + headerBoundary[1];
      const contentLengthText: string | undefined = headers['content-length'];
      let bodyEnd: number = -1;
      if (contentLengthText !== undefined) {
        const contentLength: number = parseInt(contentLengthText, 10);
        if (!Number.isSafeInteger(contentLength) || contentLength < 0) throw new Error('STOMP content-length 非法');
        bodyEnd = bodyStart + contentLength;
        if (this.buffer.byteLength <= bodyEnd) break;
        if (this.buffer[bodyEnd] !== 0) throw new Error('STOMP frame 缺少 NUL 结尾');
      } else {
        bodyEnd = this.findByte(0, bodyStart);
        if (bodyEnd < 0) break;
      }
      const bodyBytes: Uint8Array = this.buffer.slice(bodyStart, bodyEnd);
      const contentType: string = headers['content-type'] ?? '';
      const body: WsData = contentType.startsWith('application/octet-stream') ? bodyBytes.buffer :
        this.codec.decodeText(bodyBytes);
      frames.push(new StompFrame(command, headers, body));
      this.buffer = this.buffer.slice(bodyEnd + 1);
      progress = true;
    }
    return new StompDecodeBatch(frames, heartbeatCount);
  }

  reset(): void { this.buffer = new Uint8Array(0); }
  pendingBytes(): number { return this.buffer.byteLength; }

  private findHeaderBoundary(): number[] {
    for (let i: number = 0; i < this.buffer.byteLength - 1; i++) {
      if (this.buffer[i] === 10 && this.buffer[i + 1] === 10) return [i, 2];
      if (i < this.buffer.byteLength - 3 && this.buffer[i] === 13 && this.buffer[i + 1] === 10 &&
        this.buffer[i + 2] === 13 && this.buffer[i + 3] === 10) return [i, 4];
    }
    return [-1, 0];
  }

  private findByte(value: number, start: number): number {
    for (let i: number = start; i < this.buffer.byteLength; i++) if (this.buffer[i] === value) return i;
    return -1;
  }
}
