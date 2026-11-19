# winget-bump-ci

给 `zhou-dev-design/winget-pkgs` 里两个包跟版本的小工作流（Microsoft.VisualStudioCode、DeepSeek.DeepSeekHarnessDesktop）。

放在这个**非 fork** 仓库里，是因为 fork 仓库的 `schedule` 触发默认不启用——
`event=schedule` 的运行数会一直是 0，而 workflow 状态却显示 `active`。

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

## 触发

- **bump**：`cron: '7,22,37,52 * * * *'`（约 15 分钟一轮，避开整点高峰）+ 手动
- **sync**：`cron: '23 * * * *'`（每小时把上游合并进 fork）+ 手动

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
| `.github/workflows/bump.yml` | 跟版工作流（15 分钟一轮） |
| `.github/workflows/sync-fork.yml` | 同步工作流（每小时一轮） |
| `bump-winget.ps1` | 跟版脚本（与 `winget-local/ci-bump.ps1` 同源） |
| `sync-fork.ps1` | 同步脚本 |

## 为什么不放在 fork 里

fork 仓库的 `schedule` 默认不触发：`event=schedule` 的运行数会一直是 0，
而 workflow 状态却显示 `active`、UI 也没有「启用」按钮。所以调度必须放在非 fork 仓库。
这也是本仓库存在的唯一理由。

## 本地试跑

```powershell
$env:GH_TOKEN = 'ghp_...'
$wd = Join-Path $env:TEMP 'winget-work'; New-Item -ItemType Directory -Force $wd | Out-Null
.\bump-winget.ps1 -RepoRoot $wd -WorkDir $wd -Fork zhou-dev-design/winget-pkgs -ApiCommit -OpenPr -DryRun
```

去掉 `-DryRun` 才会真的写 fork；`-Only <包ID>` 可以只跑一个包。
