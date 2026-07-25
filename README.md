# MacShot

macOS 截图工具 demo：截图 → 钉图 → 自动入库 → 图库检索 → 非破坏性图层编辑。

## 构建 & 运行

```bash
./scripts/make-dev-cert.sh   # 只需跑一次，创建固定签名身份
./build.sh                   # 产出 build/MacShot.app
open build/MacShot.app
```

首次运行需要在 **系统设置 → 隐私与安全性 → 屏幕录制** 中勾选 MacShot，然后**重启 App**。

### 关于「每次构建都要重新授权」

macOS 的 TCC 是这样认 App 的：

- **ad-hoc 签名**（`codesign -s -`）没有身份信息，TCC 只能记二进制的 **cdhash** ——
  代码改一行哈希就变，授权立刻失效。
- **固定证书签名**下，TCC 记的是 designated requirement：
  `identifier "com.wxyhgk.macshot" and certificate leaf = H"<证书指纹>"`
  —— 与代码内容无关，重新构建多少次都不变。

`scripts/make-dev-cert.sh` 会在登录钥匙串里自签一张代码签名证书（不需要 Apple 开发者账号），
`build.sh` 会自动优先使用它。签名身份优先级：Developer ID → MacShot Dev（本地自签）→ ad-hoc。

注意 **App 路径也要保持稳定**，`build/MacShot.app` 换位置会被当成另一个 App 重新问一次权限。

撤销：打开「钥匙串访问」，在登录钥匙串里删掉名为 `MacShot Dev` 的证书。

## 使用

| 操作 | 快捷键 |
|---|---|
| 截图 | `⌃⌘A` |
| 打开图库 | `⌃⌘G` |

截图界面：
- **拖拽** → 自由选区
- **单击窗口** → 整窗捕获（悬停时蓝框高亮）
- **ESC / 右键** → 取消

钉图窗口：
- 拖拽移动，**滚轮**缩放，**⌘+滚轮**调透明度
- `⌘C` 复制，`ESC` 关闭，**双击**在图库中打开，右键菜单

菜单栏可开关：截图后自动钉图 / 自动复制到剪贴板 / 自动 OCR。

## 架构

```
Sources/MacShot/
  App/          入口、菜单栏、全局快捷键、截图流程编排
  Capture/      ScreenCaptureKit 捕获、选区覆盖层、坐标系换算、元数据采集
  Storage/      GRDB schema、文件布局、图层与修订模型、图片编解码
  Render/       图层 → 图像 的渲染管线
  Intelligence/ Vision OCR（图像理解的第 1 层）
  Pin/          钉图窗口
  UI/           图库、详情、标注编辑器
```

### 磁盘布局

```
~/Library/Application Support/MacShot/
  originals/<sha256>.png    原图，写入后永不修改（内容寻址，天然去重）
  thumbnails/<sha256>.jpg
  index.sqlite              元数据 + 修订 + FTS5 全文索引
```

### 非破坏性编辑

原图是不可变的字节。标注以**结构化图层**存在 `revision` 表里：

```
shot (原图元数据)
 └── revision  (append-only，parentID 指向上一版)
       └── layersJSON: [Layer]   矩形/椭圆/箭头/直线/文字/高亮/马赛克/裁剪
```

每次「保存为新版本」都是 `INSERT`，从不 `UPDATE` 旧记录 —— 所以编辑历史天然是完整的、可无限回溯的。
裁剪同样是一个图层，不动原图。只有导出/复制时才由 `LayerRenderer` flatten 渲染一次。

### 元数据采集

| 字段 | 来源 | 可靠性 |
|---|---|---|
| App 名 / bundleID | `CGWindowList` 命中 + `NSRunningApplication` | 稳 |
| App 版本 / build | 由 bundleURL 读 `Info.plist` | 稳 |
| 窗口标题 | `CGWindowList` 的 `kCGWindowName` | 需屏幕录制权限 |
| 显示器 / 缩放 / 选区 | `NSScreen` | 稳 |
| 浏览器网址 | AppleScript（Safari / Chrome / Edge / Arc / Brave / Vivaldi） | 需「自动化」授权，失败静默跳过 |

> 覆盖层一拿到焦点，`frontmostApplication` 就变成 MacShot 自己了 —— 所以前台 App 必须在弹出覆盖层**之前**记录。
> 见 `CaptureCoordinator.begin()`。

### 坐标系

macOS 上三套坐标系混用是这类项目最大的 bug 源，全部收敛在 `Capture/Geometry.swift`：

- **AppKit 全局**：主屏左下原点，Y 向上 —— `NSScreen` / `NSEvent`
- **CoreGraphics 全局**：主屏左上原点，Y 向下 —— `CGWindowListCopyWindowInfo`
- **显示器局部**：该屏左上原点，Y 向下 —— `SCStreamConfiguration.sourceRect`

图层坐标统一用**图像像素、左上原点**。

## 已知边界（demo 范围）

- 选区不支持跨显示器拖拽（限制在起始那块屏内）
- 图层创建后不能拖拽调整位置/大小，只能删除重画
- 修订历史是线性链，`parentID` 已预留但 UI 未做分叉
- Firefox 取不到网址（不支持 AppleScript，需退回 Accessibility API）

## 下一步

1. **图层直接操作** —— 选中后拖拽/缩放/改样式
2. **MobileCLIP → CoreML** —— image embedding 存进 SQLite，语义搜索 + zero-shot 分类。
   接口已经在 `Intelligence/OCRService.swift` 的 `ImageUnderstanding` 协议下预留好了
3. **规则分类** —— bundleID 本身就是最强分类信号（Xcode→代码、Figma→设计），先做规则表再上模型
4. **滚动截图 / 延时截图 / OCR 取词**
5. **Developer ID 签名 + 公证**
