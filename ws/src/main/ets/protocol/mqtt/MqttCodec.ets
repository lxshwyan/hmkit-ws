import { Utf8Codec, WsByteReader, WsByteWriter } from '../../core/Bytes';
import { WsData } from '../../core/Types';

function copyArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const buffer: ArrayBuffer = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(buffer).set(bytes);
  return buffer;
}

export enum MqttProtocolVersion {
  V3_1_1 = 4,
  V5 = 5
}

export enum MqttPacketType {
  CONNECT = 1,
  CONNACK = 2,
  PUBLISH = 3,
  PUBACK = 4,
  PUBREC = 5,
  PUBREL = 6,
  PUBCOMP = 7,
  SUBSCRIBE = 8,
  SUBACK = 9,
  UNSUBSCRIBE = 10,
  UNSUBACK = 11,
  PINGREQ = 12,
  PINGRESP = 13,
  DISCONNECT = 14,
  AUTH = 15
}

export enum MqttQoS {
  AT_MOST_ONCE = 0,
  AT_LEAST_ONCE = 1,
  EXACTLY_ONCE = 2
}

export enum MqttPropertyType {
  BYTE = 'byte',
  UINT16 = 'uint16',
  UINT32 = 'uint32',
  VARIABLE_INT = 'variable_int',
  BINARY = 'binary',
  UTF8 = 'utf8',
  UTF8_PAIR = 'utf8_pair'
}

export enum MqttPropertyId {
  PAYLOAD_FORMAT_INDICATOR = 0x01,
  MESSAGE_EXPIRY_INTERVAL = 0x02,
  CONTENT_TYPE = 0x03,
  RESPONSE_TOPIC = 0x08,
  CORRELATION_DATA = 0x09,
  SUBSCRIPTION_IDENTIFIER = 0x0B,
  SESSION_EXPIRY_INTERVAL = 0x11,
  ASSIGNED_CLIENT_IDENTIFIER = 0x12,
  SERVER_KEEP_ALIVE = 0x13,
  AUTHENTICATION_METHOD = 0x15,
  AUTHENTICATION_DATA = 0x16,
  REQUEST_PROBLEM_INFORMATION = 0x17,
  WILL_DELAY_INTERVAL = 0x18,
  REQUEST_RESPONSE_INFORMATION = 0x19,
  RESPONSE_INFORMATION = 0x1A,
  SERVER_REFERENCE = 0x1C,
  REASON_STRING = 0x1F,
  RECEIVE_MAXIMUM = 0x21,
  TOPIC_ALIAS_MAXIMUM = 0x22,
  TOPIC_ALIAS = 0x23,
  MAXIMUM_QOS = 0x24,
  RETAIN_AVAILABLE = 0x25,
  USER_PROPERTY = 0x26,
  MAXIMUM_PACKET_SIZE = 0x27,
  WILDCARD_SUBSCRIPTION_AVAILABLE = 0x28,
  SUBSCRIPTION_IDENTIFIERS_AVAILABLE = 0x29,
  SHARED_SUBSCRIPTION_AVAILABLE = 0x2A
}

export class MqttProperty {
  readonly id: number;
  readonly type: MqttPropertyType;
  numberValue: number = 0;
  stringValue: string = '';
  pairName: string = '';
  pairValue: string = '';
  binaryValue: ArrayBuffer = new ArrayBuffer(0);

  constructor(id: number, type: MqttPropertyType) {
    this.id = id;
    this.type = type;
  }

  static number(id: number, type: MqttPropertyType, value: number): MqttProperty {
    const property: MqttProperty = new MqttProperty(id, type); property.numberValue = value; return property;
  }
  static text(id: number, value: string): MqttProperty {
    const property: MqttProperty = new MqttProperty(id, MqttPropertyType.UTF8);
    property.stringValue = value; return property;
  }
  static pair(id: number, name: string, value: string): MqttProperty {
    const property: MqttProperty = new MqttProperty(id, MqttPropertyType.UTF8_PAIR);
    property.pairName = name; property.pairValue = value; return property;
  }
  static binary(id: number, value: ArrayBuffer): MqttProperty {
    const property: MqttProperty = new MqttProperty(id, MqttPropertyType.BINARY);
    property.binaryValue = value; return property;
  }
}

