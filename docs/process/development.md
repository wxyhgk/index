# 开发流程（最小闭环）

一句话：

> **同一时间只有一个可验证的变更在流动；它必须在合入前穿过同一道自动门；穿过时留下「为什么」。**

这份文件不是项目管理软件，是三条规则和六个问题的书面版本。工具可以换，规则不变；改规则就改这里。

## 三条规则

1. **一次只让一个变更流动。** 开工前工作区干净；一个功能分支存活不超过 3 天。
2. **合入前必须过同一道门。** 本地与 CI 都只认 `./scripts/check.sh`；红了不进入下一步。
3. **非平凡变更留下「为什么」。** 提交正文写动机，决策写 `docs/changes/`，事故写 `docs/errors/`。

## 六个问题

任何开发动作都要回答下面六个问题。少答一个，状态就会漏进脑子或工作区。

| 问题 | 本仓库的答案 | 存放位置 |
|---|---|---|
| 接下来做什么？ | 一个待办列表（Issue 或 `docs/plan.md`，二选一） | GitHub Issues |
| 现在能开工吗？ | 目标 / 验收标准 / 验证命令，各一行 | Issue 正文 |
| 做完了吗？ | `check.sh` 绿 + 人工验证清单打勾 | PR / 提交 |
| 为什么这么做？ | 一段动机说明 | 提交正文、`docs/changes/` |
| 现在线上是什么？ | tag = 版本号，附件由 `release.yml` 生成 | `vX.Y.Z` tag |
| 系统还健康吗？ | 每周看四个数 | `./scripts/dev-status.sh` |

## 状态机

```
Inbox ──▶ Ready ──▶ Doing ──▶ Review ──▶ Merged ──▶ Released
           │          │          │
           │          └──────────┘  门禁红 / 返工
           │
      DoR 未满足就退回
```

- **DoR（可以开工）**：目标、非目标、验收标准、验证命令四件事写清楚；有明确不做什么。
- **WIP 上限 2**：1 个功能 + 1 个修复。要开第三个，先合掉一个。
- **DoD（可以合并）**：
  1. `./scripts/check.sh` 全绿（含全部测试与 12 条架构纪律）；
  2. 触碰截图 / 覆盖层 / 钉图 / 录屏时，真实桌面验证至少一次，并在 PR 写实际结果；
  3. 非平凡变更在 `docs/changes/` 留一篇，或提交正文写清动机；
  4. 没有顺手夹带无关改动。

## 提交与分支

```
type(scope): 中文摘要

为什么这么改（一到三行）。
验证：跑了什么、结果是什么。
```

- `type`：`feat` `fix` `refactor` `perf` `test` `docs` `chore`
- `scope`：`capture` `annotate` `toolbar` `selection` `clipboard` `recording` `pin` `gallery` `input` `sync` `infra`
- 一个提交一个可回滚的意图；不要求拆到行级，但不要把两个功能塞进同一笔。

分支：`feat/<slug>`、`fix/<slug>`，合并后删除。

**必须走 PR 的改动**：触碰 `Sources/IndexApp/Platform/`、ScreenCaptureKit、签名 / 打包脚本，或改动超过 5 个文件。其余改动可直接推 `main`，由 pre-push hook 兜底。

安装 pre-push（每台机器一次）：

```bash
./scripts/install-hooks.sh
```

## 红线

- `main` 红 → 停止新功能，先修；红的时间记入周复盘。
- **不许用降低验证强度换绿**：跳过测试、删断言、缩小样本、改测量精度、用 `--filter` 冒充全量，都不算通过。
- 不许手工覆盖或删除正在运行的 `build/Index.app`，只能走 `./build.sh release`。
- 不许把凭据写进源码或提交历史；发现后先轮换，再清理历史。

## 发布

- 一键发布：`./scripts/release.sh patch|minor|major`；不带参数则发布 `Info.plist` 里的当前版本。
  脚本会校验工作区干净、`main` 与远端同步、门禁全绿，然后生成 `CHANGELOG.md`、更新版本号、
  提交并打 tag。**它不会自动推送**，最后两步由人执行：
  `git push origin main` 和 `git push origin refs/tags/vX.Y.Z`。
  不要用 `--follow-tags`：它只推 annotated tag，会漏掉本次的轻量 tag，
  却把本地历史 annotated tag 一起推上去触发发布。
- 先预览：`./scripts/release.sh --dry-run`（只打印版本与变更清单，不改文件）。
- 版本号以 `Resources/Info.plist` 的 `CFBundleShortVersionString` 为准，tag 必须是 `vX.Y.Z` 且与之一致（`release.yml` 会校验）。
- 组装只允许 `./build.sh release`；`check.sh --full` 会额外验证组装与签名。
- 发布前确认工作区干净、`main` 与 `origin/main` 同步、门禁绿。

## 每周复盘

运行 `./scripts/dev-status.sh`，只看四个数：

1. **WIP**：同时在做的变更数（应 ≤ 2）；
2. **未验证提交**：领先远端、从未经 CI 的提交数（应 = 0）；
3. **红 main 时长**：本周 `main` 门禁失败的累计时间；
4. **Issue 覆盖率**：本周提交中能对应到 Issue 的比例。

四个数里任何一个持续变差，先减需求、加门禁，不要加流程。
