import { describe, expect, it } from '@ohos/hypium';
import { StompCodec, StompCommand, StompDecodeBatch, StompFrame,
  StompFrameDecoder } from '../main/ets/protocol/stomp/StompCodec';
import { WsData } from '../main/ets/core/Types';

export default function stompTest(): void {
  describe('STOMP 1.2 codec', (): void => {
    it('round trips escaped text frames', 0, (): void => {
      const headers: Record<string, string> = {
        'destination': '/queue/a:b',
        'x-note': 'line1\nline2'
      };
      const frame: StompFrame = new StompFrame(StompCommand.SEND, headers, 'hello');
      const codec: StompCodec = new StompCodec();
      expect(codec.encodeText('abc').byteLength).assertEqual(3);
      const encoded: WsData = codec.encode(frame);
      const decoder: StompFrameDecoder = new StompFrameDecoder();
      const batch: StompDecodeBatch = decoder.push(encoded);
      expect(decoder.pendingBytes() > 0 || batch.frames.length > 0).assertTrue();
      expect(batch.frames.length).assertEqual(1);
      expect(batch.frames[0].headers['destination']).assertEqual('/queue/a:b');
      expect(batch.frames[0].headers['x-note']).assertEqual('line1\nline2');
      expect(batch.frames[0].body).assertEqual('hello');
    });

    it('decodes fragmented frames and heartbeats', 0, (): void => {
      const decoder: StompFrameDecoder = new StompFrameDecoder();
      const first: StompDecodeBatch = decoder.push('\nMESSAGE\nsubscription:s1\n\nhel');
      expect(first.heartbeatCount).assertEqual(1);
      expect(first.frames.length).assertEqual(0);
      const second: StompDecodeBatch = decoder.push('lo\u0000');
      expect(second.frames.length).assertEqual(1);
      expect(second.frames[0].body).assertEqual('hello');
    });

    it('preserves binary bodies with content length', 0, (): void => {
      const bytes: Uint8Array = new Uint8Array([0, 1, 2, 255]);
      const headers: Record<string, string> = { 'content-type': 'application/octet-stream' };
      const encoded: WsData = new StompCodec().encode(
        new StompFrame(StompCommand.SEND, headers, bytes.buffer));
      const frame: StompFrame = new StompFrameDecoder().push(encoded).frames[0];
      expect(typeof frame.body === 'string').assertFalse();
      if (typeof frame.body !== 'string') {
        const decoded: Uint8Array = new Uint8Array(frame.body);
        expect(decoded.byteLength).assertEqual(4);
        expect(decoded[3]).assertEqual(255);
      }
    });
  });
}
