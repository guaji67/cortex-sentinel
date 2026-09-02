#!/bin/bash
# 卸载正式哨兵，并清理历史开发构建登录项；不扫描或批量停止其他程序。

set -euo pipefail

SENTINEL_LOGIN_ITEM_LIB=1
# 与 install-app.sh 共用名字+路径双判，避免 whose path is 对中文路径失效。
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-app.sh"
skip_login_item_cleanup=0

app_dest="/Applications/Cortex哨兵.app"
app_executable="$app_dest/Contents/MacOS/CortexSentinelBar"
service_label="com.cortex.sentinelbar"
plist="$HOME/Library/LaunchAgents/$service_label.plist"
restart_command_dest="/Applications/重启 Cortex 哨兵.command"
uid="$(id -u)"

if [ "${1:-}" = "--dry-run" ]; then
  echo "registration_route=none (uninstall)"
  echo "historical_login_item_cleanup=delete login items whose name is Cortex哨兵/CortexSentinelBar or whose NFC path equals /Applications/Cortex哨兵.app"
  echo "remove_paths=$app_dest,$plist,$restart_command_dest"
  echo "cleanup_scope=uninstall script only; no current machine state changed"
  exit 0
fi

remove_exact_executable() {
  local pids
  pids="$(ps -axo pid=,command= | awk -v executable="$1" '{ pid=$1; $1=""; sub(/^[[:space:]]+/, ""); if ($0 == executable) print pid }')"
  [ -n "$pids" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill -TERM "$pid"
  done <<< "$pids"
}

launchctl bootout "gui/$uid/$service_label" 2>/dev/null || true
remove_login_item_for_path "$app_dest"
remove_exact_executable "$app_executable"
rm -f "$plist" "$restart_command_dest"
rm -rf "$app_dest"
echo "Cortex 哨兵已卸载；LaunchAgent 与旧登录项（名字+路径双判）清理步骤已执行。"
