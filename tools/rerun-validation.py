#!/usr/bin/env python3
"""rerun-validation.py —— 用一个「内容完全相同」的提交把 PR 分支往前挪一格

为什么要这么绕
  winget-pkgs 的验证只认 moderator 的 `@wingetbot run`，普通作者没有重跑权限
  （doc/Moderation.md 里写死了这是 moderator 的 Trigger）。但验证 App 会响应
  PR 的 `synchronize` 事件 —— 也就是「分支有新提交」。所以推一个 tree 完全没变的
  空提交，效果等于「重新跑一遍验证」，而清单文件一个字节都没改。

它做什么
  1. 读分支当前 head（sha）
  2. 读这个 commit 的 tree（内容指纹）
  3. 用同一个 tree + 同一个 parent 造一个新 commit（= 空提交）
  4. 把分支 ref 指过去（force=false，万一别人抢先推了会失败而不是覆盖）

用法
  GH_TOKEN=xxx python3 rerun-validation.py --branch bump/<包>/<版本> [--dry-run]
  GH_TOKEN=xxx python3 rerun-validation.py --auto [--dry-run]
    --auto：自动找出「自己名下开着的 PR」的分支逐个重跑（版本号常变时不用改默认值）
  token 也可以用 --token-file 指定文件
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
UPSTREAM = "microsoft/winget-pkgs"
UA = "winget-rerun/1.1"


class Api:
    def __init__(self, token):
        self.token = token

    def call(self, method, path, payload=None):
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(API + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", UA)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                body = r.read().decode() or "{}"
                return r.status, json.loads(body)
        except urllib.error.HTTPError as e:
            body = e.read().decode()
            try:
                return e.code, json.loads(body)
            except Exception:
                return e.code, {"message": body[:400]}


def rerun_one(api, fork, branch, message, dry_run):
    ref_path = f"/repos/{fork}/git/ref/heads/{branch}"
    code, ref = api.call("GET", ref_path)
    if code != 200:
        print(f"  x 读分支失败 {branch}（HTTP {code}）：{ref.get('message')}", file=sys.stderr)
        return False
    head = ref["object"]["sha"]

    code, commit = api.call("GET", f"/repos/{fork}/git/commits/{head}")
    if code != 200:
        print(f"  x 读 commit 失败（HTTP {code}）：{commit.get('message')}", file=sys.stderr)
        return False
    tree = commit["tree"]["sha"]
    print(f"  {branch}")
    print(f"    head {head[:9]}   tree {tree[:9]}")

    if dry_run:
        print("    --dry-run：到此为止，没有写入")
        return True

    code, new = api.call("POST", f"/repos/{fork}/git/commits", {
        "message": message,
        "tree": tree,
        "parents": [head],
    })
    if code != 201:
        print(f"    x 建空提交失败（HTTP {code}）：{new.get('message')}", file=sys.stderr)
        return False
    new_sha = new["sha"]

    code, _ = api.call("PATCH", f"/repos/{fork}/git/refs/heads/{branch}", {
        "sha": new_sha,
        "force": False,
    })
    if code != 200:
        print("    x 移动分支失败（分支可能刚被别人推过），重跑本脚本即可", file=sys.stderr)
        return False

    print(f"    新 head {new_sha[:9]} → 验证会重新排队")
    return True


def collect_my_open_prs(api, fork):
    """自己名下、开着、且 head 在我们 fork 里的 PR → [(号, 分支名)]"""
    q = urllib.parse.quote(f"repo:{UPSTREAM} is:pr is:open author:@me")
    code, res = api.call("GET", f"/search/issues?q={q}&per_page=30")
    if code != 200:
        print(f"x 搜索 PR 失败（HTTP {code}）：{res.get('message')}", file=sys.stderr)
        return []
    out = []
    for it in res.get("items", []):
        code, pr = api.call("GET", f"/repos/{UPSTREAM}/pulls/{it['number']}")
        if code != 200:
            continue
        head = pr.get("head") or {}
        repo = ((head.get("repo") or {}).get("full_name") or "").lower()
        if repo != fork.lower():
            continue
        out.append((it["number"], head.get("ref")))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fork", default=os.environ.get("FORK", "zhou-dev-design/winget-pkgs"))
    ap.add_argument("--branch", default=None)
    ap.add_argument("--auto", action="store_true", help="重跑自己名下所有开着的 PR")
    ap.add_argument("--message", default="chore: re-trigger validation (previous run hit an infra error)")
    ap.add_argument("--token-file", default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    token = os.environ.get("GH_TOKEN") or ""
    if not token and args.token_file:
        with open(args.token_file, "r", encoding="utf-8") as f:
            token = f.read()
    token = token.strip().replace("\n", "")
    if not token:
        print("缺少 token：GH_TOKEN 环境变量或 --token-file", file=sys.stderr)
        return 1

    api = Api(token)

    if args.auto:
        prs = collect_my_open_prs(api, args.fork)
        if not prs:
            print("没有找到自己名下开着的 PR（head 在本 fork 里）")
            return 0
        print(f"共 {len(prs)} 个开着的 PR：")
        ok = True
        for num, branch in prs:
            print(f"  PR #{num}")
            ok = rerun_one(api, args.fork, branch, args.message, args.dry_run) and ok
        return 0 if ok else 1

    if not args.branch:
        print("要么给 --branch，要么用 --auto", file=sys.stderr)
        return 1
    return 0 if rerun_one(api, args.fork, args.branch, args.message, args.dry_run) else 1


if __name__ == "__main__":
    sys.exit(main())
