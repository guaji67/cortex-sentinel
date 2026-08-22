#!/usr/bin/env bash
# Codex 派工线一眼汇总：babysitter 状态 + worktree + 未收分支 + rollout 活性。
# 用法:
#   scripts/codex_lines.sh              # 从主仓根目录跑，列出所有线
#   scripts/codex_lines.sh kill <slug>  # 仅按当前状态记录精确停止一条线（守护 + codex 进程组）
#   scripts/codex_lines.sh kill-all     # 清掉全部非终态线
# 输出解读:
#   state=running + rollout 在涨 = 正常干活, 等哨兵叫
#   state=done    = 收工, 先报 Falcon 再验收合并
#   state=help    = 守护救不活, 读 logs/codex-<slug>.log 定位(额度断供最常见)
#   state=stale?  = status 超 5 分钟没更新且非终态, babysitter 本体可能挂了, 按 runbook 接管
#   孤儿分支/worktree = 没人收的线, 找派工窗口或按 runbook merge/abandon

set -euo pipefail
STATUS_ROOT="${CORTEX_SENTINEL_HOME:-$HOME/.cortex-sentinel}/status"
mkdir -p "$STATUS_ROOT"

now=$(date +%s)
found=0

json_get() {
  local file="$1" key="$2"
  python3 - "$file" "$key" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
value = payload.get(sys.argv[2])
print("" if value is None else value)
PY
}

mark_killed() {
  local file="$1" slug="$2"
  mkdir -p "$(dirname "$file")"
  python3 - "$file" "$slug" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
slug = sys.argv[2]
payload = {}
if path.exists():
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        payload = {}
payload["slug"] = payload.get("slug") or slug
payload["state"] = "killed"
payload["killed_at"] = datetime.now(timezone.utc).isoformat()
payload["updated_at"] = payload["killed_at"]
path.write_text(json.dumps(payload, ensure_ascii=False, indent=1, sort_keys=True), encoding="utf-8")
PY
}

short_path() {
  local value="${1:-}"
  [ -n "$value" ] || { echo "-"; return; }
  case "$value" in
    "$PWD") echo ".";;
    "$PWD"/*) echo ".${value#$PWD}";;
    "$HOME"/*) echo "~${value#$HOME}";;
    "$HOME"/*-worktrees/*) echo ".../worktrees/${value##*/}";;
    *) echo "$value";;
  esac
}

kill_process_group() {
  local pid="$1" label="$2"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  local self_pgid pgid sid signal_group=0
  self_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' || true)
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  sid=$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  if [ "$pgid" = "$pid" ] && [ "$sid" = "$pid" ] && [ "$pgid" != "$self_pgid" ]; then
    signal_group=1
    kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
  local i
  for i in {1..20}; do
    kill -0 "$pid" 2>/dev/null || { echo "  killed $label pid=$pid pgid=${pgid:-?} signal=TERM"; return 0; }
    sleep 0.1
  done
  if [ "$signal_group" = 1 ]; then
    kill -KILL -- "-$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  else
    kill -KILL "$pid" 2>/dev/null || true
  fi
  echo "  killed $label pid=$pid pgid=${pgid:-?} signal=KILL"
}

pid_start_identity() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}'
}

pid_matches_status_identity() {
  local pid="$1" expected_started="$2" actual_started
  [[ "$pid" =~ ^[0-9]+$ && -n "$expected_started" ]] || return 1
  actual_started="$(pid_start_identity "$pid" || true)"
  [[ -n "$actual_started" && "$actual_started" == "$expected_started" ]]
}

is_recorded_babysitter() {
  local pid="$1" started="$2" slug="$3" command
  pid_matches_status_identity "$pid" "$started" || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ ( "$command" == *"scripts/codex_babysitter.py"* || "$command" == *"cortex_sentinel.dispatch.codex"* || "$command" == *"dispatch/codex.py"* ) && "$command" == *"--slug $slug"* ]]
}

is_recorded_codex_root() {
  local pid="$1" started="$2" command
  pid_matches_status_identity "$pid" "$started" || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in
    *codex-darwin-arm64*|*"/codex exec"*|*" codex exec "*|*"/codex "*|codex\ *) return 0 ;;
    *) return 1 ;;
  esac
}

status_file_for_slug() {
  echo "$STATUS_ROOT/codex-babysitter-$1.status.json"
}

