#!/bin/sh
# winget-poll.sh —— 外部轮询器：只在新版本出现时才触发 GitHub Actions
#
# 为什么需要它
#   GitHub 不允许把 webhook 装到别人的仓库上，所以「VS Code / DeepSeek 发新版」
#   没法直接变成我们 workflow 的触发事件。唯一可行的形态是
#   「某处定时轮询 → 发现版本变了才 dispatch」。又因为本账号在 GitHub Actions
#   里的 cron 一直不触发（见 README「为什么不用 GitHub 自己的 schedule」），
#   轮询放在一台常开的机器上（飞牛 NAS / 任意 Linux）。
#
# 每 15 分钟做什么
#   1. 查 VS Code 稳定版版本号（官方 update API，1 次请求）
#   2. 查 DeepSeek Harness 最新 release（含 prerelease，与 bump 脚本口径一致）
#   3. 若「仓库里还没有该版本」且「bump 分支也还不存在」→ dispatch bump 工作流
#   4. 距上次 sync 超过 1 小时 → dispatch sync 工作流
#   正常情况下零 dispatch；有新版才动。
#
# 为什么还要查 bump 分支
#   PR 从提出到合并可能好几天，这期间「仓库里没有该版本」一直成立。
#   只看清单会每小时白触发一次；bump 分支已存在就说明这活已经在流程里了。
#
# 依赖：curl、sed、sort、date。不需要 jq / python。
#
# 环境变量（都有默认值）
#   REPO=zhou-dev-design/winget-bump-ci   调度仓库
#   FORK=zhou-dev-design/winget-pkgs      被写入的 fork
#   REF=main                              调度仓库的分支
#   STATE_DIR=/opt/winget-poll            状态与 token 所在目录
#   TOKEN_FILE=$STATE_DIR/token           token 文件（权限 600）
#   SYNC_EVERY=3600                       sync 触发间隔（秒）
#   REDISPATCH_AFTER=3600                 同一版本未落地时，重试间隔（秒）
#   DSH_PRERELEASE=1                      DeepSeek 是否把 prerelease 算作新版（1=算，0=只认正式版）
#
# 退出码：0 正常（含"无事可做"）；1 配置/网络错误

set -eu

REPO=${REPO:-zhou-dev-design/winget-bump-ci}
FORK=${FORK:-zhou-dev-design/winget-pkgs}
REF=${REF:-main}
STATE_DIR=${STATE_DIR:-/opt/winget-poll}
TOKEN_FILE=${TOKEN_FILE:-$STATE_DIR/token}
STATE_FILE=$STATE_DIR/state
SYNC_EVERY=${SYNC_EVERY:-3600}
REDISPATCH_AFTER=${REDISPATCH_AFTER:-3600}
DSH_PRERELEASE=${DSH_PRERELEASE:-1}

VSCODE_PROBE='https://update.code.visualstudio.com/api/update/win32-x64-user/stable/latest'
VSCODE_DIR='manifests/m/Microsoft/VisualStudioCode'
VSCODE_ID='Microsoft.VisualStudioCode'
DSH_REPO='deepseek-ai/deepseek-harness'
DSH_TAG_PREFIX='dsh-v'
DSH_DIR='manifests/d/DeepSeek/DeepSeekHarnessDesktop'
DSH_ID='DeepSeek.DeepSeekHarnessDesktop'

UA='winget-poll/1.0'
TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP" "$TMP.body" 2>/dev/null || true' EXIT

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "错误：$*"; exit 1; }

command -v curl >/dev/null 2>&1 || die '缺少 curl'

[ -r "$TOKEN_FILE" ] || die "读不到 token 文件：$TOKEN_FILE（内容为 classic PAT，权限 chmod 600）"
TOKEN=$(tr -d ' \t\r\n' < "$TOKEN_FILE")
[ -n "$TOKEN" ] || die 'token 文件是空的'

mkdir -p "$STATE_DIR"
# 状态文件必须先存在：POSIX 规定 `.` 读不到文件时非交互 shell 直接退出（dash 就是这么干的，
# `|| true` 拦不住），首次运行会静默 exit 1，一个字节日志都没有。
[ -f "$STATE_FILE" ] || : > "$STATE_FILE"
# shellcheck disable=SC1090
. "$STATE_FILE"
: "${VSCODE_OK:=}" "${DSH_OK:=}" "${VSCODE_TRY:=0}" "${DSH_TRY:=0}" "${LAST_SYNC:=0}"

# ---- GitHub API：body 落到 $TMP.body，回显 HTTP 状态码 ----
api() { # api METHOD PATH [JSON]
  _m=$1; _p=$2; _d=${3:-}
  if [ -n "$_d" ]; then
    _raw=$(curl -sS --max-time 60 -X "$_m" \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H "User-Agent: $UA" -H 'Content-Type: application/json' \
      -d "$_d" -w '\n%{http_code}' "https://api.github.com$_p") || { echo 000; return 0; }
  else
    _raw=$(curl -sS --max-time 60 -X "$_m" \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -H "User-Agent: $UA" \
      -w '\n%{http_code}' "https://api.github.com$_p") || { echo 000; return 0; }
  fi
  echo "$_raw" | sed '$d' > "$TMP.body"
  echo "$_raw" | tail -n1
}

dispatch() { # dispatch <workflow-file>
  _c=$(api POST "/repos/$REPO/actions/workflows/$1/dispatches" "{\"ref\":\"$REF\"}")
  [ "$_c" = 204 ] || { log "dispatch $1 失败（HTTP $_c）$(head -c 160 "$TMP.body")"; return 1; }
  return 0
}

