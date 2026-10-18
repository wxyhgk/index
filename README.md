<p align="center">
  <img src="Sources/IndexApp/Resources/index-app-icon.svg" width="112" alt="Index app icon">
</p>

<h1 align="center">Index</h1>

<p align="center">macOS 原生截图、标注与本地优先图片资料库，内置 AI Agent。</p>

<p align="center"><a href="README.en.md">English</a> · <b>简体中文</b></p>

<p align="center">
  <img src="docs/images/index-capture-selection.png" alt="Index 截图冻结与选区界面">
</p>

<p align="center"><b>冻结屏幕 → 框选 → Tool Palette 标注 → 复制 / 保存 / 钉图 / 上传</b></p>

## 特色功能

<table>
  <tr>
    <td width="68%"><img src="docs/images/index-annotation.png" alt="Index 标注编辑器"><br><b>统一 Tool Palette</b> — 截图、钉图和图库编辑器共用同一套标注工具；原图不变，修订可回溯。</td>
    <td width="32%"><img src="docs/images/index-molecule-pin.png" alt="Index 3D 分子钉图"><br><b>3D 分子钉图</b> — 复制 XYZ，旋转到合适视角后定格、标注、复制或保存，同时保留原始坐标。</td>
  </tr>
</table>

- **冻结截图**：多显示器画面一次冻结，框选与标注始终对应同一帧。
- **跨屏选区**：选区可以拖出当前屏幕；每块屏仍用自己的冻结帧原生渲染，输出时按全局坐标拼接。
- **内容库**：截图、录屏、剪切板、AI 对话统一入口，子 tab 切换，支持 OCR、标签、收藏与搜索。
- **AI Agent**：⌘⇧A 呼出，自然语言搜索截图、打开图片、管理插件、修改配置，对话历史持久化可回溯。
- **隐私打码**：系统 Vision 本地检测邮箱、手机号、银行卡、API 密钥与人脸；图库可一键马赛克，截图工具条也能一键检测打码。
- **带壳 / 美化**：macOS 窗口壳、浏览器壳、背景留白、圆角、阴影、水印；截图阶段即可实时预览成品并切换壳样式。
- **OCR / 翻译**：OCR 结果可搜索、可打标签；SelectionAI 支持翻译（需配置 OpenAI 兼容 Provider）。
- **录屏 / GIF**：区域录屏输出 MP4，支持多段拼接与 GIF 导出；不含时间线剪辑。
- **结构化剪贴板**：复制颜色、URL、文本、图片，粘贴时自动识别类型。
- **非破坏性编辑**：原图不可变，标注保存为结构化图层和修订历史。
- **快速输出**：钉图、复制、保存、上传和拖拽暂存走同一套动作。
- **上传 / 同步**：通用 multipart 图床端点 + WebDAV 备份/恢复。
- **输入即检索插件（实验）**：默认兼容微信/苹果拼音，在已提交短语旁召回本地内容；自带 AOSP 拼音输入源降级为可选实验组件。
- **化学工作流**：`复制 XYZ → ⌃⌘M → 旋转 → 定格 → 标注 → 输出`。

## 工作区

<table>
  <tr>
    <td width="50%"><img src="docs/images/index-library.png" alt="Index 内容库"><br><b>内容库</b> — 截图 / 录屏 / 剪切板 / AI 对话，子 tab 切换。</td>
    <td width="50%"><img src="docs/images/index-collections.png" alt="Index 专题集"><br><b>专题集</b> — 手动分组，跨来源组织内容。</td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/images/index-apps.png" alt="Index 应用"><br><b>应用</b> — 按来源 App 浏览截图。</td>
    <td width="50%"><img src="docs/images/index-ai.png" alt="Index AI 对话"><br><b>AI 对话</b> — 自然语言搜索截图、打开图片、管理插件，历史持久化。</td>
  </tr>
</table>

