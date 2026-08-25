#!/bin/bash
# Cortex 哨兵的精确状态/重启入口。
# 只操作已登记的 launchd label，不按进程名批量清理。

set -euo pipefail

service_label="com.cortex.sentinelbar"
app_executable="/Applications/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar"
uid="$(id -u)"
target="gui/${uid}/${service_label}"

usage() {
  cat <<'EOF'
用法：
  bash scripts/sentinel-ctl.sh status
  bash scripts/sentinel-ctl.sh restart

也可以双击“重启 Cortex 哨兵.command”。
EOF
}

launchctl_pid() {
  launchctl print "$target" 2>/dev/null \
    | awk '/^[[:space:]]*pid = / { print $3; exit }'
}

print_status() {
  local pid
  pid="$(launchctl_pid || true)"
  if [ -z "$pid" ]; then
    echo "状态：未运行（label=${service_label}）"
    launchctl print "$target" 2>&1 | sed -n '1,24p' || true
    return 1
  fi

  echo "状态：运行中"
  ps -p "$pid" -o pid,ppid,state,lstart,etime,%cpu,%mem,command
  echo "launchd：$target"
}

restart() {
  local before_pid after_pid command
  before_pid="$(launchctl_pid || true)"
  if [ -z "$before_pid" ]; then
    echo "失败：${target} 未加载，先运行安装器恢复 launchd 托管。" >&2
    exit 1
  fi

  echo "重启：${service_label}（旧 pid=${before_pid}）"
  launchctl kickstart -k "$target"

  after_pid=""
  command=""
  for _ in {1..40}; do
    after_pid="$(launchctl_pid || true)"
    command="$(ps -p "$after_pid" -o command= 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    # kickstart 先返回 launchd 的 xpcproxy trampoline；要等真实 app
    # exec 完再验收，不能把 trampoline 当成重启成功。
    if [ -n "$after_pid" ] && [ "$after_pid" != "$before_pid" ] \
      && [ "$command" = "$app_executable" ]; then
      break
    fi
    sleep 0.25
  done
  if [ -z "$after_pid" ] || [ "$after_pid" = "$before_pid" ] || [ "$command" != "$app_executable" ]; then
    echo "失败：重启后没有拿到真实 app pid（旧=${before_pid}，新=${after_pid:-无}，command=${command:-无}）。" >&2
    exit 1
  fi

  echo "已重启：新 pid=${after_pid}"
  ps -p "$after_pid" -o pid,ppid,state,lstart,etime,%cpu,%mem,command
}

case "${1:-}" in
  status)
    print_status
    ;;
  restart)
    restart
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