manifest_exists() { [ "$(api GET "/repos/$FORK/contents/$1")" = 200 ]; }
branch_exists()   { [ "$(api GET "/repos/$FORK/git/ref/heads/$1")" = 200 ]; }

save_state() {
  {
    echo "VSCODE_OK=$VSCODE_OK"
    echo "DSH_OK=$DSH_OK"
    echo "VSCODE_TRY=$VSCODE_TRY"
    echo "DSH_TRY=$DSH_TRY"
    echo "LAST_SYNC=$LAST_SYNC"
  } > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# ---- 1. VS Code ----
# 家宽/跨境网络下偶发连不上，重试 3 次再认输（一次失败就整天不检测太脆）
vscode_ver=''
_j=''
_i=1
while [ "$_i" -le 3 ]; do
  if _j=$(curl -sS --max-time 30 -H "User-Agent: $UA" "$VSCODE_PROBE" 2>/dev/null) && [ -n "$_j" ]; then
    break
  fi
  _j=''
  _i=$((_i + 1))
  if [ "$_i" -le 3 ]; then sleep 5; fi
done
if [ -n "$_j" ]; then
  vscode_ver=$(printf '%s' "$_j" | sed -n 's/.*"productVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

if [ -z "$vscode_ver" ]; then
  log 'VS Code 探测失败，本轮不处理它'
elif [ "$vscode_ver" != "$VSCODE_OK" ]; then
  if manifest_exists "$VSCODE_DIR/$vscode_ver"; then
    VSCODE_OK=$vscode_ver
    log "VS Code $vscode_ver 已在仓库里，记为已落地"
  elif branch_exists "bump/$VSCODE_ID/$vscode_ver"; then
    VSCODE_OK=$vscode_ver
    log "VS Code $vscode_ver 的 bump 分支已存在（PR 在流程里），记为已落地"
  elif [ $(( $(date +%s) - VSCODE_TRY )) -ge "$REDISPATCH_AFTER" ]; then
    if dispatch bump.yml; then
      VSCODE_TRY=$(date +%s)
      log "触发 bump：VS Code $vscode_ver"
    fi
  else
    log "VS Code $vscode_ver 待落地，距上次触发不足 $((REDISPATCH_AFTER / 60)) 分钟，本轮不重复触发"
  fi
fi

# ---- 2. DeepSeek Harness ----
# 上游用 prerelease 发版（dsh-v0.2.2-rc.5 这种），所以不能用 /releases/latest，
# 必须拉列表自己挑：跳过 draft，按 published_at 倒序取最新。
dsh_ver=''
_c=$(api GET "/repos/$DSH_REPO/releases?per_page=10")
if [ "$_c" = 200 ]; then
  dsh_tag=$(
    sed 's/},[[:space:]]*{/}\n{/g' "$TMP.body" | while IFS= read -r obj; do
      case "$obj" in *'"draft":true'*) continue ;; esac
      if [ "$DSH_PRERELEASE" != 1 ]; then
        case "$obj" in *'"prerelease":true'*) continue ;; esac
      fi
      _tag=$(printf '%s' "$obj" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')
      _pub=$(printf '%s' "$obj" | sed -n 's/.*"published_at":[[:space:]]*"\([^"]*\)".*/\1/p')
      if [ -n "$_tag" ]; then printf '%s %s\n' "${_pub:-0000}" "$_tag"; fi
    done | sort -r | head -n1 | awk '{print $2}'
  )
  case "$dsh_tag" in
    "$DSH_TAG_PREFIX"*) dsh_ver=${dsh_tag#"$DSH_TAG_PREFIX"} ;;
    '') ;;
    *) dsh_ver=$dsh_tag ;;
  esac
else
  log "DeepSeek release 查询失败（HTTP $_c），本轮不处理它"
fi

if [ -z "$dsh_ver" ]; then
  if [ "$_c" = 200 ]; then log 'DeepSeek 没解析到版本号，本轮不处理它'; fi
elif [ "$dsh_ver" != "$DSH_OK" ]; then
  if manifest_exists "$DSH_DIR/$dsh_ver"; then
    DSH_OK=$dsh_ver
    log "DeepSeek $dsh_ver 已在仓库里，记为已落地"
  elif branch_exists "bump/$DSH_ID/$dsh_ver"; then
    DSH_OK=$dsh_ver
    log "DeepSeek $dsh_ver 的 bump 分支已存在（PR 在流程里），记为已落地"
  elif [ $(( $(date +%s) - DSH_TRY )) -ge "$REDISPATCH_AFTER" ]; then
    if dispatch bump.yml; then
      DSH_TRY=$(date +%s)
      log "触发 bump：DeepSeek $dsh_ver"
    fi
  else
    log "DeepSeek $dsh_ver 待落地，距上次触发不足 $((REDISPATCH_AFTER / 60)) 分钟，本轮不重复触发"
  fi
fi

# ---- 3. 定时 sync fork ----
_now=$(date +%s)
if [ $(( _now - LAST_SYNC )) -ge "$SYNC_EVERY" ]; then
  if dispatch sync-fork.yml; then
    LAST_SYNC=$_now
    log '触发 sync fork'
  fi
fi

save_state
log "完成：vscode=$vscode_ver(ok=$VSCODE_OK) dsh=$dsh_ver(ok=$DSH_OK)"
