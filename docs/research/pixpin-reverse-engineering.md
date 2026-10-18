# PixPin 3.5.5.1 逆向分析

> 日期：2026-10-15  
> 方法：`nm`（符号表）、`strings`、`lipo`、bundle 结构分析  
> 二进制：`/Applications/PixPin.app`（总 289 MB，主二进制 40 MB）

## 总体架构

| 项目 | 值 |
|------|-----|
| 技术栈 | **Qt 5 C++**（非原生 Swift/AppKit） |
| Bundle ID | `com.depthpicture.PixPin` |
| 最低系统 | macOS 10.15 |
| 支持语言 | 简中、繁中、英文、日、韩、法、德、西、葡 |
| 开发者 | knightjun（xmake 缓存路径在二进制中暴露） |
| 主二进制 | 40 MB universal（x86_64 + arm64），arm64 slice 17 MB |
| 自有框架 | 28 个 `libPix*.dylib` |
| 辅助进程 | `PixPinAuxiliary`（录屏/OCR 后台任务）+ `crashpad_handler`（崩溃报告） |

## 技术栈依赖

| 组件 | 版本 | 用途 |
|------|------|------|
| Qt 5 | QtCore/Gui/Qml/Xml/DBus/PrintSupport | UI 框架 |
| OpenCV | 4.13.0（xmake 包管理） | 图像处理 |
| ONNX Runtime | 1.23.2 | AI 模型推理 |
| PaddleOCR | Caffe 模型（detect + sr） | 本地 OCR |
| OpenCL | Intel subgroups / AMD fp64 | GPU 加速 |
| ZXing | — | 二维码/条形码识别 |
| libaom | v3.6.0（AV1 Decoder v3.13.1） | AV1 编解码 |
| OpenSSL | 1.1 | 网络加密 |
| Lottie | — | 矢量动画 |
| Crashpad | Chromium | 崩溃报告 |
| SQLite | — | 本地数据库（PinItem、PinImageItem 表） |

## 模块划分（28 个 libPix*.dylib）

### 截图/屏幕管理

| 模块 | 大小 | 关键符号 |
|------|------|---------|
| `libPixScreenManager` | 270 KB | `PixScreenManager::grabScreen(QRect, bool)`（截屏）、`screenList()`（屏幕列表）、`createScreenStreamer()`（录屏流）、`PixCursorPixmap::GetCursor(QRect)`（鼠标光标捕获） |
| `libPixKeyMouse` | 243 KB | CGEventTap 全局鼠标/键盘 hook；`PixGloabalMouse`（修饰键+鼠标按钮组合触发）；`SimulateMouseClick`（模拟点击）；`IsArrowKey`、`GetKeySequence` |
| `libPixWindowNotify` | 140 KB | 窗口通知 |

关键字符串：
- `ScreenCaptureKit`（macOS 15+ 路径）
- `captureThread` / `captureThread->stopCapture()`
- `ScreenShotView`、`ScreenShotEdit`、`ScreenShotModeButton`
- `ScreenPixmapItem`、`ScreenMouseItem`、`CustomScreenshot`
- `ScreenShotDirect`、`ScreenShotWindow`、`ScreenShotBgLayer`
- `ScreenshotParameters`、`ScreenshotPresetForm`、`ScreenshotPresetSelect`
- `setPixLongImagePresetTileMaxMemSize`（长图拼接）
- `CoreAudioCaptureThread`（音频捕获）

### 标注/编辑（QGraphicsScene 架构）

编辑器核心在主二进制内：
- `TrigerGraphicScene` — QGraphicsScene 子类
- `TrigerGraphicEditManage` — 编辑器状态机（添加/撤销/重做/选择）

**25 种 EditItem：**

| 类别 | 具体类型 |
|------|---------|
| 自由绘制 | `EditItemPencil`（铅笔）、`EditItemMarker`（荧光笔）、`EditItemHighLight`（高亮） |
| 线条 | `EditItemArrow`（箭头，`LineShapeType` 多种线形 + `ArrowHeadType` 箭头形状）、`EditItemLine`（直线）、`EditItemBrokenLine`（断线） |
| 形状 | `EditItemGeometry`（几何图形）、`EditItemCustomShape`（自定义形状）、`EditItemCustom`（自定义） |
| 马赛克 | `EditItemMosaic`、`EditItemRectMosaic`（矩形）、`EditItemMosaicCustom`（自定义区域） |
| AI 马赛克 | `EditItemAutoMosaic`、`EditItemRectAutoMosaic`（矩形）、`EditItemPathAutoMosaic`（路径） |
| 橡皮擦 | `EditItemEraser`、`EditItemRectEraser`（矩形）、`EditItemEraserCustom`（自定义） |
| 文字 | `EditItemText`（文字）、`EditItemSerial`（序号）、`EditItemIconLabel`（图标标签） |
| 特效 | `EditItemWatermark`（水印）、`EditItemMagnifier`（放大镜） |
| 布局 | `EditItemColumn`（列） |

