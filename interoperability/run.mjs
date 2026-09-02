import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import net from 'node:net';
import { Server } from 'socket.io';
import { io as createSocketClient } from 'socket.io-client';
import mqtt from 'mqtt';
import { Client as StompClient } from '@stomp/stompjs';
import WebSocket from 'ws';

function withTimeout(promise, milliseconds, label) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out after ${milliseconds}ms`)), milliseconds);
    })
  ]).finally(() => clearTimeout(timer));
}

async function waitForPort(port, host = '127.0.0.1') {
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    const ready = await new Promise((resolve) => {
      const socket = net.connect({ port, host });
      socket.once('connect', () => { socket.destroy(); resolve(true); });
      socket.once('error', () => resolve(false));
      socket.setTimeout(500, () => { socket.destroy(); resolve(false); });
    });
    if (ready) return;
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`Port ${host}:${port} did not become ready`);
}

async function waitForHttpEndpoint(url) {
  const deadline = Date.now() + 90000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.status > 0) return;
    } catch (_error) {}
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error(`HTTP endpoint ${url} did not become ready`);
}

async function testSocketIoTransport(transport) {
  const httpServer = createServer();
  const server = new Server(httpServer, { transports: ['polling', 'websocket'] });
  server.on('connection', (socket) => {
    socket.on('echo', (value, acknowledge) => acknowledge({ value, transport: socket.conn.transport.name }));
    socket.on('binary', (value, acknowledge) => acknowledge(Buffer.from(value).toString('hex')));
  });
  await new Promise((resolve) => httpServer.listen(0, '127.0.0.1', resolve));
  const address = httpServer.address();
  const client = createSocketClient(`http://127.0.0.1:${address.port}`, {
    transports: [transport],
    upgrade: false,
    reconnection: false
  });
  try {
    await withTimeout(new Promise((resolve, reject) => {
      client.once('connect', resolve); client.once('connect_error', reject);
    }), 10000, `Socket.IO ${transport} connect`);
    const response = await withTimeout(client.timeout(5000).emitWithAck('echo', 'hmkit'), 7000,
      `Socket.IO ${transport} ack`);
    assert.deepEqual(response, { value: 'hmkit', transport });
    const binary = await withTimeout(client.timeout(5000).emitWithAck('binary', Uint8Array.from([1, 2, 3, 4])),
      7000, `Socket.IO ${transport} binary ack`);
    assert.equal(binary, '01020304');
  } finally {
    client.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

async function testMqtt(url) {
  const client = await withTimeout(mqtt.connectAsync(url, {
    protocolVersion: 5,
    clientId: `hmkit-${url.includes('9002') ? 'ws' : 'tcp'}`,
    clean: false,
    properties: {
      sessionExpiryInterval: 60,
      receiveMaximum: 2,
      maximumPacketSize: 65536,
      topicAliasMaximum: 8,
      requestProblemInformation: true
    }
  }), 15000, `MQTT connect ${url}`);
  const topic = `hmkit/interoperability/${Date.now()}`;
  try {
    await client.subscribeAsync(topic, { qos: 2 });
    const received = withTimeout(new Promise((resolve) => {
      client.once('message', (incomingTopic, payload, packet) => resolve({ incomingTopic, payload, packet }));
    }), 10000, `MQTT message ${url}`);
    await client.publishAsync(topic, Buffer.from('mqtt5'), {
      qos: 2,
      properties: {
        payloadFormatIndicator: true,
        contentType: 'text/plain',
        messageExpiryInterval: 30,
        topicAlias: 1,
        userProperties: { suite: 'hmkit' }
      }
    });
    const message = await received;
    assert.equal(message.incomingTopic, topic);
    assert.equal(message.payload.toString(), 'mqtt5');
    assert.equal(message.packet.qos, 2);
  } finally {
    await client.endAsync(false, { reasonCode: 0, properties: { sessionExpiryInterval: 0 } });
  }
}

async function testStomp() {
  await waitForPort(15675);
  await waitForHttpEndpoint('http://127.0.0.1:15675/ws');
  const destination = `/topic/hmkit-${Date.now()}`;
  const message = await withTimeout(new Promise((resolve, reject) => {
    const client = new StompClient({
      brokerURL: 'ws://127.0.0.1:15675/ws',
      connectHeaders: { login: 'guest', passcode: 'guest' },
      reconnectDelay: 0,
      heartbeatIncoming: 2000,
      heartbeatOutgoing: 2000,
      webSocketFactory: () => new WebSocket('ws://127.0.0.1:15675/ws')
    });
    client.onStompError = (frame) => { client.deactivate(); reject(new Error(frame.headers.message)); };
    client.onWebSocketError = (error) => { client.deactivate(); reject(error); };
    client.onConnect = () => {
      client.subscribe(destination, async (frame) => {
        await client.deactivate(); resolve(frame.body);
      }, { ack: 'client-individual' });
      client.publish({ destination, body: 'stomp-1.2' });
    };
    client.activate();
  }), 20000, 'STOMP websocket round trip');
  assert.equal(message, 'stomp-1.2');
}

await waitForPort(18884);
await testSocketIoTransport('polling');
await testSocketIoTransport('websocket');
await testMqtt('mqtt://127.0.0.1:18884');
await testMqtt('ws://127.0.0.1:9002');
if (process.env.SKIP_STOMP !== '1') await testStomp();

console.log(process.env.SKIP_STOMP === '1'
  ? 'Interoperability PASS: Socket.IO polling/websocket, MQTT 5 TCP/websocket QoS2'
  : 'Interoperability PASS: Socket.IO polling/websocket, MQTT 5 TCP/websocket QoS2, STOMP 1.2 websocket');
