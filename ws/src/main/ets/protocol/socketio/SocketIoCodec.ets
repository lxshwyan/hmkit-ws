import { WsData } from '../../core/Types';

export enum EngineIoPacketType {
  OPEN = 0,
  CLOSE = 1,
  PING = 2,
  PONG = 3,
  MESSAGE = 4,
  UPGRADE = 5,
  NOOP = 6
}

export class EngineIoOpenPacket {
  sid: string = '';
  upgrades: string[] = [];
  pingInterval: number = 25000;
  pingTimeout: number = 20000;
  maxPayload: number = 1000000;
}

export class EngineIoPacket {
  readonly type: EngineIoPacketType;
  readonly data: WsData;

  constructor(type: EngineIoPacketType, data: WsData = '') {
    this.type = type;
    this.data = data;
  }
}

export class EngineIoCodec {
  encode(packet: EngineIoPacket): WsData {
    if (typeof packet.data !== 'string') {
      if (packet.type !== EngineIoPacketType.MESSAGE) throw new Error('Engine.IO 二进制只允许 MESSAGE');
      return packet.data;
    }
    return `${packet.type}${packet.data}`;
  }

  decode(data: WsData): EngineIoPacket {
    if (typeof data !== 'string') return new EngineIoPacket(EngineIoPacketType.MESSAGE, data);
    if (data.length === 0) throw new Error('Engine.IO packet 不能为空');
    const type: number = parseInt(data[0], 10);
    if (!Number.isInteger(type) || type < EngineIoPacketType.OPEN || type > EngineIoPacketType.NOOP) {
      throw new Error(`未知 Engine.IO packet type：${data[0]}`);
    }
    return new EngineIoPacket(type as EngineIoPacketType, data.substring(1));
  }

  decodeOpen(packet: EngineIoPacket): EngineIoOpenPacket {
    if (packet.type !== EngineIoPacketType.OPEN || typeof packet.data !== 'string') {
      throw new Error('不是 Engine.IO OPEN packet');
    }
    return JSON.parse(packet.data) as EngineIoOpenPacket;
  }
}

export enum SocketIoPacketType {
  CONNECT = 0,
  DISCONNECT = 1,
  EVENT = 2,
  ACK = 3,
  CONNECT_ERROR = 4,
  BINARY_EVENT = 5,
  BINARY_ACK = 6
}

export class SocketIoPacket {
  readonly type: SocketIoPacketType;
  namespace: string = '/';
  ackId: number = -1;
  attachmentsExpected: number = 0;
  dataJson: string = '';
  attachments: ArrayBuffer[] = [];

  constructor(type: SocketIoPacketType) {
    this.type = type;
  }
}

export class SocketIoEvent {
  readonly name: string;
  readonly argumentsJson: string;
  readonly namespace: string;
  readonly ackId: number;
  readonly attachments: ArrayBuffer[];

  constructor(name: string, argumentsJson: string = '[]', namespace: string = '/', ackId: number = -1,
    attachments: ArrayBuffer[] = []) {
    this.name = name;
    this.argumentsJson = argumentsJson;
    this.namespace = namespace;
    this.ackId = ackId;
    this.attachments = attachments;
  }
}

export class SocketIoCodec {
  encode(packet: SocketIoPacket): string {
    let result: string = `${packet.type}`;
    if (packet.type === SocketIoPacketType.BINARY_EVENT || packet.type === SocketIoPacketType.BINARY_ACK) {
      result += `${packet.attachmentsExpected}-`;
    }
    if (packet.namespace !== '/') result += `${packet.namespace},`;
    if (packet.ackId >= 0) result += `${packet.ackId}`;
    result += packet.dataJson;
    return result;
  }

