# Index Edge 图片导入 Demo

在 Microsoft Edge 的网页图片上点击右键，选择「保存图片到 Index 图库」。扩展读取
浏览器当前拿到的图片内容，通过 Native Messaging 写入 Index 的兼容收件箱，再用
`index://import/browser?id=<UUID>` 唤醒 Index；应用自己负责解码和入库。
导入在后台完成，不会自动打开图库或切走浏览器焦点。Index 真正入库成功后，当前
网页顶部中央会显示一条轻量结果通知，包含文件名、主动「查看」和关闭按钮；只有点击
「查看」才会打开 Index 图库。失败通知会显示具体原因并停留更久。Edge 工具栏中的
扩展图标也会同步显示 `✓` 或 `!` 作为禁止脚本注入页面的兜底。

## 安装

```bash
./scripts/install-edge-demo.sh
```

脚本会安装用户级 Native Messaging host 配置并打开 `edge://extensions`。随后：

1. 开启「开发人员模式」。
2. 点击「加载解压缩的扩展」。
3. 选择脚本输出的 `BrowserExtensions/Edge` 目录。

扩展通过 manifest `key` 固定为 `anhidejnknnfchdjgnkbkgnifophmgnm`，Native Messaging
配置只允许这个扩展 ID 调用。卸载连接器：

```bash
./scripts/install-edge-demo.sh --uninstall
```

## Demo 边界

- 支持 PNG、JPEG、HEIC/HEIF、TIFF，单张最多 25 MB。
- 普通 `http(s)` 图片会携带 Edge 当前凭据重新读取；服务器若禁止扩展重新请求，可能失败。
- `blob:`、Canvas、CSS 背景图和 WebP 暂不支持；这些属于下一步的内容脚本/格式扩展。
- 图片只会进入兼容目录 `~/Library/Application Support/Index/browser-inbox/<UUID>/`，Index URL
  命令不接受任意文件路径。导入完成后该临时目录会被删除。
- Native Messaging host 最多等待 15 秒，由 Index 回写真实入库结果后才向 Edge 报成功。

官方机制说明：

- [Microsoft Edge Native Messaging](https://learn.microsoft.com/en-us/microsoft-edge/extensions/developer-guide/native-messaging)
- [在 Edge 中旁加载扩展](https://learn.microsoft.com/en-us/microsoft-edge/extensions/getting-started/extension-sideloading)
