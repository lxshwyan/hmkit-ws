export class Utf8Codec {
  static encode(value: string): Uint8Array {
    const bytes: number[] = [];
    for (let i: number = 0; i < value.length; i++) {
      let codePoint: number = value.charCodeAt(i);
      if (codePoint >= 0xD800 && codePoint <= 0xDBFF && i + 1 < value.length) {
        const low: number = value.charCodeAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + (low - 0xDC00);
          i += 1;
        }
      }
      if (codePoint <= 0x7F) bytes.push(codePoint);
      else if (codePoint <= 0x7FF) {
        bytes.push(0xC0 | (codePoint >> 6));
        bytes.push(0x80 | (codePoint & 0x3F));
      } else if (codePoint <= 0xFFFF) {
        bytes.push(0xE0 | (codePoint >> 12));
        bytes.push(0x80 | ((codePoint >> 6) & 0x3F));
        bytes.push(0x80 | (codePoint & 0x3F));
      } else {
        bytes.push(0xF0 | (codePoint >> 18));
        bytes.push(0x80 | ((codePoint >> 12) & 0x3F));
        bytes.push(0x80 | ((codePoint >> 6) & 0x3F));
        bytes.push(0x80 | (codePoint & 0x3F));
      }
    }
    return new Uint8Array(bytes);
  }

  static decode(value: Uint8Array): string {
    let result: string = '';
    for (let i: number = 0; i < value.byteLength; i++) {
      const first: number = value[i];
      let codePoint: number;
      let extra: number;
      if (first <= 0x7F) { codePoint = first; extra = 0; }
      else if ((first & 0xE0) === 0xC0) { codePoint = first & 0x1F; extra = 1; }
      else if ((first & 0xF0) === 0xE0) { codePoint = first & 0x0F; extra = 2; }
      else if ((first & 0xF8) === 0xF0) { codePoint = first & 0x07; extra = 3; }
      else throw new Error('非法 UTF-8 起始字节');
      if (i + extra >= value.byteLength) throw new Error('UTF-8 数据不完整');
      for (let offset: number = 0; offset < extra; offset++) {
        const continuation: number = value[++i];
        if ((continuation & 0xC0) !== 0x80) throw new Error('非法 UTF-8 延续字节');
        codePoint = (codePoint << 6) | (continuation & 0x3F);
      }
      if (codePoint <= 0xFFFF) result += String.fromCharCode(codePoint);
      else {
        const adjusted: number = codePoint - 0x10000;
        result += String.fromCharCode(0xD800 + (adjusted >> 10));
        result += String.fromCharCode(0xDC00 + (adjusted & 0x3FF));
      }
    }
    return result;
  }
}

export class WsBase64Codec {
  private static readonly ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  static encode(bytes: Uint8Array): string {
    let result: string = '';
    for (let i: number = 0; i < bytes.byteLength; i += 3) {
      const first: number = bytes[i];
      const hasSecond: boolean = i + 1 < bytes.byteLength;
      const hasThird: boolean = i + 2 < bytes.byteLength;
      const second: number = hasSecond ? bytes[i + 1] : 0;
      const third: number = hasThird ? bytes[i + 2] : 0;
      const value: number = (first << 16) | (second << 8) | third;
      result += WsBase64Codec.ALPHABET[(value >> 18) & 0x3F];
      result += WsBase64Codec.ALPHABET[(value >> 12) & 0x3F];
      result += hasSecond ? WsBase64Codec.ALPHABET[(value >> 6) & 0x3F] : '=';
      result += hasThird ? WsBase64Codec.ALPHABET[value & 0x3F] : '=';
    }
    return result;
  }