配置体系：
- `MarkConfigInit()` — 一次性初始化
- `GetMarkConfigByEditType(QString)` — 按工具类型查配置
- 每种工具有独立 Config 类：`MarkArrowConfig`、`MarkMarkerConfig`、`MarkPencilConfig`、`MarkMosaicConfig`、`MarkEraserConfig`、`MarkTextConfig`
- `getMarkConfigPenWidth`、`getMarkConfigColor`、`getMarkConfigPathMode`

路径生成算法：
- `genLineArrowPath(QPointF, QPointF, LineShapeType, QPen)` — 直线箭头
- `genLineArrowPathCurve(QVector<QPointF>, LineShapeType, QPen, bool)` — 曲线箭头
- `GenSerialPath` — 序号路径
- `addRectArrowToPath` — 矩形箭头

马赛克：
- `applyMosaicToPixmap(QPixmap, double)` — 单图打码
- `applyMosaicFromSceneToPixmap(QGraphicsScene*, double)` — 场景级批量打码
- AI：`PixMosaicObjDetGraphicItem`（目标检测自动打码）

### 贴图（Pin）窗口

关键类（主二进制）：
- `PinWindow` / `PinWindowBase` — 贴图窗口
- `PinDataItem` — 数据模型（`setPinOnScreen`、`setGroup`）
- `PinDataQuery` — SQLite 查询

紧凑布局算法：
- `getCompactOccupiedRect(PinWindow*)` — 计算占用区域
- `moveWindowToCompactRect(PinWindow*, QRect)` — 移动到紧凑位置
- `getCompactArrangementInsets(PinWindow*)` — 排列间距
- `confirmNegativeDistributionGap(PinWindow*)` — 负间隙确认（空间不够时）
- `showCompactLayoutFailedDialog(PinWindow*)` — 布局失败提示

分组管理：
- SQLite `"group"` 字段
- `PinDataQuery::changeGroup`、`changePinToGroup`、`queryItemByGroup`
- `queryPinScreenItems`、`setCloseAllPinWindow`、`queryLastCreateItemNoOnScreen`

其他：
- `KeyPassMenu` — 快捷键穿透菜单
- `PixPinScript::runScriptWithPinWindow(PinWindow*, QString)` — 脚本 API

### 数据库 Schema（SQLite）

```sql
CREATE TABLE IF NOT EXISTS "PinItem" (
  ...
  "pinOnScreen" BOOLEAN NOT NULL,
  "group" TEXT,
  "closeTime" ...,
  "createTime" ...
);

CREATE TABLE IF NOT EXISTS "PinImageItem" (...);
-- 另有 OcrResult TEXT 字段
```

二进制中发现的查询：
```sql
SELECT * FROM PinItem WHERE pinOnScreen = 0 AND "group" = :group
  ORDER BY closeTime DESC LIMIT 200 OFFSET %1;
SELECT * FROM PinItem WHERE pinOnScreen = true AND "group" = :group
SELECT COUNT(*) FROM PinItem WHERE "group" = :group AND pinOnScreen = 1
UPDATE PinItem SET pinOnScreen = false, closeTime = :closeTime
  WHERE pinOnScreen = true AND "group" = :srcGroup
```

### OCR / AI

| 模块 | 大小 | 职责 |
|------|------|------|
| `libPixOCR2` | 15 MB | OCR 核心引擎 |
| `libPixVision` | 14 MB | ZXing + OpenCV（二维码、条形码、视觉） |
| `libPixFormulaRec` | 7 MB | 公式识别 |
| `libPixModelRunner` | 324 KB | 模型运行器 |
| `libPixLatex2MathML` | 3.8 MB | LaTeX → MathML 转换 |

OCR 流水线（从 `libPixOCR2` 符号推断）：
1. **检测**：`PixOcr::PixOcrRunner::submitTask(Params)` → 本地 Caffe 模型（`detect.caffemodel`）
2. **识别**：`runModel(cv::Mat, RecParams, TextBlockList&, ...)` → 本地 Caffe 模型（`sr.caffemodel`）
3. **布局**：`PixOcr::PixOcrLayout(cv::Mat, TextBoxList, ParagraphModelParams, TextDirection)` → ONNX 模型（`paragraph_recognition.onnx`）
4. **云端补充**：`/api2/ai/ocr/latexformula`（公式）、`/api2/tr/table-recognition/image`（表格）

