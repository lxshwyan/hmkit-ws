import { NativeWsServerCapability, NativeWsTransportFactory } from '@hmkit/ws-native';

@Entry
@Component
struct Index {
  private capability: NativeWsServerCapability = new NativeWsServerCapability();
  private factory: NativeWsTransportFactory = new NativeWsTransportFactory();
  build() { Column() { Text(`native consumer: ${this.capability.supported()} ${this.factory.create() !== undefined}`) } }
}
