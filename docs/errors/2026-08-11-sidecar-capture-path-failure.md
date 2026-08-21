# Sidecar 期间第三方截图超时与 replayd 崩溃

日期：2026-08-11
状态：已确认两条独立故障链；已撤回 CoreGraphics 绕过 replayd 的错误假设；两阶段实时选区 + 系统 CLI 截图方案经实测同样被代理到 replayd，已整体撤回，回到「快捷键即 SCK 冻结全屏」架构（见文末「方案撤回」）

## 用户可见现象

连接或使用过 Sidecar/虚拟屏后，Index 曾报错：

```text
无法捕获显示器「LS27D80xU」
Index 的显示器捕获路径失败（显示器「Type_C」）；macOS 系统截图可能仍可用。
```

错误后来同时出现在 `LS27D80xU`、`Type_C`、`CFORCE` 三块物理屏上。用户现场确认 macOS 自带截图仍可用，因此不能把它表述为“macOS 截图服务损坏”。PixPin 曾在故障前使用，但日志没有显示它是本次请求洪泛的来源。

## 最终现场证据

### 1. 不是 Index 版本回归

使用同一签名与 bundle ID 构建、运行原封不动的 `0.0.28` 后，它也停在 `SCShareableContent` 不返回。这证明“0.0.28 历史上能用”与“当前登录会话中它也失败”可以同时成立，不能只靠回退 Index 修复。

### 2. replayd 的确崩溃，但不等于系统自带截图损坏

`launchctl print gui/501/com.apple.replayd` 现场显示：

```text
successive crashes = 23
last terminating signal = Segmentation fault: 11
service throttled by 1200 seconds
```

崩溃报告的故障栈顶为：

```text
EXC_BAD_ACCESS / KERN_INVALID_ADDRESS 0x50
tcc_authorization_record_get_authorization_right
```

`replayd` 是第三方 ScreenCaptureKit/ReplayKit 会话的用户态代理。系统自带截图在此时仍能正常工作并不矛盾。

### 3. 请求洪泛来自 codex_chronicle，不是 PixPin 或 Index

统一日志显示，`codex_chronicle` 在 `replayd` 不响应时持续启动新的短命进程，基本每 10 秒调用一次：

```text
codex_chronicle[54924] SCShareableContent ... activating ... com.apple.replayd
codex_chronicle[54927] SCShareableContent ... activating ... com.apple.replayd
codex_chronicle[54935] SCShareableContent ... activating ... com.apple.replayd
...
codex_chronicle[89918] SCShareableContent ... activating ... com.apple.replayd
```

强制重新拉起 `replayd` 后，它一次收到了多个已经退出的旧 PID。对第一个死进程 `54924` 检查授权时，TCC 返回：

```text
missing 'auth_value' in reply message
No such process
```

`replayd` 紧接着在 `tcc_authorization_record_get_authorization_right` 空指针崩溃。这是当前 macOS 15.3.1 登录会话的直接故障链：

```text
Chronicle 短周期超时重试
  → 死进程的 XPC 请求留在 launchd 端点
  → replayd 恢复时处理无效 audit token
  → TCC 返回空授权记录
  → replayd SIGSEGV
  → launchd 进入 1200 秒退避
```

### 4. 当前会话为什么无法靠应用自愈

暂停 `codex_chronicle` 后，新的 ScreenCaptureKit 请求已停止；但旧死请求已在 launchd 管理的 Mach 端点中。`replayd` 是 SIP 保护的 LaunchAgent，普通应用不能 `bootout/bootstrap` 它来重建端点。强制 `kickstart` 只会让它重放旧请求并再次崩溃。

因此当前已毒化的登录会话需要一次“退出登录 → 重新登录”来重建用户 launchd 域；不需要重启电脑。这是清理已存系统队列，不是 Index 的常规恢复步骤。

`22:10` 又完成了一次受控验证：先把仍在运行的两个 `codex_chronicle` 进程暂停到 `T` 状态，等待第 17 次崩溃的 640 秒退避完整结束，再只启动一次 `replayd`。守护进程启动后仍一次接收了 PID `1900、11539、11544、…、12031` 等历史连接，其中 PID `11544` 已不存在；TCC 随即返回 `missing 'auth_value'`，`replayd` 第 18 次 SIGSEGV，launchd 退避升至 1200 秒。这个结果排除了“Chronicle 暂停不彻底”和“Index 此刻仍在快速重试”，并确认旧 Mach/XPC 队列不会随客户端退出而清空。