Bundle 内模型文件：
```
Resources/model/detect.caffemodel      -- 文字检测
Resources/model/detect.prototxt        -- 检测网络配置
Resources/model/sr.caffemodel          -- 文字识别
Resources/model/sr.prototxt            -- 识别网络配置
Resources/model/paragraph_recognition.onnx  -- 段落布局
Resources/model/cb6cc28d4121651b3f5bc3daecc9188e.bin
Resources/model/2478d3813bea9afacf7fee18abb09d45.bin
```

OCR UI：
- `PixOcrUI`（Qt 资源前缀）
- `OcrLanguageMenu`、`OcrConfirmedDialog`、`OcrTextBlockItem`、`OcrTextLineItem`
- `PixFloatTextLayerItem` — 浮动文字层
- `PixOcrTable` — 表格识别
- 操作："Detect Text"、"Detect Text And Copy"、"Copy Detected Text"、"Auto Detect"、"AutoCrop"

### 媒体/录屏

| 模块 | 大小 | 职责 |
|------|------|------|
| `libPixAVCodec` | 17 MB | AV1（libaom）+ H.264 编码 |
| `libPixMovie` | 1.3 MB | 视频播放 |
| `libPixLottie` | 775 KB | Lottie 动画 |

录屏：
- `ScreenRecordWindow`、`QuickScreenRecorder`、`ScreenPlaybackWindow`
- `PixScreenStreamer::captureTo(QImage&)` + `hasFrameChanged()`（帧变化检测，静态帧跳过编码省 CPU）
- `PixAsyncH264ExportEncoder`
- 输出格式：`.mp4` / `.mkv`
- 崩溃恢复：`screen_record_recovered.mp4`
- 音频：`CoreAudioCaptureThread`
- 点击特效（Lottie 动画）：`click_fireworks.json`、`click_floral.json`、`click_ray.json`、`click_ripple.json`、`click_starts.json`

### 认证/网络

| 模块 | 大小 | 职责 |
|------|------|------|
| `libPixAuth` | 10 MB | 认证/授权 |
| `libPixNetwork` | 306 KB | HTTP 客户端 |
| `libPixDownload` | 259 KB | 文件下载 |

API 端点：
```
https://api.pixpin.cn / https://api.pixpin.com
  /api2/ai/ocr/latexformula              -- 公式识别
  /api2/ai/translate/image               -- 图片翻译
  /api2/ai/translate/text                -- 文本翻译
  /api2/ai/translate/texts               -- 批量翻译
  /api2/ai/tts/synthesize                -- TTS 语音合成
  /api2/tr/table-recognition/image       -- 表格识别
  /api2/tr/translate/image               -- 翻译（旧接口）
  /api2/tr/translate/text                -- 翻译（旧接口）

第三方翻译 API 兜底：
  https://api.fanyi.baidu.com/api/trans/sdk/picture
  https://api.fanyi.baidu.com/api/trans/vip/translate
  https://openapi.youdao.com/api
  https://openapi.youdao.com/ocrtransapi

OCR 模型下载：
  https://download.pixpin.cn/PixOcrBin/
  https://pixpin.cdn.dfyun.com.cn/PixOcrBin/
```

### 配置/系统

| 模块 | 大小 | 职责 |
|------|------|------|
| `libPixConfiguration` | 797 KB | 配置存储 + 设置 UI |
| `libPixUtils` | 7.9 MB | 通用工具 |
| `libPixSystemUtils` | 359 KB | 系统工具 |
| `libPixProgramManage` | 173 KB | 进程管理 |

配置体系：
- `ConfStorage` — 单例，JSON 本地文件 + 云端同步
- `ConfStorage::createDynamicConf` — 运行时动态配置类（服务端可推送）
- `KeySequenceEdit` — 快捷键编辑控件
- `PdConfManage` — 设置面板管理（`addConfBool`、`addConfInt32`）

### UI 组件

| 模块 | 大小 | 关键组件 |
|------|------|---------|
| `libPixWidget` | 2.4 MB | `ColorPanel`（颜色面板）、`FloatPanel`（浮动面板，可 attach/detach 父窗口）、`BubbleFrame`（气泡框）、`PixComboBox`、`PixHoverTip`（悬浮提示）、`PixImageView`（图片查看器，支持缩放/平移/pixelRatio） |
| `libPixWidget2` | 965 KB | 额外组件 |
| `libPixActionsBar` | 310 KB | 操作栏 |
| `libPixStyle` | 543 KB | QSS 样式表 |
| `libPixColorPalette` | 290 KB | 调色板 |
| `libPixLottie` | 775 KB | Lottie 动画播放器 |
| `libPixPinIcon` | 1 MB | 图标字体（`PixPinIconfont`） |
| `libPixPinTutorial` | 8.6 MB | 新手教程/引导 |
| `libPixNotification` | 345 KB | 通知 |
| `libPixStat` | 174 KB | 统计/埋点 |

