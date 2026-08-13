# 第三方软件与模型声明

本文件记录 Index 当前直接使用或按需加载的第三方组件。Index 自身的源代码采用
[GNU GPL v3.0 or later](LICENSE)；各第三方项目和模型仍分别适用下列上游条款，
不会因 Index 使用 GPL 而被重新授权。

## GRDB.swift

- 用途：SQLite 数据访问与观察。
- 当前锁定版本：7.8.0（见 `Package.resolved`）。
- 许可证：MIT。
- Copyright © 2015–2025 Gwendal Roué。
- 上游：[groue/GRDB.swift](https://github.com/groue/GRDB.swift)；
  [LICENSE](https://github.com/groue/GRDB.swift/blob/master/LICENSE)。

## 3Dmol.js

- 用途：交互式 XYZ 分子显示与定格。
- 当前加载版本：2.5.5，通过 jsDelivr 按需加载，不存入仓库或 App bundle。
- 许可证：BSD-3-Clause；上游许可证同时列出其包含的 GLmol、Three.js 和 jQuery 声明。
- Copyright © 2014 University of Pittsburgh and contributors。
- 上游：[3dmol/3Dmol.js](https://github.com/3dmol/3Dmol.js)；
  [LICENSE](https://github.com/3dmol/3Dmol.js/blob/master/LICENSE)。
- 论文：Rego N, Koes D. 3Dmol.js: molecular visualization with WebGL. Bioinformatics. 2015.

## MobileCLIP Core ML 模型

- 用途：可选的本地语义图片搜索。
- 分发方式：模型不进入仓库或 App bundle；用户在设置中主动从
  [`apple/coreml-mobileclip`](https://huggingface.co/apple/coreml-mobileclip) 下载。
- 许可证：模型页面当前标记为 Apple Sample Code License（`apple-ascl`）；下载和使用模型时，
  用户应查阅并遵守模型页面当时提供的完整条款。
- 项目与论文：[apple/ml-mobileclip](https://github.com/apple/ml-mobileclip)。

## CLIP-Finder2 与 OpenCLIP tokenizer

- 用途：`CLIPTokenizer.swift` 由 CLIP-Finder2 的 Swift tokenizer 移植，并遵循 OpenCLIP 的
  tokenizer 结构；BPE 词表由用户按需下载。
- CLIP-Finder2：MIT，Copyright © 2024 Fabio Guzman；
  [项目](https://github.com/fguzman82/CLIP-Finder2)，
  [LICENSE](https://github.com/fguzman82/CLIP-Finder2/blob/main/LICENSE)。
- OpenCLIP：MIT；[mlfoundations/open_clip](https://github.com/mlfoundations/open_clip)，
  [LICENSE](https://github.com/mlfoundations/open_clip/blob/main/LICENSE)。

## Apple 系统框架

AppKit、ScreenCaptureKit、Vision、Core ML、WebKit 等由 macOS 提供，不作为第三方源码随本仓库
分发，其使用受 Apple 平台和 SDK 条款约束。
