# winget-bump-ci

给 `zhou-dev-design/winget-pkgs` 里两个包跟版本的小工作流（Microsoft.VisualStudioCode、DeepSeek.DeepSeekHarnessDesktop）。

工作流不克隆 winget-pkgs（78 万个文件 / 近 1 GB），全程走 GitHub API：

1. 读 fork 里的版本表（`contents` API）；
2. 用最新版本的清单当基底（优先 raw CDN，失败退回 API base64）；
3. 探测上游发版（VS Code 走 `update.code.visualstudio.com`，DeepSeek 走 release tag + HEAD 探测）；
4. 生成新版本清单，`winget validate` 校验；
5. `blobs → trees(base_tree) → commits → PATCH ref`，一条 commit 原子写入 fork 的 `master`；
6. 从上游 master 建 `bump/<包>/<版本>` 分支并开 PR（分支里只有清单，不含 `.github`）。

## 需要的 secret

`GH_TOKEN`：classic PAT，勾 `public_repo`。
fine-grained token 不行——GitHub 不允许它向「你不是成员的公共仓库」提交内容。

同时需要给**外部轮询器**一份同样的 token（见下面「触发方式」），这是唯一的手工步骤。

---

## 触发方式：外部轮询 → 有更新才 dispatch

### 为什么不用 GitHub 自己的 schedule

`schedule` 在这个账号下**实测完全不触发**，两个仓库都一样：

| 仓库 | 实测 |
| --- | --- |
| `zhou-dev-design/winget-pkgs`（fork） | 从建好到现在 `event=schedule` 运行数恒为 0 |
| `zhou-dev-design/winget-bump-ci`（本仓库） | 建好后 2 小时 40 分内，bump 的 12 个槽、sync 的 3 个槽、外加一个 `*/5` 最小探测工作流的 2 个槽，**全部为 0** |

已经排除的原因：仓库是 public、不是 fork、默认分支是 `main`、两个 workflow 都是
`state=active`、`workflow_dispatch` 手动能跑、GitHub 状态页无 Actions 事故。
最小探测工作流只有一个 `date` 命令、5 秒跑完，它也不跑 —— 所以不是 cron 表达式或脚本的问题，
是调度器没把本仓库收进去。

**结论：任何「继续依赖 GitHub cron」的方案都不必再试。**

### 那真正的「有更新再触发」怎么做

GitHub 不允许把 webhook 装到别人的仓库上，所以别人的 release 事件没法直接变成我们的
workflow 事件。只能：**某处定时轮询 → 发现版本变了 → `workflow_dispatch`**。

轮询放在一台常开的机器上，脚本在 `poller/`：

| 文件 | 用途 |
| --- | --- |
| `poller/winget-poll.sh` | Linux / 飞牛 NAS 版（POSIX sh，只要 curl） |
| `poller/winget-poll.service` / `.timer` | systemd 定时器（每 15 分钟） |
| `poller/winget-poll.ps1` | Windows 版（配合计划任务） |

它每 15 分钟只做 3~5 个 HTTP 请求：

1. 查 VS Code 稳定版版本号（1 次）；
2. 查 DeepSeek Harness 最新 release（1 次；上游用 prerelease 发版，
   所以不能用 `/releases/latest`，要拉列表按 `published_at` 挑）；
3. 若「仓库里没有该版本」且「`bump/<包>/<版本>` 分支也不存在」→ dispatch `bump.yml`；
4. 距上次 sync 超过 1 小时 → dispatch `sync-fork.yml`。

**没有新版本时零 dispatch**，一年也不会白跑一次。已开 PR 但还没合并的版本也算「在流程里」，
不会每小时重复触发。

### 部署：飞牛 NAS / 任意 Linux

```sh
mkdir -p /opt/winget-poll
cp poller/winget-poll.sh /opt/winget-poll/
chmod +x /opt/winget-poll/winget-poll.sh

# token：和 GitHub Secrets 里那个一样的 classic PAT
printf '%s' 'ghp_xxx' > /opt/winget-poll/token
chmod 600 /opt/winget-poll/token

# 先手工跑一次确认能通
/opt/winget-poll/winget-poll.sh

cp poller/winget-poll.service poller/winget-poll.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now winget-poll.timer
systemctl list-timers winget-poll.timer
journalctl -u winget-poll -n 30 --no-pager
```

### 部署：Windows

```powershell
# token.txt 放在脚本同目录
'ghp_xxx' | Set-Content C:\winget-poll\token.txt -NoNewline

schtasks /Create /SC MINUTE /MO 15 /TN winget-poll /F `
  /TR "pwsh -NoProfile -WindowStyle Hidden -File C:\winget-poll\winget-poll.ps1"
