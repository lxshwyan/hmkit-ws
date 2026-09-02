import { fileIo as fs } from '@kit.CoreFileKit';
import { WsBase64Codec } from '../core/Bytes';
import { WsData, WsError, WsErrorCode } from '../core/Types';
import { MemoryWsOutboundQueue, WsOutboundMessage, WsOutboundQueue, WsQueueOptions,
  WsQueueResult } from './Queue';

class WsQueueWire {
  id: number = 0;
  binary: boolean = false;
  payload: string = '';
  createdAt: number = 0;
  expiresAt: number = 0;

  static fromMessage(message: WsOutboundMessage): WsQueueWire {
    const wire: WsQueueWire = new WsQueueWire();
    wire.id = message.id;
    wire.createdAt = message.createdAt;
    wire.expiresAt = message.expiresAt;
    if (typeof message.data === 'string') {
      wire.payload = message.data;
    } else {
      wire.binary = true;
      wire.payload = WsBase64Codec.encode(new Uint8Array(message.data));
    }
    return wire;
  }

  toMessage(): WsOutboundMessage {
    const data: WsData = this.binary ? WsBase64Codec.decode(this.payload).buffer : this.payload;
    return new WsOutboundMessage(this.id, data, this.createdAt, this.expiresAt);
  }
}

export class FileWsOutboundQueue implements WsOutboundQueue {
  private readonly filePath: string;
  private readonly memory: MemoryWsOutboundQueue;

  constructor(directory: string, options: WsQueueOptions = new WsQueueOptions(),
    fileName: string = 'hmkit-ws-outbound-queue.json') {
    if (directory.trim().length === 0) throw new WsError(WsErrorCode.INVALID_STATE, '队列存储目录不能为空');
    const base: string = directory.endsWith('/') ? directory.substring(0, directory.length - 1) : directory;
    this.filePath = `${base}/${fileName}`;
    this.memory = new MemoryWsOutboundQueue(options);
    this.load();
  }

  enqueue(message: WsOutboundMessage): WsQueueResult {
    const result: WsQueueResult = this.memory.enqueue(message);
    if (result.accepted) this.flush();
    return result;
  }

  peek(): WsOutboundMessage | undefined { return this.memory.peek(); }

  removeFirst(): WsOutboundMessage | undefined {
    const message: WsOutboundMessage | undefined = this.memory.removeFirst();
    if (message !== undefined) this.flush();
    return message;
  }

  removeExpired(now: number): WsOutboundMessage[] {
    const messages: WsOutboundMessage[] = this.memory.removeExpired(now);
    if (messages.length > 0) this.flush();
    return messages;
  }

  size(): number { return this.memory.size(); }
  bytes(): number { return this.memory.bytes(); }
  list(): WsOutboundMessage[] { return this.memory.list(); }

  clear(): WsOutboundMessage[] {
    const messages: WsOutboundMessage[] = this.memory.clear();
    this.flush();
    return messages;
  }

  private load(): void {
    try {
      if (!fs.accessSync(this.filePath)) return;
      const json: string = fs.readTextSync(this.filePath);
      if (json.trim().length === 0) return;
      const wires: WsQueueWire[] = JSON.parse(json) as WsQueueWire[];
      for (let i: number = 0; i < wires.length; i++) this.memory.enqueue(wires[i].toMessage());
    } catch (error) {
      throw new WsError(WsErrorCode.TRANSPORT,
        error instanceof Error ? `无法读取持久化队列：${error.message}` : '无法读取持久化队列');
    }
  }

  private flush(): void {
    const wires: WsQueueWire[] = this.memory.list().map((message: WsOutboundMessage): WsQueueWire =>
      WsQueueWire.fromMessage(message));
    let file: fs.File | undefined;
    try {
      file = fs.openSync(this.filePath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(wires));
    } catch (error) {
      throw new WsError(WsErrorCode.TRANSPORT,
        error instanceof Error ? `无法写入持久化队列：${error.message}` : '无法写入持久化队列');
    } finally {
      if (file !== undefined) { try { fs.closeSync(file); } catch (_error) {} }
    }
  }
}
