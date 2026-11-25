# winget-bump-ci

给 `zhou-dev-design/winget-pkgs` 里两个包跟版本、开 PR、并在 PR 验证卡住时重跑的小仓库
（`Microsoft.VisualStudioCode`、`DeepSeek.DeepSeekHarnessDesktop`）。

不克隆 winget-pkgs（78 万个文件 / 近 1 GB），全程走 GitHub API。

---

## 三个工作流

| 工作流 | 触发 | 干什么 |
| --- | --- | --- |
| `bump.yml` | **只能手动** | 探测新版本 → 生成清单 → `winget validate` → 写进 fork `master` → 向上游开 PR → 补 CLA 同意 |
| `sync-fork.yml` | 每小时 cron + 手动 | 把上游 `microsoft/winget-pkgs` 合并进 fork（等价于网页的 Sync fork） |
| `rerun.yml` | **只能手动** | PR 验证卡住时，造一个同 tree 的空提交把分支往前挪，触发重新验证 |

原来还有一个 `schedule probe`（只为验证 GitHub 的 cron 到底会不会触发），结论已经明确，2026-11-25 删掉了。

## 日常怎么用

### 1. 软件出新版本了 → 手动跑 bump

Actions → `bump winget manifests` → **Run workflow**。它会自己判断有没有新版本：

- 有新版本：生成清单、校验、写进 fork、开 PR；
- 没有新版本：一行 `已是最新` 就结束，几十秒。

**没有自动触发。** 想要自动，见下面「可选：外部轮询器」。

### 2. fork 落后上游 → 不用管

`sync-fork.yml` 每小时自己合一次。注意 GitHub 的 cron 在这个账号上不稳定
（实测间隔 2~5 小时），落后一会儿不影响什么，bump 时会跳过上游已有的版本。

### 3. PR 的验证卡住了 → 手动跑 rerun

Actions → `re-run validation (empty commit)` → Run workflow，`branch` 留空即可
（自动扫你自己名下所有开着的 PR）。原理见下面「PR 验证卡住时」。

---

## 需要的 secret

`GH_TOKEN`：classic PAT，勾 `public_repo`。
fine-grained token 不行 —— GitHub 不允许它向「你不是成员的公共仓库」提交内容。

## 清单是怎么生成的

1. 读 fork 里的版本表（`contents` API）；
2. 用最新版本的清单当基底（优先 raw CDN，失败退回 API base64）；
3. 探测上游发版（VS Code 走 `update.code.visualstudio.com`，DeepSeek 走 release tag + HEAD 探测）；
4. 生成新版本清单，`winget validate` 校验；
5. `blobs → trees(base_tree) → commits → PATCH ref`，一条 commit 原子写入 fork 的 `master`；
6. 从上游 master 建 `bump/<包>/<版本>` 分支并开 PR（分支里只有清单，不含 `.github`）。

## 为什么 bump 是手动的（2026-11-25）

原来挂着 15 分钟的 cron。后来发现两件事，干脆改成手动：

1. **GitHub 的 cron 在这个账号上不可靠。** 建库后 2 小时 40 分内，bump 的 12 个槽、sync 的 3 个槽、
   外加一个 `*/5` 最小探测工作流的 2 个槽**全部为 0**。已经排除：仓库 public、非 fork、默认分支
   `main`、workflow 状态 active、手动能跑、GitHub 状态页无事故。后来它自己恢复了，但间隔 2~5 小时。
2. **跟版不是高频动作**（VS Code 一周一版），手动点一下完全够，红了还能立刻看。

### 脚本里其实是两段独立的流程

这个很重要，否则会误解红色的含义：

1. 探测 → 生成清单 → `validate` → **写进 fork `master`**；
2. 从上游 master 建分支 → 写文件 → **向上游开 PR**。

任何一段出错只记 `$script:failed`，另一段照常跑完，最后由 `exit 1` 统一标红。
所以 **「PR 开出来了但 job 是红的」是正常的组合** —— 见下面「排错」。

