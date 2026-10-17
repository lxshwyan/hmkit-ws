# @hmkit/ws 0.1.2 Release Notes

发布日期：2026-10-17

本次同步发布 `@hmkit/ws`、`@hmkit/ws-server` 和 `@hmkit/ws-native` 0.1.2，重点是安装兼容性、异常处理和可重复验证；没有新增协议，也没有有意的破坏性 API 变更。

## 主要修复

- 修复 native 包类型入口只暴露 Node-API 声明、无法导入五个 ArkTS transport/server 适配器的问题。
- 补齐 native HAR 的合并模块清单，独立 API 12 消费工程可以安装并编译三 ABI 包。
- Polling HTTP executor 现在显式转换非标准异常，同时始终销毁请求对象。
- IM 文件存储的主文件/备份恢复路径全部进入明确的异常边界，写入失败时安全尝试回滚。
- server 在源码工程内使用官方 `@module:ws` 依赖形式；最终 HAR 自动固定到 `@hmkit/ws@0.1.2`。

## 发布质量

- Hypium 升级到 1.0.29，新增 polling 握手失败回归测试。
- 新增 45% 行、30% 函数、35% 分支覆盖率下限。
- 新增 159 个 core、3 个 server、11 个 native 公共符号契约。
- 新增 HAR 凭据/元数据/ABI 扫描，以及 API 12 core、API 19 server、API 12 native 独立消费者。
- 新增 GitHub Actions 的静态检查和真实 Socket.IO、MQTT、STOMP 互操作验证。

升级方式：

```shell
ohpm install @hmkit/ws@0.1.2
ohpm install @hmkit/ws-server@0.1.2
ohpm install @hmkit/ws-native@0.1.2
```
