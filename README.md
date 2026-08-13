<p align="center">
  <img src="Resources/Brand/index-app-icon.svg" width="112" alt="Index app icon">
</p>

<h1 align="center">Index</h1>

<p align="center">
  面向 macOS 的本地优先截图、标注与图片资料库。
</p>

<p align="center">
  捕获或导入图片，完成标注、钉图、分类与检索；原图始终保持不变。
</p>

## 界面

<table>
  <tr>
    <td width="50%"><img src="docs/images/index-library.png" alt="Index 图库"><br><b>图库</b> — 浏览、搜索、标注与管理图片</td>
    <td width="50%"><img src="docs/images/index-collections.png" alt="Index 收藏"><br><b>收藏</b> — 用自定义专题集整理图片</td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/index-recordings.png" alt="Index 录屏"><br><b>录屏</b> — 集中查看录屏及其封面</td>
    <td width="50%"><img src="docs/images/index-apps.png" alt="Index 应用"><br><b>应用</b> — 按来源应用聚合图片</td>
  </tr>
</table>

以上截图来自正在运行的 Index，而不是界面设计稿。

## 功能

- 多显示器冻结截图、选区、整窗、延时、滚动截图与录屏
- 矩形、箭头、文字、马赛克、序号、裁剪等非破坏性标注
- 自动入库、收藏集、标签、OCR 全文搜索、以图搜图和语义搜索
- 置顶钉图、快速暂存栏，以及复制 / 保存 / 上传等统一动作
- 从本地或 Edge 扩展导入图片，并保留来源信息
- 复制 XYZ 后生成可旋转的 3D 分子钉图，定格后继续使用同一套标注工具

## 快捷键

| 操作 | 默认快捷键 |
|---|---|
| 截图 | `⌃⌘A` |
| 延时截图 | `⌃⌘D` |
| 滚动截图 | `⌃⌘S` |
| 录屏 | `⌃⌘R` |
| 打开图库 | `⌃⌘G` |
| 从剪贴板钉住 3D 分子 | `⌃⌘M` |

快捷键可以在 Index 设置中修改。

## 构建

要求 macOS 14 或更高版本，并已安装 Xcode Command Line Tools。

```bash
./scripts/make-dev-cert.sh   # 首次构建执行一次
./build.sh release
open build/MacShot.app
```

首次截图前，请在“系统设置 → 隐私与安全性 → 屏幕录制”中允许 Index，然后重新打开 App。

开发检查：

```bash
./scripts/check.sh
```

当前用户品牌为 Index。为兼容既有授权与数据，工程 target、可执行文件、固定 App 路径、
Bundle ID 以及 `~/Library/Application Support/MacShot/` 暂时保留 MacShot 名称。

## 数据与隐私

图库默认保存在本机：

```text
~/Library/Application Support/MacShot/
```

原图采用内容寻址存储，标注以追加式修订保存。OCR、分类、特征与搜索索引也保存在本地；
只有用户主动使用上传或其他联网功能时才会访问对应服务。详见 [PRIVACY.md](PRIVACY.md)。

## 文档

- [架构与扩展点](ARCHITECTURE.md)
- [隐私说明](PRIVACY.md)
- [安全策略](SECURITY.md)
- [第三方声明](THIRD_PARTY_NOTICES.md)
- [CI 与发布构建](docs/ci.md)

## License

[GNU General Public License v3.0 or later](LICENSE)（`GPL-3.0-or-later`）。