export class MqttWillOptions {
  topic: string;
  payload: ArrayBuffer;
  qos: MqttQoS = MqttQoS.AT_MOST_ONCE;
  retain: boolean = false;
  properties: MqttProperty[] = [];

  constructor(topic: string, payload: ArrayBuffer = new ArrayBuffer(0)) {
    this.topic = topic;
    this.payload = payload;
  }
}

export class MqttConnectOptions {
  clientId: string;
  protocolVersion: MqttProtocolVersion = MqttProtocolVersion.V3_1_1;
  cleanStart: boolean = true;
  keepAliveSeconds: number = 60;
  username: string = '';
  password: string = '';
  will?: MqttWillOptions;
  properties: MqttProperty[] = [];

  constructor(clientId: string) { this.clientId = clientId; }
}

export class MqttPublishPacket {
  topic: string;
  payload: ArrayBuffer;
  qos: MqttQoS = MqttQoS.AT_MOST_ONCE;
  retain: boolean = false;
  duplicate: boolean = false;
  packetId: number = 0;
  properties: MqttProperty[] = [];

  constructor(topic: string, payload: ArrayBuffer = new ArrayBuffer(0)) {
    this.topic = topic;
    this.payload = payload;
  }
}

export class MqttSubscription {
  readonly topicFilter: string;
  qos: MqttQoS = MqttQoS.AT_MOST_ONCE;
  noLocal: boolean = false;
  retainAsPublished: boolean = false;
  retainHandling: number = 0;

  constructor(topicFilter: string) { this.topicFilter = topicFilter; }
}

export class MqttDecodedPacket {
  readonly type: MqttPacketType;
  flags: number = 0;
  packetId: number = 0;
  reasonCode: number = 0;
  sessionPresent: boolean = false;
  topic: string = '';
  payload: ArrayBuffer = new ArrayBuffer(0);
  qos: MqttQoS = MqttQoS.AT_MOST_ONCE;
  retain: boolean = false;
  duplicate: boolean = false;
  properties: MqttProperty[] = [];
  reasonCodes: number[] = [];

  constructor(type: MqttPacketType) { this.type = type; }
}

export class MqttPropertyCodec {
  encode(properties: MqttProperty[]): Uint8Array {
    const body: WsByteWriter = new WsByteWriter();
    for (let i: number = 0; i < properties.length; i++) {
      const property: MqttProperty = properties[i];
      body.writeVariableInt(property.id);
      if (property.type === MqttPropertyType.BYTE) body.writeByte(property.numberValue);
      else if (property.type === MqttPropertyType.UINT16) body.writeUint16(property.numberValue);
      else if (property.type === MqttPropertyType.UINT32) body.writeUint32(property.numberValue);
      else if (property.type === MqttPropertyType.VARIABLE_INT) body.writeVariableInt(property.numberValue);
      else if (property.type === MqttPropertyType.UTF8) body.writeUtf8(property.stringValue);
      else if (property.type === MqttPropertyType.UTF8_PAIR) {
        body.writeUtf8(property.pairName); body.writeUtf8(property.pairValue);
      } else if (property.type === MqttPropertyType.BINARY) {
        const bytes: Uint8Array = new Uint8Array(property.binaryValue);
        body.writeUint16(bytes.byteLength); body.writeBytes(bytes);
      }
    }
    const result: WsByteWriter = new WsByteWriter();
    result.writeVariableInt(body.size());
    result.writeBytes(body.toUint8Array());
    return result.toUint8Array();
  }

