# 安全策略

## 支持范围

安全修复以默认分支的最新版本为准。历史 tag 仅用于追踪，不承诺单独回补。

## 报告漏洞

仓库公开后，请优先通过 GitHub 仓库的 **Security → Report a vulnerability** 私密报告功能联系
维护者。若私密报告尚未启用，请先通过维护者的 GitHub 主页建立非敏感联系，不要直接创建包含
利用细节、真实截图、数据库或凭据的公开 issue。

报告中可以包含：

- 受影响的版本或 commit；
- 可复现的最小步骤；
- 预期影响；
- 已脱敏的日志或测试样例。

请不要提交：

- `~/Library/Application Support/Index/` 下的真实图库或数据库；
- 图床请求头、访问 token、浏览器 cookie 或 Native Messaging 私有数据；
- 签名证书、私钥、provisioning profile 或 notarization 凭据。

## 分发安全

本地 `Index Dev` 证书只用于保持开发机上的 TCC 身份稳定。公开二进制必须使用 Developer ID
Application 签名并完成 Apple notarization；不要把开发证书或私钥提交到仓库或公共 CI。