## 截图流程（重建）

```
PixScreenManager::init(ScreenshotConfig)
  → screenList()                          // 枚举显示器
  → grabScreen(QRect, bool)               // SCK（macOS 15+）/ CGDisplay（旧版）
  → ScreenShotView（全屏覆盖层）
  → 用户拖拽选区
  → 创建 ScreenPixmapItem
  → TrigerGraphicScene + TrigerGraphicEditManage（进入标注编辑）
  → 完成后：
      ClipSetPixmap(QPixmap, ClipMetaData)  // 写入剪贴板
      / SaveImage(QPixmap, path)            // 保存文件
      / PixSaveTask（异步保存队列）
      / PixTableRecAirDropFile              // 表格识别 + AirDrop
```

## 录屏流程

```
QuickScreenRecorder
  → PixScreenStreamer::captureTo(QImage&)   // 逐帧捕获
  → hasFrameChanged()                        // 帧变化检测（静态帧跳过）
  → CoreAudioCaptureThread                   // 音频
  → PixAsyncH264ExportEncoder                // H.264 或 AV1（libaom）
  → screen_record.mp4 / .mkv
  → 崩溃 → screen_record_recovered.mp4
```

## 值得注意的设计决策

1. **Qt 5 而非原生** — 跨平台（同时出 Windows 版），QGraphicsScene 作标注画布
2. **本地 + 云端混合 AI** — PaddleOCR 本地跑；公式/表格走云端 API
3. **帧变化检测录屏** — `hasFrameChanged()` 静态帧不编码，省 CPU
4. **贴图紧凑布局** — 算法排列 + 负间隙确认（空间不够时提示）
5. **25 种 EditItem + 独立 Config** — 可扩展的标注体系
6. **CGEventTap 全局热键** — `PixGloabalMouse` 系统级拦截修饰键+点击组合
7. **录屏崩溃恢复** — `screen_record_recovered.mp4`
8. **脚本 API** — `PixPinScript::runScriptWithShotView` / `runScriptWithPinWindow`
9. **动态配置** — `ConfStorage::createDynamicConf` 支持服务端推送运行时配置变更
10. **图标字体** — `PixPinIconfont`（单个 TTF，QSS 中引用）

## 对 Index 的借鉴价值

| PixPin 特性 | Index 可参考 |
|------------|-------------|
| AI 自动马赛克（`EditItemAutoMosaic` + 目标检测） | 标注工具可加人脸/敏感区域自动检测打码 |
| 贴图紧凑布局算法（`getCompactOccupiedRect` + `moveWindowToCompactRect`） | 未来 Pin/剪贴板排列可参考其紧凑排列算法 |
| 帧变化检测录屏 | 如果做录屏功能，静态帧跳过编码 |
| 本地 OCR（PaddleOCR Caffe）+ 云端补充 | 未来加 OCR 可参考此模式 |
| `PixCursorPixmap::GetCursor` | 截图时保留鼠标光标形状 |
| 25 工具标注 + Config 体系 + `GenSerialPath`（序号） | 我们的 AnnotationState 已类似；序号/水印/放大镜/自定义形状可参考 |
| `FloatPanel` attach/detach 父窗口 | 我们的覆盖层面板可用类似父窗口附着模式 |
| `PixImageView` pixelRatio | Retina 感知图片显示 |

## 提取命令备忘

```bash
# Bundle 结构
find /Applications/PixPin.app -type f
du -sh /Applications/PixPin.app/Contents/*

# 主二进制信息
file /Applications/PixPin.app/Contents/MacOS/PixPin
lipo -thin arm64 /Applications/PixPin.app/Contents/MacOS/PixPin -output ~/tools/reverse/pixpin/PixPin_arm64

# 符号表
nm /Applications/PixPin.app/Contents/MacOS/PixPin | grep " T " | c++filt
nm /Applications/PixPin.app/Contents/Frameworks/libPix*.dylib | grep " T " | c++filt

# 字符串
strings /Applications/PixPin.app/Contents/MacOS/PixPin | grep -iE "pattern" | sort -u
```

---

## 补充：跨显示器截图怎么做的（2026-10-18）

### 结论

