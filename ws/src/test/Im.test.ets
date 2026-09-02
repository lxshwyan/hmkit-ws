import { describe, expect, it } from '@ohos/hypium';
import { ImClient, ImClientObserver, ImClientOptions } from '../main/ets/im/ImClient';
import { ImGateway, ImGatewayObserver } from '../main/ets/im/ImGateway';
import { MemoryImMessageStore } from '../main/ets/im/ImStore';
import { ImPersistedConversation, ImPersistedMessage, ImStoreSnapshot,
  JsonImStoreSnapshotCodec } from '../main/ets/im/FileImStore';
import { ImConversation, ImConversationKind, ImMessage, ImMessageStatus, ImPresence, ImReceipt,
  ImSyncBatch, ImTyping } from '../main/ets/im/ImTypes';

class MockImGateway implements ImGateway {
  observer: ImGatewayObserver = new ImGatewayObserver();
  readonly sent: ImMessage[] = [];
  readonly receipts: ImReceipt[] = [];
  readonly typings: ImTyping[] = [];
  readonly batches: ImSyncBatch[] = [];
  setObserver(observer: ImGatewayObserver): void { this.observer = observer; }
  connect(): Promise<void> { return Promise.resolve(); }
  disconnect(): Promise<void> { return Promise.resolve(); }
  sendMessage(message: ImMessage): Promise<ImMessage> {
    this.sent.push(message);
    return Promise.resolve(new ImMessage(message.clientId, message.conversationId, message.senderId,
      message.contentType, message.payload, message.createdAt, `server-${message.clientId}`, 9,
      ImMessageStatus.SENT, message.attributes));
  }
  sendReceipt(receipt: ImReceipt): Promise<void> { this.receipts.push(receipt); return Promise.resolve(); }
  sendTyping(typing: ImTyping): Promise<void> { this.typings.push(typing); return Promise.resolve(); }
  sync(_cursor: string, _limit: number): Promise<ImSyncBatch> {
    return Promise.resolve(this.batches.length > 0 ? this.batches.shift() as ImSyncBatch : new ImSyncBatch());
  }
}

export default function imTest(): void {
  describe('hmkit ws im toolkit', (): void => {
    it('uses client IDs for idempotent outgoing messages', 0, async (): Promise<void> => {
      const gateway: MockImGateway = new MockImGateway();
      const options: ImClientOptions = new ImClientOptions();
      options.createClientId = (): string => 'client-1';
      const client: ImClient = new ImClient('u1', gateway, options);
      const message: ImMessage = await client.sendMessage('direct-1', 'text/plain', 'hello');
      expect(gateway.sent[0].clientId).assertEqual('client-1');
      expect(message.id).assertEqual('server-client-1');
      expect(message.status).assertEqual(ImMessageStatus.SENT);
    });

    it('deduplicates identical server events', 0, async (): Promise<void> => {
      const gateway: MockImGateway = new MockImGateway();
      const received: ImMessage[] = [];
      const client: ImClient = new ImClient('u1', gateway);
      client.addObserver(new ImClientObserver((message: ImMessage): void => { received.push(message); }));
      const message: ImMessage = new ImMessage('c1', 'room', 'u2', 'text/plain', 'hello', 1,
        'm1', 1, ImMessageStatus.SENT);
      gateway.observer.onMessage(message);
      await Promise.resolve();
      gateway.observer.onMessage(message);
      await Promise.resolve();
      expect(received.length).assertEqual(1);
    });

    it('applies read receipts to the replaceable store', 0, async (): Promise<void> => {
      const gateway: MockImGateway = new MockImGateway();
      const store: MemoryImMessageStore = new MemoryImMessageStore();
      const options: ImClientOptions = new ImClientOptions();
      options.messageStore = store;
      options.createClientId = (): string => 'c2';
      const client: ImClient = new ImClient('u1', gateway, options);
      const message: ImMessage = await client.sendMessage('room', 'text/plain', 'hello');
      await client.markRead(message);
      expect((await store.get(message.id))?.status).assertEqual(ImMessageStatus.READ);
      expect(gateway.receipts.length).assertEqual(1);
    });

    it('version-checks the replaceable IM persistence snapshot codec', 0, (): void => {
      const snapshot: ImStoreSnapshot = new ImStoreSnapshot(); snapshot.cursor = 'cursor-2';
      const message: ImPersistedMessage = new ImPersistedMessage();
      message.id = 'message'; message.sequence = 7; snapshot.messages.push(message);
      const conversation: ImPersistedConversation = new ImPersistedConversation();
      conversation.id = 'room'; conversation.kind = ImConversationKind.GROUP;
      snapshot.conversations.push(conversation);
      const codec: JsonImStoreSnapshotCodec = new JsonImStoreSnapshotCodec();
      const restored: ImStoreSnapshot = codec.decode(codec.encode(snapshot));
      expect(restored.cursor).assertEqual('cursor-2');
      expect(restored.messages[0].sequence).assertEqual(7);
      expect(restored.conversations[0].id).assertEqual('room');
    });
  });
}