  decode(reader: WsByteReader): MqttProperty[] {
    const length: number = reader.readVariableInt();
    const end: number = reader.offset() + length;
    const properties: MqttProperty[] = [];
    while (reader.offset() < end) {
      const id: number = reader.readVariableInt();
      const type: MqttPropertyType = this.typeFor(id);
      const property: MqttProperty = new MqttProperty(id, type);
      if (type === MqttPropertyType.BYTE) property.numberValue = reader.readByte();
      else if (type === MqttPropertyType.UINT16) property.numberValue = reader.readUint16();
      else if (type === MqttPropertyType.UINT32) property.numberValue = reader.readUint32();
      else if (type === MqttPropertyType.VARIABLE_INT) property.numberValue = reader.readVariableInt();
      else if (type === MqttPropertyType.UTF8) property.stringValue = reader.readUtf8();
      else if (type === MqttPropertyType.UTF8_PAIR) {
        property.pairName = reader.readUtf8(); property.pairValue = reader.readUtf8();
      } else {
        property.binaryValue = copyArrayBuffer(reader.readBytes(reader.readUint16()));
      }
      properties.push(property);
    }
    if (reader.offset() !== end) throw new Error('MQTT 5 properties 长度不一致');
    return properties;
  }

  typeFor(id: number): MqttPropertyType {
    if ([0x01, 0x17, 0x19, 0x24, 0x25, 0x28, 0x29, 0x2A].includes(id)) return MqttPropertyType.BYTE;
    if ([0x13, 0x21, 0x22, 0x23].includes(id)) return MqttPropertyType.UINT16;
    if ([0x02, 0x11, 0x18, 0x27].includes(id)) return MqttPropertyType.UINT32;
    if (id === 0x0B) return MqttPropertyType.VARIABLE_INT;
    if ([0x09, 0x16].includes(id)) return MqttPropertyType.BINARY;
    if (id === 0x26) return MqttPropertyType.UTF8_PAIR;
    if ([0x03, 0x08, 0x12, 0x15, 0x1A, 0x1C, 0x1F].includes(id)) return MqttPropertyType.UTF8;
    throw new Error(`未知 MQTT 5 property：${id}`);
  }
}

export class MqttCodec {
  private readonly propertyCodec: MqttPropertyCodec = new MqttPropertyCodec();

  encodeConnect(options: MqttConnectOptions): ArrayBuffer {
    if (options.clientId.length === 0 && !options.cleanStart) throw new Error('持久会话必须提供 clientId');
    const variable: WsByteWriter = new WsByteWriter();
    variable.writeUtf8('MQTT');
    variable.writeByte(options.protocolVersion);
    let flags: number = options.cleanStart ? 0x02 : 0;
    if (options.will !== undefined) {
      flags |= 0x04 | ((options.will.qos & 0x03) << 3);
      if (options.will.retain) flags |= 0x20;
    }
    if (options.password.length > 0) flags |= 0x40;
    if (options.username.length > 0) flags |= 0x80;
    variable.writeByte(flags);
    variable.writeUint16(options.keepAliveSeconds);
    if (options.protocolVersion === MqttProtocolVersion.V5) {
      variable.writeBytes(this.propertyCodec.encode(options.properties));
    }
    const payload: WsByteWriter = new WsByteWriter();
    payload.writeUtf8(options.clientId);
    if (options.will !== undefined) {
      if (options.protocolVersion === MqttProtocolVersion.V5) {
        payload.writeBytes(this.propertyCodec.encode(options.will.properties));
      }
      payload.writeUtf8(options.will.topic);
      const willBytes: Uint8Array = new Uint8Array(options.will.payload);
      payload.writeUint16(willBytes.byteLength); payload.writeBytes(willBytes);
    }
    if (options.username.length > 0) payload.writeUtf8(options.username);
    if (options.password.length > 0) payload.writeUtf8(options.password);
    return this.wrap(MqttPacketType.CONNECT << 4, variable.toUint8Array(), payload.toUint8Array());
  }

