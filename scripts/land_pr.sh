#!/usr/bin/env bash
# 哨兵仓合入入口：绑定验过的头，不直推 main，不跳过已存在的检查。
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
exec python3 "$root/scripts/land_pr.py" "$@"
