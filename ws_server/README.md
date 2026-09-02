# @hmkit/ws-server

`@hmkit/ws` 的可选 Network Kit WebSocket Server 后端。服务端能力与 API 12 客户端核心相互隔离，不会提高核心包的最低系统版本。

## 安装

```shell
ohpm install @hmkit/ws-server
```

同时需要核心包：

```shell
ohpm install @hmkit/ws
```

## 兼容性

- 最低 HarmonyOS API 19。
- API 19–22 的可用设备范围受系统能力限制。
- API 23 起具备全设备 WebSocket Server 能力边界。
- 使用前应执行运行时能力检查，并为不支持的设备准备降级方案。

该包只提供协议无关的 WebSocket Server 适配，不内置 IM 服务端、用户体系、好友关系、群聊数据或文件存储。

完整文档、示例与源码：[GitHub](https://github.com/lxshwyan/hmkit-ws)

许可证：MIT
