# 运行中覆盖 Index 导致构建后截图失效

日期：2026-08-11  
状态：已修复，并完成不重启电脑的因果验证

## 用户可见现象

每次构建并替换新的 `build/Index.app` 后，Index 截图容易超时或失效；重启电脑后又恢复，因此一度看起来像 ScreenCaptureKit、Sidecar 或显示器拓扑故障。

## 实际根因

旧版 `build.sh` 会直接删除并重建：

```text
build/Index.app
```

但旧 Index 进程此时可能仍在运行。这样会同时存在两种身份：

- 运行中 PID 的 audit token 和 code object 属于旧二进制；
- 相同绝对路径上的 App 已经变成新二进制和新签名内容。

即使前后都使用固定的 `Index Dev` 证书，TCC/replayd 在解析客户端时仍可能遇到“旧进程身份 + 新磁盘内容”的不一致。重启电脑之所以有效，是因为重启清除了旧 PID 和关联的 XPC 会话；并不是每个新版本天然需要重启。

此外，如果构建静默退回 ad-hoc 签名，二进制代码变化会导致 cdhash 改变，也会破坏跨版本稳定的屏幕录制授权。

## 修复

`build.sh` 现在采用安全替换流程：

1. 在 `build/.Index-stage.*` 中完整组装新 App；
2. 使用 Developer ID 或固定的 `Index Dev` 身份签名；
3. 在 staging 路径完成严格签名校验；
4. 如果旧 Index 正在运行，先请求其正常退出；
5. 正常退出超时后，只向精确匹配绝对路径的旧 PID 发送 TERM；
6. 确认旧 PID 已完全消失后，在同一文件系统内原子替换 bundle；
7. 如果构建前 App 正在运行，替换后自动启动新版本；
8. 未找到稳定签名证书时直接失败，不再静默退回 ad-hoc；只有显式设置 `INDEX_ALLOW_ADHOC=1` 才允许临时使用。

构建流程还增加了目录锁，防止两个组装任务同时替换 `.app`。

## 因果验证

2026-08-11 23:45，在不重启、不退出登录的情况下完成真实运行中构建：

- 构建前 PID：`3526`；
- 新 bundle 在旁路目录完成签名后，PID `3526` 才退出；
- 新版本自动启动，PID：`6285`；
- 构建前后 designated requirement 完全一致：

```text
identifier "com.wxyhgk.index"
certificate leaf = 74b621417da94768be39dc6b4f2b7811615a5ead
```

- `codesign --verify --deep --strict` 通过；
- `replayd` 保持同一 PID `4190`；
- `replayd runs=7 / successive crashes=6` 在构建前后没有增加；
- 没有遗留 staging 目录；
- 用户随后直接测试截图成功，没有重启电脑。

这完成了因果确认：故障来自运行中原地覆盖 App，而不是构建后必须重启 macOS。

## 防回归

`scripts/check.sh` 增加“纪律七：运行中的 App 不得被原地覆盖”，检查：

- `build.sh` 不得重新出现直接删除 `$APP_BUNDLE` 的逻辑；
- 必须先创建并签名 `$STAGED_APP`；
- 必须等待旧进程退出；
- 必须通过 rename/move 原子替换；
- ad-hoc 只能显式启用。

当前验证结果：

```text
Executed 111 tests, with 0 failures
7 项架构纪律全部通过
```

## 日常使用

正常构建：

```bash
./build.sh release
```

如果 Index 原本正在运行，脚本会自动完成旧进程退出、替换和新版本启动。正常情况下不需要重启电脑，也不需要退出登录。

首次在一台新机器上开发时，先创建固定签名身份：

```bash
./scripts/make-dev-cert.sh
```