  encodePublish(packet: MqttPublishPacket, version: MqttProtocolVersion): ArrayBuffer {
    const topicAlias: MqttProperty | undefined = this.findProperty(packet.properties, MqttPropertyId.TOPIC_ALIAS);
    if (packet.topic.length === 0 && (version !== MqttProtocolVersion.V5 || topicAlias === undefined)) {
      throw new Error('MQTT PUBLISH topic 不能为空，除非 MQTT 5 使用有效 Topic Alias');
    }
    if (packet.qos !== MqttQoS.AT_MOST_ONCE && (packet.packetId <= 0 || packet.packetId > 65535)) {
      throw new Error('QoS 1/2 PUBLISH 需要有效 packetId');
    }
    const variable: WsByteWriter = new WsByteWriter();
    variable.writeUtf8(packet.topic);
    if (packet.qos !== MqttQoS.AT_MOST_ONCE) variable.writeUint16(packet.packetId);
    if (version === MqttProtocolVersion.V5) variable.writeBytes(this.propertyCodec.encode(packet.properties));
    const flags: number = (packet.duplicate ? 0x08 : 0) | ((packet.qos & 0x03) << 1) |
      (packet.retain ? 0x01 : 0);
    return this.wrap((MqttPacketType.PUBLISH << 4) | flags, variable.toUint8Array(),
      new Uint8Array(packet.payload));
  }

  encodeSubscribe(packetId: number, subscriptions: MqttSubscription[], version: MqttProtocolVersion,
    properties: MqttProperty[] = []): ArrayBuffer {
    this.requirePacketId(packetId);
    if (subscriptions.length === 0) throw new Error('MQTT SUBSCRIBE 至少包含一个订阅');
    const variable: WsByteWriter = new WsByteWriter();
    variable.writeUint16(packetId);
    if (version === MqttProtocolVersion.V5) variable.writeBytes(this.propertyCodec.encode(properties));
    const payload: WsByteWriter = new WsByteWriter();
    for (let i: number = 0; i < subscriptions.length; i++) {
      const subscription: MqttSubscription = subscriptions[i];
      payload.writeUtf8(subscription.topicFilter);
      let options: number = subscription.qos & 0x03;
      if (version === MqttProtocolVersion.V5) {
        if (subscription.noLocal) options |= 0x04;
        if (subscription.retainAsPublished) options |= 0x08;
        options |= (subscription.retainHandling & 0x03) << 4;
      }
      payload.writeByte(options);
    }
    return this.wrap((MqttPacketType.SUBSCRIBE << 4) | 0x02, variable.toUint8Array(), payload.toUint8Array());
  }

  encodeUnsubscribe(packetId: number, topicFilters: string[], version: MqttProtocolVersion,
    properties: MqttProperty[] = []): ArrayBuffer {
    this.requirePacketId(packetId);
    if (topicFilters.length === 0) throw new Error('MQTT UNSUBSCRIBE 至少包含一个 topic');
    const variable: WsByteWriter = new WsByteWriter();
    variable.writeUint16(packetId);
    if (version === MqttProtocolVersion.V5) variable.writeBytes(this.propertyCodec.encode(properties));
    const payload: WsByteWriter = new WsByteWriter();
    for (let i: number = 0; i < topicFilters.length; i++) payload.writeUtf8(topicFilters[i]);
    return this.wrap((MqttPacketType.UNSUBSCRIBE << 4) | 0x02, variable.toUint8Array(), payload.toUint8Array());
  }

  encodeAck(type: MqttPacketType, packetId: number, version: MqttProtocolVersion,
    reasonCode: number = 0, properties: MqttProperty[] = []): ArrayBuffer {
    this.requirePacketId(packetId);
    if (![MqttPacketType.PUBACK, MqttPacketType.PUBREC, MqttPacketType.PUBREL,
      MqttPacketType.PUBCOMP].includes(type)) throw new Error('MQTT ACK packet type 非法');
    const payload: WsByteWriter = new WsByteWriter();
    payload.writeUint16(packetId);
    if (version === MqttProtocolVersion.V5 && (reasonCode !== 0 || properties.length > 0)) {
      payload.writeByte(reasonCode); payload.writeBytes(this.propertyCodec.encode(properties));
    }
    const flags: number = type === MqttPacketType.PUBREL ? 0x02 : 0;
    return this.wrap((type << 4) | flags, payload.toUint8Array(), new Uint8Array(0));
  }