唯一的例外是 `validate` 没过：脚本会把这个「包/版本」记下来，PR 阶段直接跳过，
避免把没通过校验的清单推上去（#20 就是踩了这个坑）。

现在每段出错都会打 `::error title=...::` 注解，在 Actions 的 **Annotations** 面板能直接看到原因
（日志下载需要仓库 admin 权限，注解不需要）。API 报错也会带上 HTTP 状态码和响应体。

## CLA 同意（`-ClaAgree`）

`@microsoft-github-policy-service` 要求**每个新 PR 都评论一次** `agree`，签过一次不免。
不评论 → PR 一直挂着 `Needs-CLA`，永远合不进去。

`bump.yml` 带 `-ClaAgree`：

- 每开一个新 PR，立刻评论一次；
- 收尾时再扫一遍自己名下「开着且带 `Needs-CLA`」的 PR，把历史遗留的补上。

**注意**：这条评论是用你的 PAT 以你的身份发的，等于把 CLA 同意这件事交给 CI 代发。

---

## PR 验证卡住时，怎么自己重跑

winget-pkgs 的验证只认 moderator 的 `@wingetbot run`（`doc/Moderation.md` 写死了这是 moderator 的
Trigger），普通作者发这个指令会被回 `Commenter does not have sufficient privileges`。
但验证 App 会响应 PR 的 `synchronize` 事件 —— 分支有了新提交就会重新排队。

`rerun.yml` 干的是：**用当前 commit 的同一个 tree 造一个「空提交」，再把分支 ref 指过去**。
文件一个字节都不变，但 PR head 变了，验证就会起一个全新实例。

用法：`branch` 留空 = 自动找你名下所有开着的 PR；填值 = 只重跑那一个。`dry_run` 选 true 可先看 head/tree。

注意：

- 这只是重新排队，不保证一次就过（见下面 08 的说明）；
- 空提交会留在 PR 历史里（内容为空，01 检查只看文件差异，不受影响）；
- 维护者已经自己重跑过（时间线里有 `@wingetbot run` by `wingetbot`）就别重复点。

## 08. Installation Validation 红了的常见原因

它不是清单问题，而是验证服务**在真机上装完再让 Defender 扫一遍**这一步挂了。判据：

- **01–07 全绿 + 08 里四个安装包都是 `Completed` + 08 整体失败 → 一定是宿主环境问题**，等重跑；
- 若某个安装包是 `Waiting` / 长时间 `InProgress` → 排队或超时，也是等；
- 只有出现安装退出码非 0，或标签是 `Validation-Installation-Error` / `Validation-Unattended-Failed`，
  才是清单本身要改。

`Validation-Defender-Error` 目前是平台侧的系统性问题（同一时刻几十个 PR 一起挂），
维护者知道，会手工认定通过（`Validation-Completed`）或批量重跑。

## fork 同步要点

- fork 里通常有你抢跑的版本提交，所以这是**合并**（会多一个 merge commit），不是快进；
- 上游合了你的 PR 之后两边内容完全相同，git 自动解掉，不冲突；
- 唯一会冲突的情况：上游先合了「别人为同一版本」提交的 PR，且清单字节和你 fork 里的不同。
  这时工作流会红并给出三种处理方式（本地合 / 删掉 fork 里那份 / 网页手工解）。

---

## 可选：外部轮询器（想自动跟版才装）

别人的 release 事件没法直接变成我们的 workflow 事件（webhook 只能装在自己仓库上），
所以「自动」只能是「某处定时轮询 → 版本变了才 dispatch」。脚本在 `poller/`：

| 文件 | 用途 |
| --- | --- |
| `poller/winget-poll.sh` | Linux / 飞牛 NAS 版（POSIX sh，只要 curl） |
| `poller/winget-poll.service` / `.timer` | systemd 定时器，每 15 分钟 |
| `poller/winget-poll.ps1` | Windows 版（配合计划任务） |

