# CI 与协同

Index 只能在 macOS 上构建：AppKit、ScreenCaptureKit 和 Vision 在 Linux 上不可用。
仓库中的 CI 只复用本地检查脚本，不在无桌面会话的 runner 上触发截图、录屏或 TCC 授权。

## GitHub Actions

公共仓库默认使用 [`.github/workflows/check.yml`](../.github/workflows/check.yml)：

- `push` 和 `pull_request` 触发；
- 使用固定的 `macos-15` runner；
- `GITHUB_TOKEN` 只有 `contents: read` 权限；
- 只运行 `./scripts/check.sh`，覆盖 Swift 构建、全部测试和架构纪律；
- 同一分支有新提交时取消尚未完成的旧任务。

这条工作流不会运行 `build.sh release`。可分发 App 需要可信的 Developer ID 证书和
Apple 公证凭据，不应把本地开发证书上传到公共 CI。

## 本地提交前

```bash
./scripts/check.sh
```

需要额外验证 App 组装、签名和安全替换流程时运行：

```bash
./scripts/check.sh --full
```

`--full` 可能退出并重新启动当前运行的 Index；它不会触发真实截图，但会改变 App 进程。

可选的本地 pre-push hook：

```bash
printf '#!/bin/sh\nexec ./scripts/check.sh\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

`.git/hooks` 不进入版本库，每位贡献者需要自行安装。

## Release 与签名

Release App 只能通过以下命令组装：

```bash
./build.sh release
```

脚本会在旁路目录完整组装和签名，校验成功后退出旧进程，再同卷原子替换固定路径下的
`build/MacShot.app`。不得手工覆盖正在运行的 App；详细原因见
[`docs/errors/2026-08-11-running-app-rebuild-tcc-identity.md`](errors/2026-08-11-running-app-rebuild-tcc-identity.md)。

本地开发可先运行 `./scripts/make-dev-cert.sh` 创建固定的 `MacShot Dev` 身份。该证书只适合
开发机，不适合向其他用户分发。GitHub Release 的可下载 App 应使用 Developer ID Application
签名并完成 Apple notarization。

## GitLab 兼容

仓库保留 [`.gitlab-ci.yml`](../.gitlab-ci.yml)，供已有 GitLab 或自托管环境使用。注册一个
macOS shell runner，并给它添加 `macos` 标签即可执行检查；具体 GitLab 地址、SSH 别名和
runner token 属于部署方私有配置，不应写入仓库。

tag 对应的 GitLab `package` job 会执行 Release 组装，因此 runner 的钥匙串必须预先安装
稳定签名身份。若产物要公开分发，仍必须使用 Developer ID 并完成公证。

## 增量构建异常

协议变更后如果出现与源码不相符的 SIGSEGV，可能是 SwiftPM 增量产物中的旧见证表。
先清理后再验证：

```bash
swift package clean
./scripts/check.sh
```

CI 设置了 `CI=true`，`check.sh` 会自动执行对应的干净构建路径。
