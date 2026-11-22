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
  GH_TOKEN 也可以写成环境变量，或用 --token-file 指定文件
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
UA = "winget-rerun/1.0"


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fork", default=os.environ.get("FORK", "zhou-dev-design/winget-pkgs"))
    ap.add_argument("--branch", required=True)
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
    ref_path = f"/repos/{args.fork}/git/ref/heads/{args.branch}"

    code, ref = api.call("GET", ref_path)
    if code != 200:
        print(f"读分支失败 {args.branch}（HTTP {code}）：{ref.get('message')}", file=sys.stderr)
        return 1
    head = ref["object"]["sha"]
    print(f"当前 head  {head[:9]}  ({args.branch})")

    code, commit = api.call("GET", f"/repos/{args.fork}/git/commits/{head}")
    if code != 200:
        print(f"读 commit 失败（HTTP {code}）：{commit.get('message')}", file=sys.stderr)
        return 1
    tree = commit["tree"]["sha"]
    print(f"内容指纹    {tree[:9]}  （新提交会复用这一份，所以文件不变）")

    if args.dry_run:
        print("--dry-run：到此为止，没有写入任何东西")
        return 0

    code, new = api.call("POST", f"/repos/{args.fork}/git/commits", {
        "message": args.message,
        "tree": tree,
        "parents": [head],
    })
    if code != 201:
        print(f"建空提交失败（HTTP {code}）：{new.get('message')}", file=sys.stderr)
        return 1
    new_sha = new["sha"]
    print(f"新提交      {new_sha[:9]}")

    code, _ = api.call("PATCH", f"/repos/{args.fork}/git/refs/heads/{args.branch}", {
        "sha": new_sha,
        "force": False,
    })
    if code != 200:
        print(f"移动分支失败（HTTP {code}）——分支可能刚被别人推过，重跑本脚本即可", file=sys.stderr)
        return 1

    print("分支已前移，PR 会收到 synchronize 事件 → 验证重新排队")
    return 0


if __name__ == "__main__":
    sys.exit(main())