每 15 分钟只做 3~5 个请求：查 VS Code 版本、查 DeepSeek 最新 release；
**仓库里没有该版本、且 `bump/<包>/<版本>` 分支也不存在**时才 dispatch `bump.yml`；
距上次 sync 超过 1 小时则 dispatch `sync-fork.yml`。没有新版本时零触发。

### 部署：飞牛 NAS / 任意 Linux

```sh
mkdir -p /opt/winget-poll
cp poller/winget-poll.sh /opt/winget-poll/
chmod +x /opt/winget-poll/winget-poll.sh

printf '%s' 'ghp_xxx' > /opt/winget-poll/token   # 和 GitHub Secrets 里同一个 PAT
chmod 600 /opt/winget-poll/token
/opt/winget-poll/winget-poll.sh                   # 先手跑一次看日志

cp poller/winget-poll.service poller/winget-poll.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now winget-poll.timer
journalctl -u winget-poll -n 30 --no-pager
```

### 部署：Windows

```powershell
'ghp_xxx' | Set-Content C:\winget-poll\token.txt -NoNewline
schtasks /Create /SC MINUTE /MO 15 /TN winget-poll /F `
  /TR "pwsh -NoProfile -WindowStyle Hidden -File C:\winget-poll\winget-poll.ps1"
```

计划任务里勾「不管用户是否登录都运行」。关机期间错过的轮询会在下次开机补上（靠状态文件）。

---

## 文件

| 文件 | 说明 |
| --- | --- |
| `.github/workflows/bump.yml` | 跟版工作流（手动，开 PR 并补 CLA） |
| `.github/workflows/sync-fork.yml` | 同步工作流（小时级 cron + 手动） |
| `.github/workflows/rerun.yml` | 验证重跑（手动） |
| `bump-winget.ps1` | 跟版脚本（与 `winget-local/ci-bump.ps1` 同源） |
| `sync-fork.ps1` | 同步脚本 |
| `tools/rerun-validation.py` | 造同 tree 空提交、前移 PR 分支 |
| `poller/` | 外部轮询器（可选） |

## 本地试跑

```powershell
$env:GH_TOKEN = 'ghp_...'
$wd = Join-Path $env:TEMP 'winget-work'; New-Item -ItemType Directory -Force $wd | Out-Null
.\bump-winget.ps1 -RepoRoot $wd -WorkDir $wd -Fork zhou-dev-design/winget-pkgs -ApiCommit -OpenPr -ClaAgree -DryRun
```

去掉 `-DryRun` 才会真的写 fork；`-Only <包ID>` 只跑一个包。
`-ApiCommit` 模式不要求工作区是 git 仓库（目录只是临时产出）。

## 排错：几个常见现象

| 现象 | 含义 | 怎么办 |
| --- | --- | --- |
| PR 开出来了，但 job 红 | 第一段（写 fork `master`）失败，第二段（开 PR）成功 | 看 Annotations 里的 `::error::`，按 HTTP 状态码判断；PR 本身没问题 |
| `winget validate 失败（exit 1）` 但输出是 `succeeded with warnings` | runner 上的 winget 比清单 schema 旧，把 warning 判成失败（#20 的真因） | 已修：以输出文本为准（`succeeded` = 通过），warning 只打印 |
| `Argument name was not recognized: '--output-locale'` | runner 的 winget 太老（实测 v1.11.510），不认这两个开关 | 已修：首次调用探测一次参数能力并缓存，不认就退回原始命令 |
| `winget validate 失败` 且输出 `Manifest Error: ...` | 生成清单真的不合规 | 注解里带 winget 原始输出，按提示改模板 |
| 08 红，四包都 `Completed` | 验证机 Defender 扫描撞车 | 等维护者重跑，或自己跑 `rerun.yml` |
| sync 红（409） | 上游也有同一版本且字节不同 | 按日志提示三选一处理 |
| `Commenter does not have sufficient privileges` | 你用作者身份发了 `@wingetbot run` | 那是指令只有 moderator 能用，改用 `rerun.yml` |
