# Index 隐私说明

最后更新：2026-08-24

Index 是本地优先的 macOS 图片资料库和截图工具。当前版本不包含分析 SDK、广告 SDK、
遥测上报或自建账号系统，也不会自动把图库内容发送给项目维护者。

## 本地保存的数据

图库原图、缩略图、录屏、分子附件、修订历史、OCR 文本、分类、标签、搜索索引和可选的
语义向量默认保存在应用自己的数据目录。GitHub 直装版使用：

```text
~/Library/Application Support/Index/
```

Mac App Store 版启用 App Sandbox，系统会把同一相对目录映射到 Index 的沙盒容器中。应用不会
在用户不知情的情况下绕过沙盒读取直装版目录；用户可以通过系统文件选择面板显式导入内容。

为了保持既有 TCC 授权和数据兼容，用户可见品牌已改为 Index，但目录名和 Bundle ID 仍沿用
Index。设置项保存在 Bundle ID `com.wxyhgk.index` 对应的 macOS UserDefaults 中。

## 系统权限

- **屏幕录制**：用于冻结显示器画面、滚动截图和录屏。
- **自动化 / Apple Events（直装版）**：在受支持的浏览器中读取当前页面标题和网址；拒绝后
  仍可截图，但来源网址可能为空。首个 Mac App Store 版本不申请这项沙盒例外，也不读取浏览器 URL。
- **麦克风**：用户在录屏设置中主动开启麦克风后，用于把声音写入本次录屏；默认关闭。
- **辅助功能**：有两项彼此独立、都需用户主动开启的用途：
  1. 用户要求把剪贴板条目直接粘贴到其它 App 时，向当前前台 App 发送一次 `⌘V`；拒绝后
     仍可复制，用户可以手动粘贴。
  2. 用户打开“输入即检索（兼容中文输入法）”后，每 300ms 最多读取当前光标前 128 个已经
     提交的字符，在本机提取短语并查询本地数据库。密码框、Index 自身窗口和无法安全读取
     文本范围的控件会被跳过；读取内容不持久化、不写日志、不发送到网络，关闭功能后立即停止。

Index 不要求辅助功能权限来模拟滚动；滚动截图由用户自己滚动页面。

## 会发生的网络请求

Index 没有后台遥测。只有以下功能会联网：

| 功能 | 触发方式 | 发送或接收的内容 |
| --- | --- | --- |
| 语义搜索模型 | 用户在设置中主动下载 | 从 Apple 的 Hugging Face 仓库下载 MobileCLIP Core ML 模型，并从 GitHub 下载 BPE 词表；搜索推理留在本机 |
| 3D 分子钉图 | 用户打开 3D 分子窗口 | 从 jsDelivr 加载固定版本的 3Dmol.js；XYZ 坐标在本地 WebView 中解析，不通过应用代码上传 |
| 自定义图床 | 用户点击上传或测试上传 | 将当前 PNG 和用户配置的请求头发送到用户填写的 HTTP(S) 地址 |
| 选区 AI | 用户框选内容并明确选择解释、翻译、LaTeX 或表格任务 | 将框选后的局部 PNG、任务类型和可选 OCR 文本发送到用户配置的 AI 端点；不发送整张屏幕 |
| AI Agent | 用户启用插件并发送消息 | 将消息和为完成请求所需的本地搜索结果发送到用户配置的兼容 API 端点 |
| Edge 图片导入 Demo（直装版） | 用户在网页图片上选择右键菜单 | Edge 重新读取所选图片及页面元数据，经 Native Messaging 写入本机收件箱，再交给 Index 入库 |

Selection AI 与 Agent API Key 保存在 macOS 钥匙串。图床请求头可能包含 token；当前版本仍把
图床配置明文保存在 UserDefaults，请使用权限最小、可撤销的 token，不要复用主账号密码。

## Edge 扩展权限

Edge Demo 申请 `http://*/*` 和 `https://*/*` 主机权限，是为了在用户明确点击图片右键菜单后
重新读取该图片。扩展不会批量抓取页面图片，也不会把数据发送到 Index 之外的服务；图片先进入
`~/Library/Application Support/Index/browser-inbox/`，入库完成后临时目录会被清理。

## 删除数据

退出 Index 后，删除 `~/Library/Application Support/Index/` 可移除图库、模型和浏览器导入
临时数据。以下命令可删除偏好设置：

```bash
defaults delete com.wxyhgk.index
```

Edge 连接器可通过 `./scripts/install-edge-demo.sh --uninstall` 卸载。执行删除前请先导出需要保留的
图片；删除图库目录不可撤销。

## 问题反馈

隐私或安全问题请优先使用 GitHub 的私密漏洞报告功能，不要在公开 issue 中附带真实截图、
数据库、访问 token 或包含个人信息的日志。参见 [SECURITY.md](SECURITY.md)。