全部图片均来自正在运行的 Index，不是界面设计稿。

## 功能矩阵

> ✅ 完整 · ◐ 部分 / 需配置 · — 无。竞品列依据其公开 README 整理（2026-10），仅作定位参考；
> 版本迭代很快，请以各自最新版为准。

| 能力 | Index | macshot | Snapzy | better-shot |
|---|:---:|:---:|:---:|:---:|
| 区域 / 窗口 / 滚动 / 跨屏截图 | ✅ | ✅ | ✅ | ✅ |
| 标注工具 + 非破坏性修订 | ✅ | ◐ | ◐ | ◐ |
| 敏感内容检测 / 打码 | ✅ | ✅ | ✅ | — |
| OCR | ✅ | ✅ | ✅ | ✅ |
| 翻译 | ◐ 需配置 Provider | ✅ | ✅ | — |
| 录屏 / GIF | ✅ | ✅ | ✅ | ✅ |
| 视频剪辑 | — | ◐ | ✅ | ✅ |
| 带壳 / 背景 / 水印 | ✅ | ✅ | ✅ | ✅ |
| 上传 / 云同步 | ◐ 通用图床 + ✅ WebDAV | ✅ | ✅ | ✅ |
| 内容库 / 历史检索 | ✅ | ◐ | ◐ | ◐ |
| AI Agent | ✅ | — | — | — |
| 3D 分子钉图 | ✅ | — | — | — |
| Homebrew / 公证 / 自动更新 | — / ◐ / — | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ✅ / — |

## 差异点

Index 不打算在「标注工具数量」或「视频编辑器」上做平替，差异化是：

1. **内容库 + AI 检索**：截图、录屏、剪贴板、AI 对话统一入库，可搜索、可分组、可按来源 App 浏览。
2. **AI Agent**：不是聊天装饰，而是能搜图、打开图片、管理插件、修改配置的执行入口。
3. **3D 分子钉图 + 化学工作流**：竞品完全没有覆盖的垂直场景。
4. **非破坏性图层 + 修订历史**：标注是结构化的修订，不是「导出即终稿」。

## 构建

要求 macOS 14+ 与 Xcode Command Line Tools。

```bash
./scripts/make-dev-cert.sh   # 首次构建执行一次
./build.sh release
open build/Index.app
```

主 App 的日常 Release 不再强制组装实验输入源；需要输入源产物时运行
`INDEX_BUILD_INPUT_METHOD=1 ./build.sh release`。

首次截图前，在"系统设置 → 隐私与安全性 → 屏幕录制"中允许 Index，然后重新打开 App。

默认快捷键：截图 `⌃⌘A` · 滚动截图 `⌃⌘S` · 录屏 `⌃⌘R` · 图库 `⌃⌘G` · AI Agent `⌘⇧A` · 3D 分子 `⌃⌘M`。

开发检查：`./scripts/check.sh`

输入即检索插件、可选输入源的构建安装与当前限制见 [输入即检索](docs/input-method.md)。

版本附件见 [GitHub Releases](https://github.com/wxyhgk/index/releases)；发布工作流要求 Developer ID
证书与 Apple 公证凭据，上传前会完成 notarization、staple 和 Gatekeeper 校验。
公开预览附件可能为 ad-hoc 签名，正式分发包以公证通过为准。

SwiftPM target、可执行文件、Bundle ID 和 `~/Library/Application Support/Index/` 仍保留内部名称，
以兼容既有授权与数据；用户看到的 App bundle 与显示名称均为 Index。

## 文档与许可

[架构](ARCHITECTURE.md) · [隐私](PRIVACY.md) · [安全](SECURITY.md) · [第三方声明](THIRD_PARTY_NOTICES.md) · [输入即检索](docs/input-method.md) · [Mac App Store](docs/app-store.md) · [CI](docs/ci.md)

[GNU General Public License v3.0 or later](LICENSE)（`GPL-3.0-or-later`）。
