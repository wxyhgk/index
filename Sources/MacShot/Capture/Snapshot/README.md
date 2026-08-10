# Snapshot

像素输入。`CaptureSource.makeSnapshots() -> [DisplaySnapshot]` 为契约，`ImmediateScreenSource`（`ScreenFreezer` 定格）与 `DelayedScreenSource`（包 `Immediate` + 倒计时 HUD）为实现。`WindowCapturer` 为 `⌥` 整窗重拍，`DisplaySnapshot` 为跨层载体。
