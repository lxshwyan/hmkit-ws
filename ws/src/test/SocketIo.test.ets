import { describe, expect, it } from '@ohos/hypium';
import { EngineIoCodec, EngineIoOpenPacket, EngineIoPacket, EngineIoPacketType, SocketIoCodec,
  SocketIoEvent, SocketIoPacket, SocketIoPacketDecoder, SocketIoPacketType,
  SocketIoWireCodec } from '../main/ets/protocol/socketio/SocketIoCodec';
import { WsData } from '../main/ets/core/Types';
import { EngineIoPollingPayloadCodec } from '../main/ets/protocol/socketio/PollingTransport';

export default function socketIoTest(): void {
  describe('Socket.IO v4 codec', (): void => {
    it('parses Engine.IO handshake and heartbeat packets', 0, (): void => {
      const codec: EngineIoCodec = new EngineIoCodec();
      const packet: EngineIoPacket = codec.decode(
        '0{"sid":"abc","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}');
      const open: EngineIoOpenPacket = codec.decodeOpen(packet);
      expect(open.sid).assertEqual('abc');
      expect(codec.decode('2probe').type).assertEqual(EngineIoPacketType.PING);
      expect(codec.encode(new EngineIoPacket(EngineIoPacketType.PONG, 'probe'))).assertEqual('3probe');
    });

    it('round trips namespace event and acknowledgement id', 0, (): void => {
      const codec: SocketIoCodec = new SocketIoCodec();
      const packet: SocketIoPacket = codec.eventToPacket(
        new SocketIoEvent('chat', '["hello",2]', '/room', 7));
      const encoded: string = codec.encode(packet);
      expect(encoded).assertEqual('2/room,7["chat","hello",2]');
      const event: SocketIoEvent = codec.packetToEvent(codec.decode(encoded));
      expect(event.name).assertEqual('chat');
      expect(event.namespace).assertEqual('/room');
      expect(event.ackId).assertEqual(7);
      expect(event.argumentsJson).assertEqual('["hello",2]');
    });

    it('assembles binary attachments after the placeholder packet', 0, (): void => {
      const decoder: SocketIoPacketDecoder = new SocketIoPacketDecoder();
      const first: SocketIoPacket[] = decoder.push(
        '51-["file",{"_placeholder":true,"num":0}]');
      expect(first.length).assertEqual(0);
      const attachment: ArrayBuffer = new ArrayBuffer(3);
      new Uint8Array(attachment).set([1, 2, 3]);
      const completed: SocketIoPacket[] = decoder.push(attachment);
      expect(completed.length).assertEqual(1);
      expect(completed[0].attachments.length).assertEqual(1);
      expect(new Uint8Array(completed[0].attachments[0])[2]).assertEqual(3);
    });

    it('wraps Socket.IO packets in Engine.IO message frames', 0, (): void => {
      const packet: SocketIoPacket = new SocketIoPacket(SocketIoPacketType.CONNECT);
      packet.namespace = '/admin'; packet.dataJson = '{"token":"x"}';
      const frames: WsData[] = new SocketIoWireCodec().encodePacket(packet);
      expect(frames.length).assertEqual(1);
      expect(frames[0]).assertEqual('40/admin,{"token":"x"}');
    });

    it('frames polling packets and base64 binary with record separators', 0, (): void => {
      const codec: EngineIoPollingPayloadCodec = new EngineIoPollingPayloadCodec();
      const binary: ArrayBuffer = new ArrayBuffer(4);
      new Uint8Array(binary).set([1, 2, 3, 4]);
      const packets: WsData[] = [];
      packets.push('4hello'); packets.push('2'); packets.push(binary);
      const payload: string = codec.encode(packets);
      expect(payload).assertEqual('4hello\u001e2\u001ebAQIDBA==');
      const decoded: WsData[] = codec.decode(payload);
      expect(decoded.length).assertEqual(3);
      expect(decoded[0]).assertEqual('4hello');
      expect(new Uint8Array(decoded[2] as ArrayBuffer)[3]).assertEqual(4);
    });
  });
}
