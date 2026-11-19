# winget-poll.ps1 —— 外部轮询器（Windows 版），逻辑与 winget-poll.sh 一致
#
# 用途：每 15 分钟查一次 VS Code / DeepSeek Harness 的版本，只有「新版本出现且还没进流程」
# 才去 dispatch GitHub Actions 里的 bump 工作流。正常情况下零触发。
#
# 为什么不靠 GitHub 自己的 cron 见 README。
#
# 部署（Windows 计划任务，每 15 分钟）：
#   schtasks /Create /SC MINUTE /MO 15 /TN winget-poll /F ^
#     /TR "pwsh -NoProfile -WindowStyle Hidden -File C:\winget-poll\winget-poll.ps1"
#   记得属性里勾「不管用户是否登录都运行」。
#
# token：与本文件同目录的 token.txt（单行 classic PAT），或环境变量 GH_TOKEN

param(
    [string]$Repo  = 'zhou-dev-design/winget-bump-ci',
    [string]$Fork  = 'zhou-dev-design/winget-pkgs',
    [string]$Ref   = 'main',
    [string]$StateDir = $PSScriptRoot,
    [int]$SyncEvery = 3600,
    [int]$RedispatchAfter = 3600,
    # DeepSeek 上游用 prerelease 发版（dsh-v0.2.2-rc.5），1 = 跟着 rc 走（与 bump 脚本一致）
    [int]$DshPrerelease = 1
)

$ErrorActionPreference = 'Stop'

$tokenFile = Join-Path $StateDir 'token.txt'
$stateFile = Join-Path $StateDir 'state.ps1'

# GitHub 探测地址与清单路径
$VscodeProbe = 'https://update.code.visualstudio.com/api/update/win32-x64-user/stable/latest'
$VscodeDir   = 'manifests/m/Microsoft/VisualStudioCode'
$VscodeId    = 'Microsoft.VisualStudioCode'
$DshRepo     = 'deepseek-ai/deepseek-harness'
$DshPrefix   = 'dsh-v'
$DshDir      = 'manifests/d/DeepSeek/DeepSeekHarnessDesktop'
$DshId       = 'DeepSeek.DeepSeekHarnessDesktop'

$tok = $env:GH_TOKEN
if (-not $tok -and (Test-Path $tokenFile)) { $tok = (Get-Content -Raw $tokenFile) }
if ($tok) { $tok = ($tok -replace '\s', '') }
if (-not $tok) { throw "缺少 token：$tokenFile 或环境变量 GH_TOKEN" }

$h = @{
    Authorization          = "Bearer $tok"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'winget-poll/1.0'
}

function Write-Log([string]$m) {
    Write-Host "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')) $m"
}

# ---- 状态 ----
$state = @{ VSCODE_OK = ''; DSH_OK = ''; VSCODE_TRY = 0; DSH_TRY = 0; LAST_SYNC = 0 }
if (Test-Path $stateFile) {
    try {
        . $stateFile
        $state.VSCODE_OK = $VSCODE_OK; $state.DSH_OK = $DSH_OK
        $state.VSCODE_TRY = [int64]$VSCODE_TRY; $state.DSH_TRY = [int64]$DSH_TRY
        $state.LAST_SYNC = [int64]$LAST_SYNC
    } catch { Write-Log "状态文件损坏，重新开始：$($_.Exception.Message)" }
}

function Get-Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

function Test-Handled([string]$dir, [string]$ver, [string]$id) {
    try { $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$Fork/contents/$dir/$ver" -Headers $h -TimeoutSec 60; return $true } catch { }
    try { $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$Fork/git/ref/heads/bump/$id/$ver" -Headers $h -TimeoutSec 60; return $true } catch { }
    return $false
}

function Invoke-Dispatch([string]$workflow) {
    try {
        Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$Repo/actions/workflows/$workflow/dispatches" `
            -Headers $h -ContentType 'application/json' -Body (@{ ref = $Ref } | ConvertTo-Json -Compress) -TimeoutSec 60
        return $true
    } catch {
        $code = ''
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        Write-Log "dispatch $workflow 失败（HTTP $code）：$($_.Exception.Message)"
        return $false
    }
}

# 统一处理：已落地/已在流程里就记下，否则按节流间隔触发 bump
function Resolve-Version([string]$label, [string]$ver, [string]$dir, [string]$id, [string]$okKey, [string]$tryKey) {
    if (-not $ver) { return }
    if ($ver -eq $state[$okKey]) { return }

    if (Test-Handled $dir $ver $id) {
        $state[$okKey] = $ver
        Write-Log "$label $ver 已在流程里（清单或 bump 分支存在），记为已落地"
        return
    }
    if ((Get-Now) - $state[$tryKey] -lt $RedispatchAfter -and $state[$tryKey] -gt 0) {
        Write-Log "$label $ver 尚未落地，距上次触发不足 $([int]($RedispatchAfter / 60)) 分钟，本轮不重复触发"
        return
    }
    if (Invoke-Dispatch 'bump.yml') {
        $state[$tryKey] = Get-Now
        Write-Log "触发 bump：$label $ver"
    }
}

# ---- VS Code ----
$vscodeVer = $null
try {
    $j = Invoke-RestMethod -Uri $VscodeProbe -Headers @{ 'User-Agent' = 'winget-poll/1.0' } -TimeoutSec 60
    $vscodeVer = $j.productVersion
} catch { Write-Log "VS Code 探测失败，本轮不处理它：$($_.Exception.Message)" }
Resolve-Version 'VS Code' $vscodeVer $VscodeDir $VscodeId 'VSCODE_OK' 'VSCODE_TRY'

# ---- DeepSeek Harness ----
# 不能用 /releases/latest：上游是 prerelease（dsh-v0.2.2-rc.5），那个接口会 404。
$dshVer = $null
try {
    $rels = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$DshRepo/releases?per_page=10" -Headers $h -TimeoutSec 60)
    if ($DshPrerelease -ne 1) { $rels = @($rels | Where-Object { -not $_.prerelease }) }
    $rels = @($rels | Where-Object { -not $_.draft })
    $newest = $rels | Sort-Object { $_.published_at } -Descending | Select-Object -First 1
    if ($newest) {
        $dshVer = $newest.tag_name
        if ($dshVer.StartsWith($DshPrefix)) { $dshVer = $dshVer.Substring($DshPrefix.Length) }
    }
} catch { Write-Log "DeepSeek release 查询失败，本轮不处理它：$($_.Exception.Message)" }
Resolve-Version 'DeepSeek' $dshVer $DshDir $DshId 'DSH_OK' 'DSH_TRY'

# ---- 定时 sync ----
$now = Get-Now
if (($now - $state.LAST_SYNC) -ge $SyncEvery) {
    if (Invoke-Dispatch 'sync-fork.yml') {
        Write-Log '触发 sync fork'
        $state.LAST_SYNC = $now
    }
}

@(
    "`$VSCODE_OK = '$($state.VSCODE_OK)'"
    "`$DSH_OK = '$($state.DSH_OK)'"
    "`$VSCODE_TRY = $($state.VSCODE_TRY)"
    "`$DSH_TRY = $($state.DSH_TRY)"
    "`$LAST_SYNC = $($state.LAST_SYNC)"
) | Set-Content -LiteralPath $stateFile -Encoding utf8

Write-Log "完成：vscode=$vscodeVer(ok=$($state.VSCODE_OK)) dsh=$dshVer(ok=$($state.DSH_OK))"