PixPin 不是「每块屏一个独立选区」，而是**把整个虚拟桌面当成一张画布**：

1. 枚举所有屏幕，取所有 `geometry` 的并集（`wholeRect`）；
2. 逐屏抓图，把每屏 pixmap 按 `屏幕原点 - wholeRect 原点` 放进**同一个 QGraphicsScene**；
3. 只创建一个 `ScreenShotWindow`，窗口 geometry 直接设为 `wholeRect`；
4. 选区是一个虚拟桌面坐标系里的 `QRect`，所以可以自然跨屏；
5. 输出时从共享 scene 里按选区裁一张图（`getSceneExportRectPixmap`）。

### 证据

`PixScreenManager`（`libPixScreenManager.dylib`）：

- 符号：`screenList()`、`wholeRect()`、`screenAt(QPoint,bool,bool)`、`size()`；
- `refresh()` 内调用 `QRect::operator|` 合并各屏 geometry（反汇编 `0x560c`）；
- 运行日志（本机 4 屏）：

```
[PixScreenManager::refresh] screenCount= 4 wholeRect= QRect(-720,0 3992x2025)
    Geometry: QRect(0,0 1920x1080)
    Geometry: QRect(1920,0 1352x878)
    Geometry: QRect(-720,0 720x1280)
    Geometry: QRect(126,1080 1680x945)
```

单窗口、整张虚拟画布：

- `ScreenShotWindow::ScreenShotWindow(ScreenShotBgLayer*, QWidget*)` 反汇编：
  `bl PixScreenManager::wholeRect()` → `bl QWidget::setGeometry(QRect const&)`，
  即窗口几何 = 虚拟桌面并集；
- `PixPin::initScreenShotWindow` 只构造一次 `ScreenShotWindow`（日志也只有一条
  `Screenshot window constructed`）；
- `ScreenShotView::prepareScreenShotBgLayer` 调用一次 `screenList()`，为每屏创建
  `ScreenPixmapItem`，并 `QGraphicsItem::setPos` 到 `屏幕 geometry - wholeRect 原点`；
- 每屏抓图在 `ScreenPixmapItem::syncPixmap(PixScreen*)` 内完成，日志按屏串行：

```
Screen capture started geometry=0,0 1920x1080
Screen capture finished geometry=0,0 1920x1080 isNull=false
Screen capture started geometry=1920,0 1352x878
...
Screenshot background capture finished
```

输出：

- `ScreenShotView::getRawPixmap(bool)` 调用
  `getSceneExportRectPixmap(QGraphicsScene*, ...)`，即按选区从共享 scene 裁剪；
  跨屏选区只是 scene 上的一个更大的矩形。

### 代价与边界

- 打开截图前要**串行抓完所有屏**：本机 4 屏约 230ms（每屏 50–70ms），窗口之后才显示。
- `wholeRect` 是**包围盒**，不是屏幕并集：L 形布局里屏幕之间的空档也属于窗口矩形，
  但不在任何显示器上，用户看不见；输出按选区裁剪时同样只会取到有画面的区域。
- 混合 DPI 靠 Qt 每屏 pixmap 的 devicePixelRatio 处理；窗口/场景坐标是逻辑点。

### 对 Index 的启示

Index 现在是反过来的：`SelectionOverlayController` 为每块屏建一个 `SelectionModel`，
`bounds = snapshot.frame`，所有落点/选区都 `intersection(bounds)` 夹在单屏内，
因此天然不支持跨屏拖拽。

两条可行路线：

**A. 照搬 PixPin：一个跨屏大窗口**
- 冻结帧拼成一张虚拟画布，一个 borderless window 覆盖 `wholeRect`，一个 selection。
- 优点：坐标最简单，鼠标天然跨屏。
- 风险：AppKit 单窗口只有一个 backing scale，混合 DPI 会糊；跨 Space/全屏、
  4K+竖屏的大窗口合成成本高；与 Index 现有「每屏一张冻结图」架构冲突较大。

**B. 保留每屏 overlay，共享一个虚拟选区（推荐）**
- 新增 `VirtualSelection`（全局 rect + phase），由 `SelectionOverlayController` 持有；
- 每屏 `OverlayView` 只负责把全局选区与自己的 `snapshot.frame` 求交并绘制；
- 鼠标事件先转全局坐标再更新共享选区，不再按单屏 bounds 夹；
- 输出按屏裁剪 `intersection(globalRect, display.frame)`，再按各屏 scale 拼回一张图；
- 工具栏锚定在指针所在屏，Esc/确认仍走一个协调器。
- 这样保留冻结帧、逐屏快照、混合 DPI 与现有 SCK 事务门。