  encodePingRequest(): ArrayBuffer { return new Uint8Array([MqttPacketType.PINGREQ << 4, 0]).buffer; }

  encodeDisconnect(version: MqttProtocolVersion, reasonCode: number = 0,
    properties: MqttProperty[] = []): ArrayBuffer {
    if (version === MqttProtocolVersion.V3_1_1) {
      return new Uint8Array([MqttPacketType.DISCONNECT << 4, 0]).buffer;
    }
    if (reasonCode === 0 && properties.length === 0) {
      return new Uint8Array([MqttPacketType.DISCONNECT << 4, 0]).buffer;
    }
    const payload: WsByteWriter = new WsByteWriter();
    payload.writeByte(reasonCode); payload.writeBytes(this.propertyCodec.encode(properties));
    return this.wrap(MqttPacketType.DISCONNECT << 4, payload.toUint8Array(), new Uint8Array(0));
  }

  encodeAuth(reasonCode: number = 0, properties: MqttProperty[] = []): ArrayBuffer {
    if (reasonCode === 0 && properties.length === 0) {
      return new Uint8Array([MqttPacketType.AUTH << 4, 0]).buffer;
    }
    const payload: WsByteWriter = new WsByteWriter();
    payload.writeByte(reasonCode); payload.writeBytes(this.propertyCodec.encode(properties));
    return this.wrap(MqttPacketType.AUTH << 4, payload.toUint8Array(), new Uint8Array(0));
  }

  decodePacket(bytes: Uint8Array, version: MqttProtocolVersion): MqttDecodedPacket {
    const reader: WsByteReader = new WsByteReader(bytes);
    const fixed: number = reader.readByte();
    const type: MqttPacketType = (fixed >> 4) as MqttPacketType;
    const flags: number = fixed & 0x0F;
    this.validateFixedFlags(type, flags);
    const remainingLength: number = reader.readVariableInt();
    if (reader.remaining() !== remainingLength) throw new Error('MQTT Remaining Length 不一致');
    const packet: MqttDecodedPacket = new MqttDecodedPacket(type); packet.flags = flags;
    if (type === MqttPacketType.CONNACK) {
      packet.sessionPresent = (reader.readByte() & 0x01) !== 0;
      packet.reasonCode = reader.readByte();
      if (version === MqttProtocolVersion.V5) packet.properties = this.propertyCodec.decode(reader);
    } else if (type === MqttPacketType.PUBLISH) {
      packet.duplicate = (flags & 0x08) !== 0; packet.qos = ((flags >> 1) & 0x03) as MqttQoS;
      packet.retain = (flags & 0x01) !== 0; packet.topic = reader.readUtf8();
      if (packet.qos !== MqttQoS.AT_MOST_ONCE) packet.packetId = reader.readUint16();
      if (version === MqttProtocolVersion.V5) packet.properties = this.propertyCodec.decode(reader);
      packet.payload = copyArrayBuffer(reader.readBytes(reader.remaining()));
    } else if ([MqttPacketType.PUBACK, MqttPacketType.PUBREC, MqttPacketType.PUBREL,
      MqttPacketType.PUBCOMP].includes(type)) {
      packet.packetId = reader.readUint16();
      if (version === MqttProtocolVersion.V5 && reader.remaining() > 0) {
        packet.reasonCode = reader.readByte();
        if (reader.remaining() > 0) packet.properties = this.propertyCodec.decode(reader);
      }
    } else if (type === MqttPacketType.SUBACK || type === MqttPacketType.UNSUBACK) {
      packet.packetId = reader.readUint16();
      if (version === MqttProtocolVersion.V5) packet.properties = this.propertyCodec.decode(reader);
      while (reader.remaining() > 0) packet.reasonCodes.push(reader.readByte());
    } else if (type === MqttPacketType.DISCONNECT || type === MqttPacketType.AUTH) {
      if (reader.remaining() > 0) packet.reasonCode = reader.readByte();
      if (version === MqttProtocolVersion.V5 && reader.remaining() > 0) {
        packet.properties = this.propertyCodec.decode(reader);
      }
    } else if (reader.remaining() !== 0) {
      throw new Error(`MQTT packet type ${type} 包含未解析数据`);
    }
    return packet;
  }

