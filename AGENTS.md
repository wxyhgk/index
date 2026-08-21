# Index Agent Guide

本文件适用于整个仓库。修改代码前先阅读根目录 `README.md`、`ARCHITECTURE.md` 和相关模块的 `README.md`；真实实现与当前测试结果优先于历史文档中的旧方案。

## 项目边界

- Index 是 macOS 原生截图工具，SwiftPM 工程，最低平台 macOS 14。
- 平台副作用必须收口在 `Sources/Index/Platform/`；Capture、Toolbar、Annotation 等领域层不得直接新增平台弹窗或反向依赖 UI。
- 普通截图不得恢复 `CGDisplayCreateImage` 或 `CGWindowListCreateImage`。macOS 15 会把这些废弃 API 代理到 ReplayKit，可能把多屏故障放大成多次串行超时。
- 不要仅凭显示器数量、Sidecar 或虚拟屏存在就判断根因。先核对 `NSScreen`/CoreGraphics 拓扑、displayID、frame、scale、ScreenCaptureKit 请求日志以及 `replayd` 的真实状态。
- 捕获请求必须有完成门；失败后不得自动快速重试，不得返回半套显示器快照；拓扑变化时丢弃旧结果。
- 系统自带截图成功不等于第三方 ScreenCaptureKit 路径健康，错误文案不得声称整个 macOS 截图服务已损坏。

## 构建与签名：强制规则

- 组装或替换 App 只能运行：

  ```bash
  ./build.sh release
  ```

- 绝不能在 Index 进程仍运行时直接删除、覆盖或就地修改 `build/Index.app`。旧进程的 audit token/code object 与磁盘新签名不一致，会污染 TCC/replayd 会话，表现为“构建后必须重启”。
- `build.sh` 必须保持以下顺序：旁路目录完整组装与签名 → 校验签名 → 退出旧进程 → 确认 PID 消失 → 同卷原子替换 → 按原运行状态启动新版本。
- 签名必须使用 Developer ID 或固定的 `Index Dev` 证书。不得静默退回 ad-hoc；只有无 TCC 需求的临时环境可显式设置 `INDEX_ALLOW_ADHOC=1`。
- 新开发机器首次构建前运行：

  ```bash
  ./scripts/make-dev-cert.sh
  ```

- Release App 的固定路径现为 `build/Index.app`；不要再次移动，路径变化可能被 TCC 当成另一个客户端。

## 验证

常规修改至少运行：

```bash
./scripts/check.sh
```

它必须通过 Swift 构建、全部测试和所有架构纪律。需要验证 Release 组装时运行：

```bash
./scripts/check.sh --full
```

`--full` 可能退出并自动重启正在运行的 Index，这是安全替换流程的一部分。

截图、Sidecar、多物理屏等真实验证具有桌面副作用：不要在未告知用户时主动触发截图、录屏、退出登录或重启。完成构建后让用户手动触发一次，再读取新 PID 对应的日志。报告时明确区分单元测试通过、Release 已启动和真实多屏操作已验证。

## 故障处理

- 遇到 ScreenCaptureKit 超时，先记录当前 Index PID、二进制路径、designated requirement 和 `replayd` 的 `state/runs/successive crashes/pid`，不要立即重启而丢失证据。
- 不要反复 `kickstart` 已崩溃或退避中的 `replayd`；旧 XPC 请求可能被重新处理并继续延长退避。
- “退出登录/重新登录”只能作为已确认用户 launchd/XPC 域损坏后的最后恢复手段，不能作为产品默认建议。
- 相关事故记录：
  - `docs/errors/2026-08-11-sidecar-capture-path-failure.md`
  - `docs/errors/2026-08-11-running-app-rebuild-tcc-identity.md`

## 工作区与交付

- 工作区可能已有用户修改。保留无关变更，不要 reset、checkout 或覆盖他人的工作。
- 修改后运行 `git diff --check`，并只汇报本次实际验证过的结果。
- 未经用户明确要求，不要提交、推送、打 tag 或提升版本号。
