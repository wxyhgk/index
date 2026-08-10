# Capture

冻结截图链路。`CaptureCoordinator` 串 4 步：`CaptureSource → 选区 → 入库/Pipeline → 动作`。

```
Snapshot/   像素怎么来：CaptureSource 契约、ScreenFreezer 定格、DisplaySnapshot 载体、WindowCapturer 整窗
Selection/  框怎么算：SelectionModel 纯值状态机 + SelectionResult + OverlayGeometry
Overlay/    怎么盖屏上：OverlayWindow/View/Renderer + Keyboard
Magnifier/  放大镜：MagnifierRenderer + PixelSample
Metadata/   元数据：MetadataCollector + ScrollStitcher（滚动拼接，成熟后移 Pipeline）
```

* 新增捕获方式：`Snapshot/` 加 `CaptureSource` 实现 + 注册一行，不动 `CaptureCoordinator`。
* 选区逻辑不碰 AppKit，`Selection/` 可单测。