```

计划任务里勾上「不管用户是否登录都运行」。机器关机期间错过的轮询会在下次开机补上
（靠状态文件里的 `VSCODE_OK` / `DSH_OK`）。

### 保留 GitHub cron 作为兜底

`bump.yml` / `sync-fork.yml` 里的 `schedule` 暂时留着：它现在不触发，但万一哪天调度器恢复了，
多跑一次也无害（bump 内部对「已有开着的 PR」「上游已有该版本」都会跳过）。
等确认外部轮询稳定后可以删掉那几行。

---

## fork 同步（sync-fork.ps1）

等价于网页上的 **Sync fork**，只是能定时跑。调的是
`POST /repos/{fork}/merge-upstream`，让 GitHub 服务端做合并。

要点：

- fork 里通常有你抢跑的版本提交，所以这是**合并**（会多一个 merge commit），不是快进；
- 上游合了你的 PR 之后，两边内容完全相同，git 自动解掉，不冲突；
- 唯一会冲突的情况：上游先合了「别人为同一版本」提交的 PR，且清单字节和你 fork 里的不同。
  这时工作流会红，并按提示给三种处理方式（本地合 / 删掉 fork 里那份 / 网页手工解）。

## 文件

| 文件 | 说明 |
| --- | --- |
| `.github/workflows/bump.yml` | 跟版工作流（由轮询器或手动触发） |
| `.github/workflows/sync-fork.yml` | 同步工作流（由轮询器或手动触发） |
| `bump-winget.ps1` | 跟版脚本（与 `winget-local/ci-bump.ps1` 同源） |
| `sync-fork.ps1` | 同步脚本 |
| `poller/` | 外部轮询器 |

## 本地试跑

```powershell
$env:GH_TOKEN = 'ghp_...'
$wd = Join-Path $env:TEMP 'winget-work'; New-Item -ItemType Directory -Force $wd | Out-Null
.\bump-winget.ps1 -RepoRoot $wd -WorkDir $wd -Fork zhou-dev-design/winget-pkgs -ApiCommit -OpenPr -DryRun
```

去掉 `-DryRun` 才会真的写 fork；`-Only <包ID>` 可以只跑一个包。

---

## PR 验证卡住时，怎么自己重跑

winget-pkgs 的验证只认 moderator 的 `@wingetbot run`（`doc/Moderation.md` 里写死了这是
moderator 的 Trigger），普通作者发这个指令会被回 `Commenter does not have sufficient privileges`。
但验证 App 会响应 PR 的 `synchronize` 事件 —— 分支有了新提交就会重新排队。

所以 `rerun.yml` 干的是：**用当前 commit 的同一个 tree 造一个「空提交」，再把分支 ref 指过去**。
文件一个字节都不变，但 PR head 变了，验证就会起一个全新实例。

用法：Actions → `re-run validation (empty commit)` → Run workflow。
`branch` 默认填了 VS Code 那个分支，`dry_run` 选 true 可以先看它读到的 head / tree 而不写入。

注意：

- 这只是重新排队，已经确认是 Defender 竞态的话，可能还要再撞一次，重跑一两次是正常的；
- 空提交会留在 PR 历史里（内容为空，01 检查只看文件差异，不受影响）；
- 如果维护者已经自己重跑过（PR 时间线里有 `@wingetbot run` by `wingetbot`），就不要重复点。

---

## PR 验证卡住时，怎么自己重跑

winget-pkgs 的验证只认 moderator 的 `@wingetbot run`（`doc/Moderation.md` 里写死了这是
moderator 的 Trigger），普通作者发这个指令会被回 `Commenter does not have sufficient privileges`。
但验证 App 会响应 PR 的 `synchronize` 事件 —— 分支有了新提交就会重新排队。

所以 `rerun.yml` 干的是：**用当前 commit 的同一个 tree 造一个「空提交」，再把分支 ref 指过去**。
文件一个字节都不变，但 PR head 变了，验证就会起一个全新实例。

用法：Actions → `re-run validation (empty commit)` → Run workflow。
`branch` 默认填了 VS Code 那个分支，`dry_run` 选 true 可以先看它读到的 head / tree 而不写入。

注意：

- 这只是重新排队，已经确认是 Defender 竞态的话，可能还要再撞一次，重跑一两次是正常的；
- 空提交会留在 PR 历史里（内容为空，01 检查只看文件差异，不受影响）；
- 如果维护者已经自己重跑过（PR 时间线里有 `@wingetbot run` by `wingetbot`），就不要重复点。
