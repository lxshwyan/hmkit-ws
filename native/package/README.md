# @hmkit/ws-native

`@hmkit/ws` 的可选 Rust / Node-API WebSocket 客户端与服务端后端。它与纯 ArkTS 核心分包发布，只有主动安装时才会携带 Native 二进制。

## 安装

```shell
ohpm install @hmkit/ws-native
```

同时需要核心包：

```shell
ohpm install @hmkit/ws
```

## 主要能力

- RFC 6455 文本、二进制、关闭、ping/pong。
- 客户端支持 `ws` 和基于 rustls / WebPKI 根证书的 `wss`。
- 提供可选 Native WebSocket Server。
- 包含 `arm64-v8a`、`armeabi-v7a` 和 `x86_64` 三种 OHOS ABI。

Native Server 当前提供明文 `ws` listener。生产环境需要 TLS 时，建议在网关终止 TLS，或选择 `@hmkit/ws-server` 提供的官方 Network Kit 后端。

完整文档、示例与源码：[GitHub](https://github.com/lxshwyan/hmkit-ws)

许可证：MIT