  private wrap(fixedHeader: number, variable: Uint8Array, payload: Uint8Array): ArrayBuffer {
    const result: WsByteWriter = new WsByteWriter();
    result.writeByte(fixedHeader);
    result.writeVariableInt(variable.byteLength + payload.byteLength);
    result.writeBytes(variable); result.writeBytes(payload);
    return result.toArrayBuffer();
  }

  private requirePacketId(packetId: number): void {
    if (!Number.isSafeInteger(packetId) || packetId <= 0 || packetId > 65535) {
      throw new Error('MQTT packetId 必须在 1..65535');
    }
  }

  private findProperty(properties: MqttProperty[], id: number): MqttProperty | undefined {
    for (let i: number = 0; i < properties.length; i++) if (properties[i].id === id) return properties[i];
    return undefined;
  }

  private validateFixedFlags(type: MqttPacketType, flags: number): void {
    const expected: number = type === MqttPacketType.PUBREL || type === MqttPacketType.SUBSCRIBE ||
      type === MqttPacketType.UNSUBSCRIBE ? 0x02 : 0;
    if (type !== MqttPacketType.PUBLISH && flags !== expected) {
      throw new Error(`MQTT packet ${type} fixed-header flags 非法：${flags}`);
    }
    if (type === MqttPacketType.PUBLISH && ((flags >> 1) & 0x03) === 3) {
      throw new Error('MQTT PUBLISH QoS 3 非法');
    }
  }
}

export class MqttPacketDecoder {
  private readonly codec: MqttCodec = new MqttCodec();
  private readonly version: MqttProtocolVersion;
  private buffer: Uint8Array = new Uint8Array(0);
  private maximumPacketSize: number = 268435460;

  constructor(version: MqttProtocolVersion = MqttProtocolVersion.V3_1_1) { this.version = version; }
  setMaximumPacketSize(value: number): void {
    if (!Number.isSafeInteger(value) || value <= 0) throw new Error('MQTT maximum packet size 必须为正整数');
    this.maximumPacketSize = value;
  }

  push(data: WsData): MqttDecodedPacket[] {
    if (typeof data === 'string') throw new Error('MQTT over WebSocket 必须使用二进制消息');
    const incoming: Uint8Array = new Uint8Array(data);
    const joined: Uint8Array = new Uint8Array(this.buffer.byteLength + incoming.byteLength);
    joined.set(this.buffer, 0); joined.set(incoming, this.buffer.byteLength); this.buffer = joined;
    const packets: MqttDecodedPacket[] = [];
    while (this.buffer.byteLength >= 2) {
      let multiplier: number = 1;
      let remainingLength: number = 0;
      let cursor: number = 1;
      let completeLength: boolean = false;
      for (let count: number = 0; count < 4; count++) {
        if (cursor >= this.buffer.byteLength) break;
        const encoded: number = this.buffer[cursor++];
        remainingLength += (encoded & 0x7F) * multiplier;
        if ((encoded & 0x80) === 0) { completeLength = true; break; }
        multiplier *= 128;
      }
      if (!completeLength) break;
      const packetLength: number = cursor + remainingLength;
      if (packetLength > this.maximumPacketSize) throw new Error(`MQTT packet 超过接收上限：${packetLength}`);
      if (this.buffer.byteLength < packetLength) break;
      packets.push(this.codec.decodePacket(this.buffer.slice(0, packetLength), this.version));
      this.buffer = this.buffer.slice(packetLength);
    }
    return packets;
  }

  reset(): void { this.buffer = new Uint8Array(0); }
}
