# @hmkit/ws-native

Optional Rust/Node-API WebSocket backend for `@hmkit/ws`. It provides RFC 6455 text, binary, close, ping/pong, WSS via rustls/webpki roots, and a native WebSocket server.

The native package is intentionally separate from the API-12 pure-ArkTS core. Applications only carry its `.so` files when they explicitly install this package.

## Installation

```shell
ohpm install @hmkit/ws-native
```

Documentation and examples:
https://github.com/lxshwyan/hmkit-ws
