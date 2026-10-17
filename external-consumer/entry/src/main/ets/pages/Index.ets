import { HmWebSocketClient, NetworkKitWsTransportFactory, WsState } from '@hmkit/ws';

@Entry
@Component
struct Index {
  private client: HmWebSocketClient = HmWebSocketClient.withUrl(
    'wss://example.test', new NetworkKitWsTransportFactory());
  build() { Column() { Text(`@hmkit/ws consumer: ${this.client.state() === WsState.IDLE}`) } }
}