  static decode(value: string): Uint8Array {
    const normalized: string = value.replace(/\s/g, '');
    if (normalized.length % 4 !== 0) throw new Error('Base64 长度非法');
    const result: number[] = [];
    for (let i: number = 0; i < normalized.length; i += 4) {
      const a: number = WsBase64Codec.index(normalized[i]);
      const b: number = WsBase64Codec.index(normalized[i + 1]);
      const c: number = normalized[i + 2] === '=' ? 0 : WsBase64Codec.index(normalized[i + 2]);
      const d: number = normalized[i + 3] === '=' ? 0 : WsBase64Codec.index(normalized[i + 3]);
      const packed: number = (a << 18) | (b << 12) | (c << 6) | d;
      result.push((packed >> 16) & 0xFF);
      if (normalized[i + 2] !== '=') result.push((packed >> 8) & 0xFF);
      if (normalized[i + 3] !== '=') result.push(packed & 0xFF);
    }
    return new Uint8Array(result);
  }

  private static index(value: string): number {
    const index: number = WsBase64Codec.ALPHABET.indexOf(value);
    if (index < 0) throw new Error(`非法 Base64 字符：${value}`);
    return index;
  }
}

export class WsByteWriter {
  private readonly values: number[] = [];

  writeByte(value: number): void { this.values.push(value & 0xFF); }
  writeUint16(value: number): void {
    this.writeByte((value >> 8) & 0xFF);
    this.writeByte(value & 0xFF);
  }
  writeUint32(value: number): void {
    this.writeByte((value >>> 24) & 0xFF);
    this.writeByte((value >>> 16) & 0xFF);
    this.writeByte((value >>> 8) & 0xFF);
    this.writeByte(value & 0xFF);
  }
  writeBytes(bytes: Uint8Array): void {
    for (let i: number = 0; i < bytes.byteLength; i++) this.values.push(bytes[i]);
  }
  writeUtf8(value: string): void {
    const bytes: Uint8Array = Utf8Codec.encode(value);
    if (bytes.byteLength > 65535) throw new Error('UTF-8 字符串超过 65535 字节');
    this.writeUint16(bytes.byteLength);
    this.writeBytes(bytes);
  }
  writeVariableInt(value: number): void {
    if (!Number.isSafeInteger(value) || value < 0 || value > 268435455) throw new Error('MQTT Variable Byte Integer 超界');
    let remaining: number = value;
    do {
      let encoded: number = remaining % 128;
      remaining = Math.floor(remaining / 128);
      if (remaining > 0) encoded |= 0x80;
      this.writeByte(encoded);
    } while (remaining > 0);
  }
  size(): number { return this.values.length; }
  toUint8Array(): Uint8Array { return new Uint8Array(this.values); }
  toArrayBuffer(): ArrayBuffer { return this.toUint8Array().buffer; }
}

export class WsByteReader {
  private readonly bytes: Uint8Array;
  private offsetValue: number = 0;

  constructor(bytes: Uint8Array) { this.bytes = bytes; }
  offset(): number { return this.offsetValue; }
  remaining(): number { return this.bytes.byteLength - this.offsetValue; }
  readByte(): number {
    this.require(1);
    return this.bytes[this.offsetValue++];
  }
  readUint16(): number { return (this.readByte() << 8) | this.readByte(); }
  readUint32(): number {
    return ((this.readByte() * 0x1000000) + (this.readByte() << 16) +
      (this.readByte() << 8) + this.readByte()) >>> 0;
  }
  readBytes(length: number): Uint8Array {
    this.require(length);
    const result: Uint8Array = this.bytes.slice(this.offsetValue, this.offsetValue + length);
    this.offsetValue += length;
    return result;
  }
  readUtf8(): string { return Utf8Codec.decode(this.readBytes(this.readUint16())); }
  readVariableInt(): number {
    let multiplier: number = 1;
    let value: number = 0;
    let count: number = 0;
    while (true) {
      const encoded: number = this.readByte();
      value += (encoded & 0x7F) * multiplier;
      count += 1;
      if ((encoded & 0x80) === 0) return value;
      if (count >= 4) throw new Error('MQTT Variable Byte Integer 超过四字节');
      multiplier *= 128;
    }
  }
  skip(length: number): void { this.require(length); this.offsetValue += length; }

  private require(length: number): void {
    if (length < 0 || this.offsetValue + length > this.bytes.byteLength) throw new Error('二进制数据不完整');
  }
}