cmd_kill() {
  local slug="${1:-}"
  [ -n "$slug" ] || { echo "ERROR: 缺 slug。用法: $0 kill <slug>" >&2; exit 1; }
  [[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: slug 只允许小写字母/数字/连字符: $slug" >&2; exit 1; }
  local status babysitter_pid babysitter_started codex_pid codex_started stopped=0
  status=$(status_file_for_slug "$slug")
  echo "== kill $slug =="

  echo "- babysitter:"
  babysitter_pid=$(json_get "$status" "babysitter_pid")
  babysitter_started=$(json_get "$status" "babysitter_started")
  if is_recorded_babysitter "$babysitter_pid" "$babysitter_started" "$slug"; then
    kill_process_group "$babysitter_pid" "babysitter"
    stopped=1
  elif [ -n "$babysitter_pid" ]; then
    echo "  skip pid $babysitter_pid: 不匹配已记录的 babysitter 身份（疑似 PID 复用或旧状态）"
  else
    echo "  none (旧状态没有可验证的 babysitter PID)"
  fi

  echo "- codex process group:"
  codex_pid=$(json_get "$status" "codex_pid")
  codex_started=$(json_get "$status" "codex_started")
  if is_recorded_codex_root "$codex_pid" "$codex_started"; then
    kill_process_group "$codex_pid" "codex-root"
    stopped=1
  elif [ -n "$codex_pid" ]; then
    echo "  skip pid $codex_pid: 不匹配已记录的 Codex 身份（疑似 PID 复用或旧状态）"
  else
    echo "  none (旧状态没有可验证的 Codex PID)"
  fi

  if [ "$stopped" = 1 ]; then
    mark_killed "$status" "$slug"
    echo "DONE: $slug status=killed ($status)"
  else
    echo "STOPPED: 没有可验证的本线进程，状态文件保持不变。"
    return 0
  fi
}

cmd_kill_all() {
  local killed_any=0 slug state f
  for f in "$STATUS_ROOT"/codex-babysitter-*.status.json; do
    [ -e "$f" ] || continue
    slug=$(basename "$f" .status.json); slug=${slug#codex-babysitter-}
    state=$(json_get "$f" "state")
    case "$state" in
      done|killed) continue;;
    esac
    killed_any=1
    cmd_kill "$slug"
  done
  [ "$killed_any" = 1 ] || echo "  (无非终态 babysitter 线)"
}

case "${1:-}" in
  kill)
    shift
    cmd_kill "$@"
    exit 0
    ;;
  kill-all)
    shift
    cmd_kill_all "$@"
    exit 0
    ;;
esac

echo "== babysitter 线 =="
for f in "$STATUS_ROOT"/codex-babysitter-*.status.json; do
  [ -e "$f" ] || continue
  found=1
  slug=$(basename "$f" .status.json); slug=${slug#codex-babysitter-}
  IFS=$'\037' read -r state restarts rollout workdir_raw started_at prompt_file_raw worklog_hint < <(python3 - "$f" <<'PY' 2>/dev/null || printf 'unreadable\037?\037\037\037?\037\037\n'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
fields = [
    payload.get("state", "?"),
    payload.get("restarts", 0),
    payload.get("rollout") or "",
    payload.get("workdir") or "",
    payload.get("started_at") or "?",
    payload.get("prompt_file") or "",
    payload.get("worklog_hint") or "",
]
print("\x1f".join(str(item) for item in fields))
PY
)
  workdir=$(short_path "$workdir_raw")
  prompt_file=$(short_path "$prompt_file_raw")
  status_age=$(( now - $(stat -f %m "$f") ))
  flag=""
  if [ "$state" = "running" ] && [ "$status_age" -gt 300 ]; then flag=" <-- status ${status_age}s 没更新, babysitter 可能挂了"; fi
  roll_info="no-rollout"
  if [ -n "$rollout" ] && [ -e "$rollout" ]; then
    roll_age=$(( now - $(stat -f %m "$rollout") ))
    roll_lines=$(wc -l < "$rollout" | tr -d ' ')
    roll_info="rollout ${roll_lines}行/${roll_age}s前有写"
  fi
  echo "  $slug: state=$state restarts=$restarts workdir=$workdir started_at=${started_at:-?} $roll_info (status ${status_age}s 前更新)$flag"
  echo "    prompt=$prompt_file worklog=${worklog_hint:-null}"
done
[ "$found" = 1 ] || echo "  (无 babysitter 状态文件)"

echo "== 活跃 worktree =="
git worktree list | tail -n +2 | sed 's/^/  /' || true
[ "$(git worktree list | wc -l)" -gt 1 ] || echo "  (无)"

echo "== 未收回的 codex/* 分支 =="
branches=$(git branch --list 'codex/*' --format='%(refname:short) %(committerdate:relative)' || true)
if [ -n "$branches" ]; then echo "$branches" | sed 's/^/  /'; else echo "  (无)"; fi
