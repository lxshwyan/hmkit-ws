import { describe, expect, it } from '@ohos/hypium';
import { MqttCodec, MqttConnectOptions, MqttDecodedPacket, MqttPacketDecoder, MqttPacketType,
  MqttProperty, MqttPropertyType, MqttProtocolVersion, MqttPublishPacket, MqttQoS,
  MqttSubscription } from '../main/ets/protocol/mqtt/MqttCodec';

function bufferOf(values: number[]): ArrayBuffer {
  const buffer: ArrayBuffer = new ArrayBuffer(values.length);
  new Uint8Array(buffer).set(values);
  return buffer;
}

export default function mqttTest(): void {
  describe('MQTT codec', (): void => {
    it('encodes MQTT 3.1.1 CONNECT', 0, (): void => {
      const options: MqttConnectOptions = new MqttConnectOptions('client-1');
      options.keepAliveSeconds = 30;
      const bytes: Uint8Array = new Uint8Array(new MqttCodec().encodeConnect(options));
      expect(bytes[0]).assertEqual(0x10);
      expect(bytes[2]).assertEqual(0);
      expect(bytes[3]).assertEqual(4);
      expect(bytes[4]).assertEqual(77);
      expect(bytes[8]).assertEqual(MqttProtocolVersion.V3_1_1);
    });

    it('round trips QoS 1 PUBLISH', 0, (): void => {
      const publish: MqttPublishPacket = new MqttPublishPacket('chat/room', bufferOf([1, 2, 3]));
      publish.qos = MqttQoS.AT_LEAST_ONCE; publish.packetId = 42; publish.retain = true;
      const encoded: ArrayBuffer = new MqttCodec().encodePublish(publish, MqttProtocolVersion.V3_1_1);
      const decoded: MqttDecodedPacket = new MqttCodec().decodePacket(
        new Uint8Array(encoded), MqttProtocolVersion.V3_1_1);
      expect(decoded.type).assertEqual(MqttPacketType.PUBLISH);
      expect(decoded.topic).assertEqual('chat/room');
      expect(decoded.packetId).assertEqual(42);
      expect(decoded.qos).assertEqual(MqttQoS.AT_LEAST_ONCE);
      expect(new Uint8Array(decoded.payload)[2]).assertEqual(3);
    });

    it('encodes and decodes MQTT 5 properties', 0, (): void => {
      const publish: MqttPublishPacket = new MqttPublishPacket('sensor/temp', bufferOf([50, 51]));
      publish.properties.push(MqttProperty.text(0x03, 'text/plain'));
      publish.properties.push(MqttProperty.pair(0x26, 'trace', 'abc'));
      publish.properties.push(MqttProperty.number(0x02, MqttPropertyType.UINT32, 60));
      const encoded: ArrayBuffer = new MqttCodec().encodePublish(publish, MqttProtocolVersion.V5);
      const decoded: MqttDecodedPacket = new MqttCodec().decodePacket(new Uint8Array(encoded), MqttProtocolVersion.V5);
      expect(decoded.properties.length).assertEqual(3);
      expect(decoded.properties[0].stringValue).assertEqual('text/plain');
      expect(decoded.properties[1].pairName).assertEqual('trace');
      expect(decoded.properties[2].numberValue).assertEqual(60);
    });

    it('assembles fragmented MQTT packets', 0, (): void => {
      const publish: MqttPublishPacket = new MqttPublishPacket('a', bufferOf([9, 8, 7]));
      const bytes: Uint8Array = new Uint8Array(
        new MqttCodec().encodePublish(publish, MqttProtocolVersion.V3_1_1));
      const firstBuffer: ArrayBuffer = new ArrayBuffer(2);
      new Uint8Array(firstBuffer).set(bytes.slice(0, 2));
      const secondBuffer: ArrayBuffer = new ArrayBuffer(bytes.byteLength - 2);
      new Uint8Array(secondBuffer).set(bytes.slice(2));
      const decoder: MqttPacketDecoder = new MqttPacketDecoder();
      expect(decoder.push(firstBuffer).length).assertEqual(0);
      expect(decoder.push(secondBuffer).length).assertEqual(1);
    });

    it('encodes MQTT 5 subscription flags', 0, (): void => {
      const subscription: MqttSubscription = new MqttSubscription('devices/+/state');
      subscription.qos = MqttQoS.AT_LEAST_ONCE;
      subscription.noLocal = true; subscription.retainAsPublished = true; subscription.retainHandling = 2;
      const bytes: Uint8Array = new Uint8Array(new MqttCodec().encodeSubscribe(7,
        [subscription], MqttProtocolVersion.V5));
      expect(bytes[0]).assertEqual(0x82);
      expect(bytes[bytes.byteLength - 1]).assertEqual(0x2D);
    });

    it('round trips MQTT 5 enhanced-auth packets', 0, (): void => {
      const properties: MqttProperty[] = [];
      properties.push(MqttProperty.text(0x15, 'SCRAM-SHA-256'));
      properties.push(MqttProperty.binary(0x16, bufferOf([1, 2, 3])));
      const codec: MqttCodec = new MqttCodec();
      const packet: MqttDecodedPacket = codec.decodePacket(new Uint8Array(codec.encodeAuth(0x18, properties)),
        MqttProtocolVersion.V5);
      expect(packet.type).assertEqual(MqttPacketType.AUTH);
      expect(packet.reasonCode).assertEqual(0x18);
      expect(packet.properties[0].stringValue).assertEqual('SCRAM-SHA-256');
      expect(new Uint8Array(packet.properties[1].binaryValue)[2]).assertEqual(3);
    });

    it('rejects packets above the configured MQTT 5 receive size', 0, (): void => {
      const decoder: MqttPacketDecoder = new MqttPacketDecoder(MqttProtocolVersion.V5);
      decoder.setMaximumPacketSize(3);
      let failed: boolean = false;
      try { decoder.push(bufferOf([0x20, 0x02, 0x00, 0x00])); } catch (_error) { failed = true; }
      expect(failed).assertTrue();
    });
  });
}
