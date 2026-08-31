#!/bin/bash
# 卸载正式哨兵，并清理历史开发构建登录项；不扫描或批量停止其他程序。

set -euo pipefail

app_dest="/Applications/Cortex哨兵.app"
app_executable="$app_dest/Contents/MacOS/CortexSentinelBar"
service_label="com.cortex.sentinelbar"
plist="$HOME/Library/LaunchAgents/$service_label.plist"
restart_command_dest="/Applications/重启 Cortex 哨兵.command"
uid="$(id -u)"

if [ "${1:-}" = "--dry-run" ]; then
  echo "registration_route=none (uninstall)"
  echo "historical_login_item_cleanup=delete login items whose path contains /.build/ and CortexSentinelBar.app"
  echo "remove_paths=$app_dest,$plist,$restart_command_dest"
  echo "cleanup_scope=uninstall script only; no current machine state changed"
  exit 0
fi

remove_historical_build_login_items() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  repeat with staleItem in every login item
    try
      set candidatePath to POSIX path of (staleItem as alias)
      if candidatePath contains "/.build/" and candidatePath contains "CortexSentinelBar.app" then
        delete staleItem
        log "deleted CortexSentinelBar build login item: " & candidatePath
      end if
    end try
  end repeat
end tell
APPLESCRIPT
}

remove_exact_executable() {
  local pids
  pids="$(ps -axo pid=,command= | awk -v executable="$1" '{ pid=$1; $1=""; sub(/^[[:space:]]+/, ""); if ($0 == executable) print pid }')"
  [ -n "$pids" ] || return 0
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill -TERM "$pid"
  done <<< "$pids"
}

launchctl bootout "gui/$uid/$service_label" 2>/dev/null || true
remove_historical_build_login_items
remove_exact_executable "$app_executable"
rm -f "$plist" "$restart_command_dest"
rm -rf "$app_dest"
echo "Cortex 哨兵已卸载；LaunchAgent 与历史 .build 登录项清理步骤已执行。"