### 5. 后续证据推翻了“CGDisplayCreateImage 不经过 replayd”

重启后 `CGDisplayCreateImage` 曾在三块物理屏上用约 `0.091s` 成功，因此一度被误判为独立于 ScreenCaptureKit 的稳定帧缓冲路径。但 macOS 15.3.1 的统一日志在故障现场清楚显示，每次调用都被系统转发为：

```text
ScreenCaptureKit SLSHWCaptureDesktopProxying request
ReplayKit RPDaemonProxy proxyCoreGraphicsWithMethodType
... 5 秒后 unable to complete request due to timeout
```

三块屏依次在 `21:55:33`、`21:55:38`、`21:55:43` 发起，最后到 `21:55:48` 才统一报错。这解释了“按下快捷键后等十几秒”以及三个显示器同时出现在错误文案中的真正原因：并非拓扑同时变化，而是同一个失效代理被串行请求了三次。

Xcode 15.2 SDK 的头文件也将 `CGDisplayCreateImage` 标为 macOS 15 obsolete。此前“普通截图不建立 ScreenCaptureKit/replayd 会话”的结论据此撤回；一次成功计时只能证明当时代理健康，不能证明调用边界。

## 开源实现对照与结论

- [Apple `captureImage(in:)`](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage%28in%3Acompletionhandler%3A%29)：macOS 15.2 起官方支持用一个 screen-space rect 跨多个显示器截图；但现场三块 2× 屏的联合矩形 `2640×2025 pt` 只返回 `2640×2025 px`，且接口不能配置目标像素尺寸，因此不适合作为 Retina 覆盖层的主路径。
- [Mio](https://github.com/iSoldLeo/Mio/blob/main/Mio/Capture.swift)：精确匹配 displayID、失败时拒绝半套快照；它的多屏并发/预热策略不适合直接照搬到已出现 `replayd` 退避的机器。
- [Snapzy](https://github.com/duongductrong/Snapzy/blob/master/Snapzy/Services/Capture/ScreenCaptureManager.swift)：冻结多屏会话，监听显示器参数变化并丢弃旧缓存。
- [开源 macshot](https://github.com/sw33tLie/macshot/blob/main/macshot/Capture/ScreenCaptureManager.swift)：多屏快照保持全或无语义，不把缺屏静默变成成功。
- [BetterShot](https://github.com/KartikLabhshetwar/better-shot/blob/main/Sources/Capture/ScreenCapture.swift)：调用 `/usr/sbin/screencapture`。Index 借用它的系统执行器思路，但把系统调用放在自定义选区确认之后，并在取帧时隐藏自己的覆盖层，因此仍保留原工具栏和标注流程。

可移植的共性不是“定期预热”，而是：选区入口不做像素捕获；确认后只请求目标屏；精确匹配 displayID；校验原生像素倍率；失败时停止追加请求；拓扑变化后丢弃旧结果；系统进程也必须有超时与取消，不能短周期重试。

## Index 已实施的修正（两阶段方案，已于同日晚些时候整体撤回，见文末）

最终实现不再把“能否进入截图界面”绑定到 ScreenCaptureKit。入口改为两阶段：

1. 快捷键或菜单点击时只读取 `NSScreen` 的 displayID、frame 和 scale，并为每块屏创建透明实时画布；这一步不调用 `SCShareableContent`、`SCScreenshotManager` 或废弃 CoreGraphics 截图 API，因此不会等待 `replayd`；
2. 用户拖出选区并确认后，短暂把 Index 的可见窗口设为全透明，通过 `/usr/sbin/screencapture -R` 和目标 displayID 的 Quartz bounds 只捕获选区所在的一块屏；
3. 冻结完成前不开放工具栏、放大镜、像素取样、Live Text 和标注，避免把透明占位图误当截图；
4. 录屏和长截图动作只消费选区几何，不需要先冻结静态截图，因此它们不再被静态截图服务阻塞；
5. 全窗口截图若尚未冻结，不会把透明占位图保存为成功结果；窗口捕获失败会直接报告本次失败；
6. 系统截图子进程保留 8 秒单次完成门并响应任务取消；门必须大于 screencapture 约 5 秒的内部超时，让故障时子进程自己退出 —— 门更短会在请求在途时杀进程，死 PID 的在途请求留在 replayd 端点里（与 Chronicle 致崩同款模式）；超时不自动重试、不继续请求其他显示器；
7. 捕获前后比较 displayID、frame 和 scale；拓扑变化则拒绝陈旧结果；
8. 删除 `CGDisplayCreateImage` / `CGWindowListCreateImage` 主路径及“不经过 replayd”的错误结论。

主要实现位置：

- `Platform/macOS/MacScreenCapturer.swift`：实时画布准备、拓扑和 Retina 结果校验；
- `Platform/macOS/MacSystemDisplayCapturer.swift`：目标屏 Quartz bounds、系统截图子进程、超时、取消和进程回收；
- `Capture/Overlay/OverlayView.swift`：确认选区后才发起冻结，并在冻结完成前阻止像素相关操作；
- `Capture/Selection/SelectionOverlayController.swift`：把目标屏冻结结果安装回对应覆盖层；
- `Capture/Selection/SelectionResult.swift`：区分真实截图与只包含几何的延迟捕获结果。

这个改动解决的是应用自己的错误耦合：截图入口不应因为 SCK 失效而卡 5 到 15 秒，普通静态截图也不应由 Index 自己先枚举共享内容。`screencapture` 的内部实现由 macOS 决定，不能宣称它绝对不经过 ScreenCaptureKit/replayd；但它与用户已验证可用的系统截图路径一致，并且即使失败也受 4 秒门约束。

## 恢复与回归清单

### 已出现 replayd 崩溃的会话

不要把“退出登录”做成每次截图失败后的产品提示或默认恢复动作。先退出或暂停会周期重试的屏幕捕获客户端，并用日志确认 `replayd` 是否真的崩溃；只有已确认系统代理反复崩溃且无法自动恢复时，退出登录再登录才是清理当前用户 launchd/XPC 域的最后手段。Index 本身应保持可进入选区、可取消，并且不得自动重试放大故障。

### 必须补的真实回归

1. 按快捷键后日志应先出现 `已准备实时选区画布 count=N`，此时不得出现 `SCShareableContent`；
2. 确认选区后才应出现一次目标屏冻结日志，并核对返回像素等于该屏点尺寸乘 scale；
3. 核对不同排列方向、负坐标和 Retina/非 Retina 混合缩放下的目标屏位图；
4. 连接 Sidecar 后连续触发快捷键与菜单按钮，确认入口不枚举共享内容、确认后一次只请求目标屏，且没有 `proxyCoreGraphicsWithMethodType`；
5. 准备或冻结期间断开/重连 Sidecar，应丢弃旧结果而不保存透明或陈旧图像；
6. 观察 `replayd` 不应因 Index 产生短周期重试或新增连续崩溃；
7. 运行 `LiveSelectionTests`、`CaptureSourceTests`、`scripts/check.sh`、Release 签名校验。

## 当前验证结果

- `LiveSelectionTests` + `CaptureSourceTests`：9 个测试，0 失败；
- `scripts/check.sh`：115 个测试，0 失败，6 项架构纪律全部通过；
- 新两阶段架构的 Release 构建成功，`codesign --verify --deep` 通过；旧 PID `12031` 已退出，新 PID `42703` 已从同一绝对路径启动；
- 新进程启动后没有产生新的 `SCShareableContent` / ScreenCaptureKit 请求；实际 Sidecar 选区和确认后的目标屏冻结仍待手动操作验证；
- 修正前故障复现：三次旧 CG 代理请求各等待 5 秒，总耗时约 15 秒，错误列出全部三屏；
- 修正后单元回归：`CaptureSourceTests` 5 个测试通过；完整检查结果见对应构建记录；
- 修正后的手动截图在枚举 `SCShareableContent` 时于 5 秒完成门超时；受控恢复验证确认 `replayd runs=18 / successive crashes=18 / minimum runtime=1200`；
- Chronicle 屏幕历史捕获已暂停，当前不再产生新的短命捕获客户端；继续 `kickstart` 只会重放旧死连接并延长退避，因此不再尝试；
- 22:47 手动确认选区后报「macOS 自带截图工具响应超时」。直接在终端运行 `/usr/sbin/screencapture`（不经过 Index）同样每屏等待约 5 秒后失败 `could not create image from display N`；统一日志确认 CLI 路径同样被代理：`screencapture → SLSHWCaptureDesktopProxying → RPDaemonProxy proxyCoreGraphicsWithMethodType → com.apple.replayd → unable to complete request due to timeout`。此时 `replayd runs=19 / successive crashes=19 / spawn scheduled`（退避中），证明「系统 CLI 截图不经过 replayd」的预期不成立，当前登录会话内所有捕获路径仍然失效，仍需退出登录重建 launchd 域；
- 据此把子进程完成门从 4 秒提到 8 秒：4 秒门会抢在 screencapture 约 5 秒内部超时之前杀掉在途请求的子进程，死 PID 的在途请求留在 replayd 端点 —— 与 Chronicle 的致崩模式相同。8 秒门让故障时系统工具自己报错退出，健康时（实测 0.1~0.5 秒）不受影响。

## 方案撤回：回到「快捷键即 SCK 冻结全屏」（2026-08-11 深夜）

两阶段方案的核心前提是「SCK 失效时，系统 CLI 截图仍然可用」——22:47 的终端实测证伪了它（见上条）：macOS 15.3.1 上 `/usr/sbin/screencapture` 与 `CGDisplayCreateImage` 一样被代理到 replayd。前提不成立之后，两阶段只剩下代价：选区期间画面不冻结（动态内容存下来的不是框选时看到的那帧）、框选阶段没有放大镜/取色、每次确认要隐去全部窗口再恢复、确认到工具栏之间多出一段等待。故障会话里它同样一张图也截不出来。

因此整体撤回两阶段实现（`MacSystemDisplayCapturer`、实时画布、`requiresDeferredCapture` 等随之删除），回到冻结式入口：

- 快捷键按下即 `SCShareableContent`（5 秒完成门）+ 逐屏 `SCContentFilter(display:)` 冻结，精确匹配 displayID、按 `frame × scale` 请求并校验原生 Retina 像素，任意一屏失败不返回半套结果；拓扑变化最多重取一次；
- 故障会话的表现：枚举超时一次、有界报错（不再串行放大成 N 次等待），不健康会话体验与 0.0.28 一致（冻结所见即所得、放大镜、确认即裁剪）；
- 本次事件留下的长期纪律不变：不自动重试、请求必有完成门、拓扑变化丢弃旧结果、禁止恢复 `CGDisplayCreateImage / CGWindowListCreateImage`（`scripts/check.sh` 纪律六看守）。

## 构建后“必须重启”的独立原因与修正（2026-08-11 23:45）

后续观察发现，“每次构建新版本后都需要重启才能恢复”还有一条独立于捕获 API 的部署故障：旧版 `build.sh` 会在 Index 仍运行时，直接删除并重建 `build/Index.app`。

这会形成不安全窗口：运行中 PID 的 audit token/code object 仍属于旧二进制，而同一绝对路径已经变成新二进制和新签名。即使前后都使用固定的 `Index Dev` 证书，TCC/replayd 仍可能在解析客户端时看到“旧进程身份 + 新磁盘内容”。重启之所以看似有效，是因为它同时清掉了旧 PID 和相关 XPC 会话，并不是每个版本天然需要重启。

`build.sh` 已改为：

1. 在 `build/.Index-stage.*` 完整组装、固定身份签名并通过 `codesign --verify`；
2. 保持现有 App 和进程不动，直到新 bundle 已经可用；
3. 若旧 Index 正在运行，先正常退出，超时才对精确匹配的 PID 发送 TERM；
4. 确认旧 PID 完全消失后，在同一文件系统内原子替换 bundle；
5. 构建前若 App 正在运行，替换后自动启动新版本；
6. 未找到 Developer ID 或固定 `Index Dev` 证书时直接失败，不再静默生成每次 cdhash 都变化的 ad-hoc 包。

真实无重启验证：旧 PID `3526` 在替换前退出，新 PID `6285` 自动启动；前后 designated requirement 都是 `com.wxyhgk.index + 74b621…5ead`。构建前后 `replayd` 保持同一 PID `4190`，`runs=7 / successive crashes=6` 未增加；Release 严格签名校验通过，且没有遗留 staging 目录。

`scripts/check.sh` 新增纪律七，阻止重新引入“运行中原地覆盖 App”或“无提示退回 ad-hoc”两类问题。
