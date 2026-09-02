import coreTest from './Core.test';
import stompTest from './Stomp.test';
import socketIoTest from './SocketIo.test';
import mqttTest from './Mqtt.test';
import protocolClientsTest from './ProtocolClients.test';
import imTest from './Im.test';

export default function testsuite(): void {
  coreTest();
  stompTest();
  socketIoTest();
  mqttTest();
  protocolClientsTest();
  imTest();
}
