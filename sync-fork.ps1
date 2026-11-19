<#
sync-fork.ps1 —— 把上游 microsoft/winget-pkgs 的 master 合并进你的 fork

等价于网页上的 "Sync fork" 按钮，区别是可以定时跑。
注意：fork 里通常有你抢跑的版本提交，所以这是**合并**（会多一个 merge commit），不是快进。
上游合并了你的 PR 之后，两边内容完全相同，git 会自动解掉，不会冲突。

冲突只会在一种情况下出现：上游先合了「别人为同一个版本」提交的 PR，
而那份清单的字节和你 fork 里的不一样 —— 这时需要人来判断留哪一份。

环境变量：GH_TOKEN —— classic PAT，勾 public_repo（需要对 fork 有写权限）
退出码：0 成功（含"已经一致"）；1 失败（含冲突）
#>
param(
    [string]$Fork = $(if ($env:FORK) { $env:FORK } else { 'zhou-dev-design/winget-pkgs' }),
    [string]$Upstream = 'microsoft/winget-pkgs',
    [string]$Branch = 'master'
)

$ErrorActionPreference = 'Stop'

$tok = $env:GH_TOKEN
if ($tok) { $tok = ($tok -replace '\s', '') }
if (-not $tok) {
    Write-Host '::error title=缺少凭据::需要 GH_TOKEN secret（classic PAT，勾 public_repo）'
    exit 1
}

$h = @{
    Authorization          = "Bearer $tok"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'winget-sync-fork'
}

function Get-BranchSha([string]$repo) {
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/git/ref/heads/$Branch" -Headers $h -TimeoutSec 60
    $r.object.sha
}

$upSha = $null; $fkSha = $null
try {
    $upSha = Get-BranchSha $Upstream
    $fkSha = Get-BranchSha $Fork
} catch {
    $code = ''
    if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
    Write-Host "::error title=读不到分支::上游或 fork 的 $Branch 读取失败（$code）$($_.Exception.Message)"
    exit 1
}
Write-Host "上游 $($upSha.Substring(0, 8))   fork $($fkSha.Substring(0, 8))"

if ($upSha -eq $fkSha) {
    Write-Host '两边已经完全一致，本次不用动'
    exit 0
}

try {
    $body = @{ branch = $Branch } | ConvertTo-Json -Compress
    $r = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Fork/merge-upstream" `
        -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 600
    Write-Host "merge_type = $($r.merge_type)   $($r.message)"
} catch {
    $code = ''
    if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
    if ($code -eq 409) {
        Write-Host '::error title=合并冲突::fork 与上游在同一路径上都有新增且内容不同，需要人工判断'
        Write-Host @'
常见原因：上游先合了「别人为同一版本」提交的 PR，那份清单和你 fork 里的字节不一致。

三种处理方式（任选）：
  1. 本地合并：git fetch upstream && git merge upstream/master，解冲突后 push；
  2. 删掉 fork 里冲突的那个版本目录（如果上游那份更好），再让本工作流重跑一次；
  3. 在网页点 Sync fork，按提示手工解决。

处理完后本工作流会照常按小时同步。
'@
        exit 1
    }
    Write-Host "失败（$code）：$($_.Exception.Message)"
    exit 1
}

$newSha = Get-BranchSha $Fork
Write-Host "fork 现在 $($newSha.Substring(0, 8))"
exit 0
