# Sidecar 期间第三方截图超时与 replayd 崩溃

日期：2026-08-11
状态：已确认现场根因；普通多屏截图已切到 CoreGraphics 原生像素路径并完成三屏回归

## 用户可见现象

连接或使用过 Sidecar/虚拟屏后，MacShot 曾报错：

```text
无法捕获显示器「LS27D80xU」
MacShot 的显示器捕获路径失败（显示器「Type_C」）；macOS 系统截图可能仍可用。
```

错误后来同时出现在 `LS27D80xU`、`Type_C`、`CFORCE` 三块物理屏上。用户现场确认 macOS 自带截图仍可用，因此不能把它表述为“macOS 截图服务损坏”。PixPin 曾在故障前使用，但日志没有显示它是本次请求洪泛的来源。

## 最终现场证据

### 1. 不是 MacShot 版本回归

使用同一签名与 bundle ID 构建、运行原封不动的 `0.0.28` 后，它也停在 `SCShareableContent` 不返回。这证明“0.0.28 历史上能用”与“当前登录会话中它也失败”可以同时成立，不能只靠回退 MacShot 修复。

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

### 3. 请求洪泛来自 codex_chronicle，不是 PixPin 或 MacShot

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

因此当前已毒化的登录会话需要一次“退出登录 → 重新登录”来重建用户 launchd 域；不需要重启电脑。这是清理已存系统队列，不是 MacShot 的常规恢复步骤。

## 开源实现对照与结论

- [Apple `captureImage(in:)`](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage%28in%3Acompletionhandler%3A%29)：macOS 15.2 起官方支持用一个 screen-space rect 跨多个显示器截图；但现场三块 2× 屏的联合矩形 `2640×2025 pt` 只返回 `2640×2025 px`，且接口不能配置目标像素尺寸，因此不适合作为 Retina 覆盖层的主路径。
- [Mio](https://github.com/iSoldLeo/Mio/blob/main/Mio/Capture.swift)：精确匹配 displayID、失败时拒绝半套快照；它的多屏并发/预热策略不适合直接照搬到已出现 `replayd` 退避的机器。
- [Snapzy](https://github.com/duongductrong/Snapzy/blob/master/Snapzy/Services/Capture/ScreenCaptureManager.swift)：冻结多屏会话，监听显示器参数变化并丢弃旧缓存。
- [开源 macshot](https://github.com/sw33tLie/macshot/blob/main/macshot/Capture/ScreenCaptureManager.swift)：多屏快照保持全或无语义，不把缺屏静默变成成功。
- [BetterShot](https://github.com/KartikLabhshetwar/better-shot/blob/main/Sources/Capture/ScreenCapture.swift)：调用 `/usr/sbin/screencapture` 并把交互交给 macOS；这条路稳定性高，但放弃了 MacShot 的自定义冻结覆盖层和工具栏，不能作为无损替换。

可移植的共性不是“定期预热”，而是：普通显示器冻结不应依赖窗口枚举或 replayd；必须使用 SCK 的高级能力才建立一个有界会话；拓扑变化后丢弃旧结果；不在异常时短周期生成新进程重试。

## MacShot 已实施的修正

实现位置：`Sources/MacShot/Platform/macOS/MacScreenCapturer.swift`

1. 普通显示器冻结按当前 `NSScreen` 的 displayID 调用 `CGDisplayCreateImage`，直接得到每屏原生像素；
2. 普通截图不再请求 `SCShareableContent`，也不建立 ScreenCaptureKit/replayd 会话；
3. 不使用跨屏 rect 主路径：它虽只需一个请求，但现场只能得到 1× 位图，导致选区浮层和最终截图模糊；
4. 不使用逐屏 SCK 作为普通截图回退：Release 实测首次调用即令 replayd 的崩溃计数 `10 → 11`，并最终触发 5 秒超时；
5. 只有 `⌥` 整窗重拍等必须读取窗口后备存储的功能才使用 SCK，并保留 5 秒单次完成门；
6. 取消启动时 2×2 预热，真实截图不会等待一个卡死的共享预热 Task；
7. 超时不会触发应用内快速重试；
8. 捕获前后比较 displayID、frame 和 scale；拓扑变化时拒绝陈旧/部分结果；
9. 错误文案限定为 MacShot 自己的捕获路径，不声称系统自带截图损坏。

旧会话现场验证：有界回调约 5.2 秒后返回 `screenCaptureTimedOut`，MacShot 保持存活且可再接收命令，没有再生成多个短命客户端。重启后跨屏 rect 在约 0.4 秒内成功并证明 replayd 当时可用，但它返回 1× 位图造成明显模糊；随后逐屏 2× SCK 又令 replayd 新增一次崩溃。两条 SCK 普通截图路径均已从主路径移除。

## 恢复与回归清单

### 当前已毒化会话

1. 暂停或退出会周期重试的 `codex_chronicle`；
2. 保持 PixPin/其他截图与录屏工具不运行，避免添加新请求；
3. 退出 macOS 用户登录会话并重新登录一次，无需重启电脑；
4. 只启动当前绝对路径的 MacShot Release；
5. 先验证三块物理屏，再连接 Sidecar 验证四屏。

### 必须补的真实回归

1. 日志应出现 `CoreGraphics 多屏冻结完成 ... count=N images=...`，并核对每屏返回像素等于点尺寸乘 scale；
2. 核对不同排列方向、负坐标和 Retina/非 Retina 混合缩放下的各屏位图；
3. 连接 Sidecar 后连续触发快捷键与菜单按钮，确认普通截图日志中不出现 `SCShareableContent` 或 `SCScreenshotManager`；
4. 准备期间断开/重连 Sidecar，应丢弃旧快照而不展示残缺覆盖层；
5. 观察 `replayd` 不应新增连续崩溃；
6. 运行 `CaptureSourceTests`、`scripts/check.sh`、Release 签名校验。

## 当前验证结果

- `CaptureSourceTests`：5 个测试，0 失败；
- `scripts/check.sh`：110 个测试，0 失败，5 项架构纪律全部通过；
- Release 构建成功，`codesign --verify --deep --strict` 通过；
- 当前会话失败上限：约 5.2 秒，不再出现十几秒或无界 `isPreparing`；
- 已完成：CoreGraphics 三块物理屏真实捕获在 `0.091s` 完成，返回 `3840×2160@2x`、`1440×2560@2x`、`3360×1890@2x`；调用前后 replayd 保持 `runs=13 / crashes=12 / PID=8390`；
- 待完成：重新连接 Sidecar 后的四屏真实回归。
