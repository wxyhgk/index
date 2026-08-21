# Chronicle 短命捕获进程触发 replayd audit-token 崩溃

日期：2026-08-12  
状态：现场因果链已确认；Chronicle 已关闭；Index 已统一 ScreenCaptureKit 事务门

## 现象

Index 偶发停在“正在捕获选中的显示器”，5 秒后提示 ScreenCaptureKit 超时。退出 PixPin 后问题仍持续，重启或重新构建并重启 Index 有时暂时恢复。

## 本次现场证据

00:26:13，同一个 Index 进程在约 0.247 秒内成功冻结三块显示器：

```text
LS27D80xU=3840x2160@2x
CFORCE=1440x2560@2x
Type_C=3360x1890@2x
```

约 54 秒后，`codex_chronicle` 的短命捕获子进程退出。统一日志紧接着出现：

```text
tccd: SecTaskCopy... No such process
tccd: failed to obtain signing identifier from audit token
replayd: EXC_BAD_ACCESS / SIGSEGV
```

replayd 崩溃报告的故障线程位于 `tcc_authorization_record_get_authorization_reason`，说明 replayd 正在用已经退出的客户端 audit token 查询 TCC 授权。38 秒观察窗口内，replayd 接受了 41 个不同客户端 PID，绝大多数来自 Chronicle 的短命屏幕捕获进程；不是 Index 在快速重试。

当前系统为 macOS 15.3.1（24D70）。现场检查时可用的 Sequoia 更新为 15.7.9；本次没有自动安装系统更新，也没有重启或退出登录。

## 立即止血

按照 Chronicle 官方开关语义，将 Codex 配置中的：

```toml
[features]
chronicle = true
```

改为 `false`，并只终止现有 `codex_chronicle` 后台进程。ChatGPT、Index 和 replayd 均未被退出或强制重启；Chronicle 进程没有再次拉起。

这会停用 Codex 的屏幕历史采集，但不删除项目代码、对话或已有普通记忆。若需要重新启用，应先升级 macOS 并确认 replayd 不再因短命捕获客户端崩溃。

## Index 侧修复

外部应用无法被 Index 的进程锁约束，因此 Index 不能保证修复 macOS 或其他截图软件的客户端行为。它能保证的是不继续放大故障：

1. 新增进程级 `MacScreenCaptureBroker`；
2. 普通截图、整窗重拍、录屏和滚动截图共用同一个事务门；
3. 一次事务覆盖 `SCShareableContent` 枚举以及随后的截图或 `SCStream.startCapture`；
4. 超时和 Task 取消后保持 quarantine，直到系统真实回调结束；
5. 不自动快速重试，不返回半套多屏快照；
6. 普通截图失败后清除 `SCShareableContent` 缓存，避免 replayd 重启后复用旧连接对象；
7. `scripts/check.sh` 增加静态纪律，禁止调用方绕过 Broker 直接初始化 ScreenCaptureKit。

## 结论

本次不是 Sidecar 数量判断错误，也不是 PixPin 退出不彻底，更不是“macOS 系统截图整体损坏”。直接触发链是 Chronicle 的短命第三方捕获客户端与 macOS 15.3.1 replayd/TCC 的 audit-token 崩溃。Index 的内部并发边界此前也不完整：普通截图有门，录屏和长截图没有；这部分已修正。

剩余系统风险只能通过停止有问题的外部捕获客户端和升级 macOS 降低。不要把 `kickstart replayd`、退出登录或重启电脑做成默认恢复流程；先保留 PID、签名、replayd 状态和统一日志证据。
