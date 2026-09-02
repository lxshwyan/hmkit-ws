# Reference-server interoperability

This directory starts unmodified reference implementations and exercises the
same wire features that `@hmkit/ws` implements:

- Socket.IO 4 / Engine.IO 4 with polling and WebSocket, ACKs and binary data;
- Mosquitto MQTT 5 over TCP and WebSocket with QoS 2 and properties;
- RabbitMQ Web STOMP with STOMP 1.2 heartbeats and publish/subscribe.

Run the host-side server acceptance suite with:

```bash
../scripts/test-interop.sh
```

The host runner deliberately uses upstream clients. Its job is to prove that
the pinned servers and scenarios are healthy before a device run; it is not
reported as an ArkTS client pass. To exercise `@hmkit/ws` itself, expose the
Docker host to the HarmonyOS device/emulator and run the matching protocol
clients with these endpoints:

| Protocol | Endpoint | Required assertion |
|---|---|---|
| Socket.IO polling | `http://<host>:<socket-port>` | `echo` ACK includes `transport: polling`; binary ACK is `01020304` |
| Socket.IO WebSocket | `ws://<host>:<socket-port>` | same assertions with `transport: websocket` |
| MQTT 5 WebSocket | `ws://<host>:9002` | QoS 2 loopback on `hmkit/interoperability/#` with MQTT 5 properties |
| STOMP 1.2 | `ws://<host>:15675/ws` | guest publish/subscribe loopback on `/topic/hmkit-*` |

The Socket.IO server is process-local and therefore chooses an ephemeral port;
for a device run, change `run.mjs` to bind a fixed exposed port or point the
ArkTS client at an equivalent deployed Socket.IO 4 server. Mosquitto and
RabbitMQ ports are fixed by `compose.yaml`.

Native `.so` files must be tested on an OHOS target, not loaded by desktop
Node.js. Use `NativeWsTransportFactory` with the same Socket.IO/STOMP WebSocket
URLs, and use `NativeWsServerFactory` with a raw WebSocket echo client.