  decode(value: string): SocketIoPacket {
    if (value.length === 0) throw new Error('Socket.IO packet 不能为空');
    let cursor: number = 0;
    const typeNumber: number = parseInt(value[cursor++], 10);
    if (!Number.isInteger(typeNumber) || typeNumber < SocketIoPacketType.CONNECT ||
      typeNumber > SocketIoPacketType.BINARY_ACK) throw new Error('未知 Socket.IO packet type');
    const packet: SocketIoPacket = new SocketIoPacket(typeNumber as SocketIoPacketType);
    if (packet.type === SocketIoPacketType.BINARY_EVENT || packet.type === SocketIoPacketType.BINARY_ACK) {
      const dash: number = value.indexOf('-', cursor);
      if (dash < 0) throw new Error('Socket.IO binary packet 缺少附件数量');
      packet.attachmentsExpected = parseInt(value.substring(cursor, dash), 10);
      if (!Number.isSafeInteger(packet.attachmentsExpected) || packet.attachmentsExpected < 0) {
        throw new Error('Socket.IO binary attachment 数量非法');
      }
      cursor = dash + 1;
    }
    if (cursor < value.length && value[cursor] === '/') {
      const comma: number = value.indexOf(',', cursor);
      if (comma < 0) {
        packet.namespace = value.substring(cursor);
        cursor = value.length;
      } else {
        packet.namespace = value.substring(cursor, comma);
        cursor = comma + 1;
      }
    }
    const idStart: number = cursor;
    while (cursor < value.length && value.charCodeAt(cursor) >= 48 && value.charCodeAt(cursor) <= 57) cursor += 1;
    if (cursor > idStart) packet.ackId = parseInt(value.substring(idStart, cursor), 10);
    packet.dataJson = value.substring(cursor);
    return packet;
  }

  eventToPacket(event: SocketIoEvent): SocketIoPacket {
    const args: string = event.argumentsJson.trim();
    if (!args.startsWith('[') || !args.endsWith(']')) throw new Error('Socket.IO event argumentsJson 必须是 JSON 数组');
    const hasArguments: boolean = args.substring(1, args.length - 1).trim().length > 0;
    const type: SocketIoPacketType = event.attachments.length > 0 ? SocketIoPacketType.BINARY_EVENT :
      SocketIoPacketType.EVENT;
    const packet: SocketIoPacket = new SocketIoPacket(type);
    packet.namespace = event.namespace;
    packet.ackId = event.ackId;
    packet.attachmentsExpected = event.attachments.length;
    packet.attachments = [...event.attachments];
    packet.dataJson = `[${JSON.stringify(event.name)}${hasArguments ? `,${args.substring(1, args.length - 1)}` : ''}]`;
    return packet;
  }

  packetToEvent(packet: SocketIoPacket): SocketIoEvent {
    if (packet.type !== SocketIoPacketType.EVENT && packet.type !== SocketIoPacketType.BINARY_EVENT) {
      throw new Error('不是 Socket.IO EVENT packet');
    }
    const values: Object[] = JSON.parse(packet.dataJson) as Object[];
    if (values.length === 0 || typeof values[0] !== 'string') throw new Error('Socket.IO EVENT 缺少事件名');
    return new SocketIoEvent(values[0] as string, JSON.stringify(values.slice(1)), packet.namespace,
      packet.ackId, [...packet.attachments]);
  }
}

export class SocketIoPacketDecoder {
  private readonly codec: SocketIoCodec = new SocketIoCodec();
  private pending?: SocketIoPacket;

  push(data: WsData): SocketIoPacket[] {
    if (typeof data === 'string') {
      const packet: SocketIoPacket = this.codec.decode(data);
      if ((packet.type === SocketIoPacketType.BINARY_EVENT || packet.type === SocketIoPacketType.BINARY_ACK) &&
        packet.attachmentsExpected > 0) {
        if (this.pending !== undefined) throw new Error('上一个 Socket.IO binary packet 尚未完成');
        this.pending = packet;
        return [];
      }
      return [packet];
    }
    const pending: SocketIoPacket | undefined = this.pending;
    if (pending === undefined) throw new Error('收到没有占位 packet 的 Socket.IO binary attachment');
    pending.attachments.push(data);
    if (pending.attachments.length < pending.attachmentsExpected) return [];
    this.pending = undefined;
    return [pending];
  }

  reset(): void { this.pending = undefined; }
}

export class SocketIoWireCodec {
  private readonly engine: EngineIoCodec = new EngineIoCodec();
  private readonly socket: SocketIoCodec = new SocketIoCodec();

  encodePacket(packet: SocketIoPacket): WsData[] {
    const frames: WsData[] = [this.engine.encode(new EngineIoPacket(EngineIoPacketType.MESSAGE,
      this.socket.encode(packet)))];
    for (let i: number = 0; i < packet.attachments.length; i++) frames.push(packet.attachments[i]);
    return frames;
  }

  decodeTextFrame(data: string): EngineIoPacket {
    return this.engine.decode(data);
  }
}
