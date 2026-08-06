# CI 与协同

## 现状

| 项 | 值 |
| --- | --- |
| GitLab | `http://ds720.local:2224`（容器跑在群晖上，端口 `2224→80`、`2223→443`、`2222→22`） |
| SSH 别名 | `gitlab`（`~/.ssh/config` 里已配好，指向 `ds720.local:2222`） |
| 仓库远端 | **还没建**（`git remote -v` 是空的） |
| Runner | **还没有**（NAS 上没有 runner 容器，本机也没装 `gitlab-runner`） |

## 为什么 runner 必须在 Mac 上

这个项目只能在 macOS 上构建：AppKit、ScreenCaptureKit、Vision 在 Linux 上不存在。
GitLab 装在群晖上没问题（它只负责托管和调度），但**执行构建的 runner 必须是一台 Mac**。
NAS 上再怎么配也跑不了 `swift build`。

现实选择只有两个：

1. **就用这台开发机**当 runner（shell executor）。小团队最省事，代价是构建会占用你本机资源，
   而且 runner 用的是你的登录环境（能拿到钥匙串里的 `MacShot Dev` 证书，签名和本地一致）。
2. **另找一台 Mac** 常开当构建机。干净，但要有闲置机器。

## 首次搭建

### 1. 在 GitLab 上建项目并接上远端

在 `http://ds720.local:2224` 建一个空项目（假设路径 `wxyhgk/macshot`），然后：

```bash
git remote add origin gitlab:wxyhgk/macshot.git
git push -u origin main
git push --tags
```

注意用 `gitlab:` 这个 SSH 别名而不是写全 `ssh://git@ds720.local:2222/...` ——
别名里已经带了端口和密钥。

> NAS 响应比较慢，第一次 `ssh -T gitlab` 可能要十几秒才回 banner。
> 如果超时，把 `ConnectTimeout` 放大到 20 秒再试，别急着判定服务挂了。

### 2. 装 runner 并注册

在要当构建机的那台 Mac 上：

```bash
brew install gitlab-runner
brew services start gitlab-runner        # 开机自启

gitlab-runner register \
  --url http://ds720.local:2224/ \
  --token <项目 → Settings → CI/CD → Runners 里生成的 token> \
  --executor shell \
  --description "mac-mini-swift" \
  --tag-list macos
```

`--tag-list macos` 必须有：`.gitlab-ci.yml` 里所有 job 都要求 `tags: [macos]`，
没这个标签的 runner 不会接活（这正是防止有人日后加一台 Linux runner 然后
在 `import AppKit` 那行失败）。

`--executor shell` 意味着 job 直接在这台机器上跑，用的是 runner 用户的环境。
确认那个用户能跑通 `swift --version` 和 `security find-identity -v -p codesigning`。

### 3. 验证

推一个空提交，看流水线是否变绿：

```bash
git commit --allow-empty -m "chore: 验证 CI"
git push
```

## 流水线做什么

两个 stage，都只是调用 `scripts/check.sh` 或 `build.sh` —— **和本地跑的是同一套脚本**，
检查逻辑只有一份，不会出现「CI 过了本地没过」。

| Job | 触发 | 内容 |
| --- | --- | --- |
| `check` | 每次推送 | 构建 + 76 条测试 + 三条架构纪律 |
| `package` | 打 tag 时 | release 构建、签名校验、产出 `.app.zip` 作为 artifact |

## 本地提交前

```bash
./scripts/check.sh          # 构建 + 测试 + 架构纪律，约半分钟
./scripts/check.sh --full   # 再加上组装并签名 .app
```

想让它自动跑，装一个 pre-push hook：

```bash
printf '#!/bin/sh\nexec ./scripts/check.sh\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

（`.git/hooks` 不进版本库，每个人各装各的。)

## 三条架构纪律

`scripts/check.sh` 会静态检查三条 `ARCHITECTURE.md` / `DIRECTORY.md` 里立过、
但此前**只靠人工巡检**的规矩。人工巡检真的漏过——2026-07 那次审计才发现批量导出
偷偷内联了一份目录选择面板。新人不会读完两千行文档才动手，机器读得完。

1. **模态面板与弹窗只许出现在 `Platform/`**
   界面层不许自己拼 `NSAlert()` / `NSOpenPanel()` / `runModal()`，
   一律走 `AppAlert` / `ImageExporter` / `SystemNavigator`。
2. **依赖只向下**
   `Capture/`、`Render/`、`Annotation/`、`Storage/` 等不许引用 `GalleryView`、
   `EditorView` 这些界面层类型。（注释里提到不算——检查会跳过注释行。）
3. **工具契约没有被绕过**
   领域层与渲染层里不许再出现 `switch layer.kind`。加标注工具请在
   `Annotation/Tools/` 下新建文件，往 `BuiltinTools.all` 加一行。

三条都是 grep 级别的检查，会漏掉换个写法的违例——它们拦的是「顺手写歪」，
不是「铁了心绕开」。真正的保证仍然是 code review。

## 已知的坑

**改了协议之后出现莫名其妙的 SIGSEGV**，堆栈显示调用 A 方法却崩在 B 方法里 ——
那是 SwiftPM 增量构建留下的错位见证表，不是代码问题。`swift package clean`
再跑一次即可。CI 上已经默认先清理（`check.sh` 认 `CI` 环境变量），所以只会在本地遇到。
