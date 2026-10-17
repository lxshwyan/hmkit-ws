# @hmkit/ws 0.1.2 Validation

验证日期：2026-10-17

## 自动门禁

- Hypium：32/32 通过。
- 覆盖率下限：lines 45%、functions 30%、branches 35%。
- Release 构建：core API 12 HAR、server API 19 HAR、native 三 ABI HAR。
- API 合约：core 159、server 3、native 11 个公开符号。
- 包扫描：版本、作者、仓库、许可证、release/obfuscation 元数据、敏感材料、native ABI。
- 独立消费者：API 12 core、API 19 server、API 12 native 均从最终 HAR 安装并生成 HAP。
- 互操作：Socket.IO polling/websocket、MQTT 5 TCP/websocket QoS 2、STOMP 1.2 websocket。
- OHPM：三个最终 HAR 均执行 prepublish；发布时按 core → server → native 顺序提交。

## 工具诊断说明

- Hvigor 6.1 会对有效的 0.1.2 本地模块映射输出 SemVer/local-module 告警；源码清单、依赖映射和最终 HAR 均解析为 0.1.2，OHPM prepublish 作为发布判定。
- `NetworkKitWsNetworkMonitor` 使用需要 `ohos.permission.GET_NETWORK_INFO` 的系统 API；core HAR 已声明该权限，消费应用仍应在自身模块中明确申请。
- native consumer 会显示当前 SDK 对 Node-API 模块“尚未启用验证”的提示；包中已包含生成的 `libs/index.d.ts`、三 ABI 动态库和可编译的 ArkTS 类型入口。
- OHPM 对 native HAR 给出“包含源码”的提示，这是 ArkTS 适配层与类型声明的正常发布形态；敏感材料扫描已通过，三个包的 prepublish 均成功。

## 最终产物

| 包 | 文件 | 大小（字节） | SHA-256 |
| --- | --- | ---: | --- |
| `@hmkit/ws@0.1.2` | `ws.har` | 96,539 | `b2aa959fb8746a9fa16a7d05e1e176e2a3d1bcbf6a5d2a27ca2af849d8082c98` |
| `@hmkit/ws-server@0.1.2` | `ws_server.har` | 7,578 | `049dd32a2373af7381d789662d482f9a63e5fa7095a7087a00941e8d08484894` |
| `@hmkit/ws-native@0.1.2` | `hmkit-ws-native.har` | 2,326,275 | `a2e5ebc780c35075faef10269a5957fa79d7bed3eb747977bae97bca8caeb0de` |
