import * as native from 'libhmkit_ws_native.so';

export * from 'libhmkit_ws_native.so';
export { NativeWsServer, NativeWsServerCapability, NativeWsServerFactory,
  NativeWsTransport, NativeWsTransportFactory } from './NativeTransport';
export default native;
