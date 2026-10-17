import { NetworkKitWsServerCapability, NetworkKitWsServerFactory } from '@hmkit/ws-server';

@Entry
@Component
struct Index {
  private capability: NetworkKitWsServerCapability = new NetworkKitWsServerCapability();
  private factory: NetworkKitWsServerFactory = new NetworkKitWsServerFactory();
  build() { Column() { Text(`server consumer: ${this.capability.supported()} ${this.factory.create().peers().length}`) } }
}
