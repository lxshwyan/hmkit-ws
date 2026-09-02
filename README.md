# @hmkit/ws

面向 HarmonyOS NEXT / OpenHarmony 的分层实时通信套件。核心目标是：API 清晰、协议可替换、策略可注入，并且不让高层协议或高版本系统能力污染基础 WebSocket 客户端。

> 当前版本 `0.1.1` 是开发预览版；`0.1.0` 已发布到 OHPM，`0.1.1` 补充中文包文档。

## 安装

```shell
ohpm install @hmkit/ws
```

## 当前能力

- API 12+ 纯 ArkTS WebSocket 核心：显式状态机、网络感知、自动重连、连接超时、串行发送。
- 可定制心跳：心跳内容、响应匹配、间隔、超时和是否消费响应都不是固定 JSON 格式。
- 可定制离线行为：失败、丢弃或有界排队；支持容量、字节数、TTL 和溢出策略。
- 持久化是显式选择：默认内存队列，只有主动创建 `FileWsOutboundQueue` 才写文件。
- 文本、二进制、JSON 和自定义 typed codec；JSON 只是可选 codec，不是传输层约束。
- STOMP 1.2：增量帧解析、版本协商、心跳、订阅、ACK/NACK、receipt 和事务。
- Socket.IO v4 / Engine.IO v4：WebSocket 与 HTTP long-polling transport、namespace、event、ack、binary attachment、timeout/retry；polling HTTP 执行器可替换。
- MQTT 3.1.1 / 5.0：QoS 0/1/2、订阅、will、keepalive、session store、主题别名、Receive Maximum、Maximum Packet Size、服务端能力协商、reason code、增强认证与重新认证。
- 协议无关 IM toolkit：单聊/群聊、消息、同步游标、去重、回执、presence、typing，以及可替换 Gateway/Store；内存存储默认，文件存储显式启用。
- 独立 `@hmkit/ws-server` HAR：官方 Network Kit WebSocket Server 后端，API 19+；API 23 起具备全设备声明。
- 独立 `@hmkit/ws-native` HAR：Rust + Node-API 客户端/服务端，支持 RFC 6455 ping/pong、`ws`/`wss` 客户端及三种 OHOS ABI。

## 包边界

| 包 | 最低 API | 说明 |
|---|---:|---|
| `@hmkit/ws` | 12 | 纯 ArkTS 核心、客户端 transport、协议和 IM 接口；零第三方运行时依赖 |
| `@hmkit/ws-server` | 19 | 可选官方服务端后端；不随客户端核心引入 |
| `@hmkit/ws-native` | 12 | 可选 Rust/Node-API client/server transport；`arm64-v8a`、`armeabi-v7a`、`x86_64`，不进入核心 HAR |

## 最小示例

```ts
import {
  HmWebSocketClient,
  HmWebSocketClientOptions,
  NetworkKitWsTransportFactory,
  TextHeartbeatStrategy
} from '@hmkit/ws';

const options = new HmWebSocketClientOptions();
options.heartbeat = new TextHeartbeatStrategy('PING', 'PONG', 15000, 5000, true);

const client = HmWebSocketClient.withUrl(
  'wss://example.com/realtime',
  new NetworkKitWsTransportFactory(),
  options
);

await client.connect();
await client.send('hello');
```

业务若要 JSON，应显式使用 `JsonWsCodec<T>`；使用 STOMP、Socket.IO 或 MQTT 时，应创建对应协议客户端，不能把它们当成普通 WebSocket 消息混用。

Socket.IO polling 可作为同一个客户端的 transport 注入：

```ts
import { EngineIoPollingTransportFactory, HmWebSocketClient, SocketIoClient } from '@hmkit/ws';

const transport = HmWebSocketClient.withUrl(
  'https://example.com',
  new EngineIoPollingTransportFactory()
);
const socket = new SocketIoClient(transport);
await socket.connect();
```

IM 文件存储是 opt-in，并把序列化策略留给业务：

```ts
import { FileImStore, FileImStoreOptions } from '@hmkit/ws';

const options = new FileImStoreOptions();
options.fileName = 'messages.data';
const store = new FileImStore(context.filesDir, options);
// store.messages / store.conversations / store.cursor 分别注入 IM 客户端。
```

## 设计边界

- 平台 `send()` 成功只代表数据交给传输层，不等于业务服务端已经确认。
- 核心离线队列保证 FIFO，但不宣称 exactly-once；至少一次需要协议 ACK、幂等键和服务端配合。
- MQTT QoS 状态由 MQTT session store 管理，不复用普通 WebSocket 离线队列语义。
- IM 不规定服务端 JSON schema。业务通过 `ImGateway` 完成协议映射，通过 `ImMessageStore` 决定是否持久化。
- 官方 WebSocket Server 与 Native backend 都是可选包，不增加 API 12 客户端的系统版本和二进制负担。
- Native client 的 `wss` 使用 rustls/WebPKI 系统根；Native server 当前提供明文 `ws` listener，TLS 终止应放在网关或使用官方 API 19+ server backend。

## 本地验证

```bash
./scripts/test-local.sh

# Docker reference servers：Socket.IO polling/websocket、MQTT 5 TCP/websocket、STOMP 1.2
./scripts/test-interop.sh

# 首次构建 native backend
cargo install ohrs --root .tools/ohrs --locked
./scripts/build-release.sh
```

若只发布纯 ArkTS 包，可运行 `BUILD_NATIVE=0 ./scripts/build-release.sh`。本地单测覆盖核心生命周期、重连、心跳、队列/发送顺序、协议 codec/状态机、MQTT 5 流控/认证和 IM 快照；互操作套件使用真实开源服务器验证线协议。
