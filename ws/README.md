# @hmkit/ws

面向 HarmonyOS NEXT / OpenHarmony 的可扩展实时通信工具包。核心包基于纯 ArkTS，最低支持 API 12，不强制引入 Native 依赖。

## 安装

```shell
ohpm install @hmkit/ws
```

## 主要能力

- WebSocket 客户端：连接状态机、超时、网络感知和自动重连。
- 灵活心跳：可替换心跳内容、响应匹配、间隔和超时，不写死 JSON 格式。
- 离线队列：支持失败、丢弃或排队，可配置数量、字节、TTL 和溢出策略。
- 可选持久化：默认仅使用内存；只有业务主动启用时才保存消息。
- 可替换 Codec：支持文本、二进制、JSON 和自定义类型，JSON 不是底层约束。
- Socket.IO 4 / Engine.IO 4：WebSocket、HTTP polling、namespace、ack 和二进制附件。
- STOMP 1.2：订阅、ACK/NACK、receipt、事务和心跳协商。
- MQTT 3.1.1 / 5.0：QoS 0/1/2、会话、主题别名、流控、增强认证和重新认证。
- 协议无关 IM 工具：消息、会话、同步游标、去重、回执、presence、typing 及可替换存储。

Socket.IO、STOMP、MQTT 和 IM 都是按需使用的上层模块，不会改变基础 WebSocket 的消息格式。WebSocket Server 与 Rust/Node-API 后端分别位于可选包 `@hmkit/ws-server` 和 `@hmkit/ws-native`。

## 快速开始

```ts
import {
  HmWebSocketClient,
  HmWebSocketClientOptions,
  NetworkKitWsTransportFactory,
  TextHeartbeatStrategy
} from '@hmkit/ws';

const options = new HmWebSocketClientOptions();
options.heartbeat = new TextHeartbeatStrategy(
  'PING',
  'PONG',
  15000,
  5000,
  true
);

const client = HmWebSocketClient.withUrl(
  'wss://example.com/realtime',
  new NetworkKitWsTransportFactory(),
  options
);

await client.connect();
await client.send('hello');
```

业务需要 JSON 时，应显式选择 `JsonWsCodec<T>`；使用 Socket.IO、STOMP 或 MQTT 时，应创建对应协议客户端，不要把协议帧当作普通 WebSocket 消息混用。

## 设计边界

- 平台 `send()` 成功只代表数据已交给传输层，不代表业务服务端已经确认。
- 离线队列保证 FIFO，但不宣称 exactly-once；至少一次投递需要协议 ACK、幂等键和服务端共同配合。
- IM 不固定服务端 JSON Schema，业务通过 Gateway、Store、Uploader 等接口完成适配。
- 用户消息默认不持久化，文件存储必须显式创建和注入。
- 核心包不包含 WebSocket Server 和 Native 二进制，避免提高最低 API 或安装体积。

完整文档、示例与源码：[GitHub](https://github.com/lxshwyan/hmkit-ws)

许可证：MIT
