# Snapshot

像素输入。`CaptureSource.makeSnapshots() -> [DisplaySnapshot]` 为契约；`ImmediateScreenSource` 按 `NSScreen` 的 displayID 用 CoreGraphics 直接冻结全部活动显示器，得到原生 Retina 像素且不经过 ScreenCaptureKit/replayd。`DelayedScreenSource` 包装 `Immediate` 并在倒计时结束后执行同一条路径。`DisplaySnapshot` 分开保存显示器拓扑 scale 与实际位图 `imageScale`；`DisplayTopology` 用于阻止捕获时的旧拓扑与覆盖层显示时的新拓扑混用。跨屏 rect API 不用于主路径，因为现场只得到统一 1× 位图；逐屏 SCK 也不用于普通截图，因为现场会再次触发 replayd 崩溃。`WindowCapturer` 仅为 `⌥` 整窗重拍。
