# Mac App Store 发布

Index 的直装版与商店版使用同一份 Swift 源码，但分发签名必须隔离：

- `./build.sh release` 仍生成固定路径 `build/Index.app`，用于本地验证和 Developer ID 直装分发；
- `scripts/package-app-store.sh` 只复制该 App，在旁路目录启用 App Sandbox、嵌入 provisioning profile，
  清除下载文件继承的扩展属性，最终生成 `build/app-store/Index.pkg`；
- 商店脚本不会就地重签、覆盖或尝试启动 Mac App Store 签名副本。

## Apple 后台准备

1. 注册显式 App ID：`com.wxyhgk.index`。
2. 创建 App Store Connect 的 macOS App 记录，版本号与 `Resources/Info.plist` 一致。
3. 准备应用签名身份：`Apple Distribution` 或 `Mac App Distribution`。
4. 准备安装包签名身份：`Mac Installer Distribution`。
5. 创建 `Mac App Store Connect` provisioning profile，并下载到本机。

现有 APNs、WeatherKit 等服务密钥不是代码签名身份，不能替代第 3、4 步。

## 生成上传包

不要把证书、私钥或 provisioning profile 放进仓库。通过环境变量传入本机路径和钥匙串身份：

```bash
INDEX_APP_STORE_PROFILE="$HOME/Downloads/Index_Mac_App_Store.provisionprofile" \
INDEX_APP_STORE_APP_IDENTITY="Apple Distribution: YOUR NAME (TEAMID)" \
INDEX_APP_STORE_INSTALLER_IDENTITY="Mac Installer Distribution: YOUR NAME (TEAMID)" \
./scripts/package-app-store.sh
```

两个 identity 变量可省略；脚本会从钥匙串选择第一个匹配身份。团队同时维护多个证书时应显式填写。

生成后先检查：

```bash
codesign --verify --deep --strict build/app-store/Index.app
pkgutil --check-signature build/app-store/Index.pkg
```

脚本会在签名前递归清除旁路副本的扩展属性，并逐文件确认不存在
`com.apple.quarantine`。下载的 provisioning profile 如果把该属性带入 payload，
App Store Connect 会以 `91109` 拒绝构建。

最后在 Transporter 中添加 `build/app-store/Index.pkg` 并交付。上传只把二进制送入 App Store
Connect；仍需在网页选择构建、填写隐私信息、审核说明和截图，再提交 App Review。

## 当前商店沙盒能力

商店副本声明以下最小能力：

- 出站网络连接；
- 用户通过系统面板选择的文件读写；
- 用户明确开启后的麦克风输入；
- App Sandbox。

屏幕录制仍由 macOS 的 Screen Recording TCC 权限控制。审核说明应写清首次启动、截图、录屏、
剪贴板直接粘贴分别会触发哪些系统权限，以及拒绝权限后的降级行为。

首个商店版本不申请临时 Apple Events 沙盒例外，因此不会启动 `/usr/bin/osascript`，也不会自动
记录浏览器当前页面 URL。GitHub 直装版保留这项可选能力；后续若要在商店版恢复，应先改为
沙盒兼容的实现并单独评估审核必要性。
