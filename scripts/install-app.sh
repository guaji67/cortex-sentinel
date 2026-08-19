#!/bin/bash
# 构建、安装并托管唯一一份 Cortex 哨兵。更新和换机修复都走这个脚本。

set -euo pipefail

# ps 在 C locale 会把中文路径打成 M- 转义，按绝对路径对 pid 会对不上。
if [ -z "${LC_ALL:-}" ] || [ "${LC_ALL}" = "C" ]; then
  export LC_ALL=en_US.UTF-8
fi
if [ -z "${LANG:-}" ] || [ "${LANG}" = "C" ]; then
  export LANG=en_US.UTF-8
fi

package_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dest="/Applications/Cortex哨兵.app"
app_executable="$app_dest/Contents/MacOS/CortexSentinelBar"
service_label="com.cortex.sentinelbar"
plist="$HOME/Library/LaunchAgents/$service_label.plist"
uid="$(id -u)"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
app_source=""
cortex_repo_root="${CORTEX_REPO_ROOT:-}"
watch_dir="${CORTEX_SENTINEL_WATCH_DIR:-}"
watch_dir_explicit=0
default_watch_dir="$HOME/.cortex-sentinel/logs"
detected_cortex_logs="$HOME/Documents/Code/cortex/logs"
if [ -n "$watch_dir" ]; then
  watch_dir_explicit=1
fi
skip_login_item_cleanup=0
print_watch_plan=0
used_fallback_watch=0
if [ -n "${SSH_CONNECTION:-}" ]; then
  skip_login_item_cleanup=1
fi

usage() {
  cat <<'EOF'
用法：
  bash scripts/install-app.sh
  bash scripts/install-app.sh --app-source /path/to/Cortex哨兵.app
  bash scripts/install-app.sh --app-source /path/to/Cortex哨兵.app --cortex-root /path/to/cortex
  bash scripts/install-app.sh --app-source /path/to/Cortex哨兵.app --skip-login-item-cleanup

监视目录（写入 launchd）：
  CORTEX_SENTINEL_WATCH_DIR   优先，直接指向日志目录
  CORTEX_REPO_ROOT / --cortex-root   兼容旧装法，读取 <root>/logs（目录必须存在）
  自动找到 ~/Documents/Code/cortex/logs 则用它
  都没有时创建并使用 ~/.cortex-sentinel/logs；此时不往 LaunchAgent 写 CORTEX_REPO_ROOT
  给了无效的 CORTEX_REPO_ROOT 不会失败，按上面顺序继续往下落

不传 --app-source 时从当前源码构建；DMG 分发使用预构建 app，不依赖目标机 Swift/Xcode。
SSH/headless 环境会自动跳过可能阻塞的 System Events 查询；旧 app 仍会被归档，因此不会再次启动。
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-source)
      [ "$#" -ge 2 ] || { echo "--app-source 缺路径" >&2; exit 2; }
      app_source="$2"
      shift 2
      ;;
    --cortex-root)
      [ "$#" -ge 2 ] || { echo "--cortex-root 缺路径" >&2; exit 2; }
      cortex_repo_root="$2"
      shift 2
      ;;
    --skip-login-item-cleanup)
      skip_login_item_cleanup=1
      shift
      ;;
    --print-watch-plan)
      print_watch_plan=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$watch_dir" ]; then
  if [ -n "$cortex_repo_root" ] && [ -d "$cortex_repo_root/logs" ]; then
    watch_dir="$cortex_repo_root/logs"
  elif [ -d "$detected_cortex_logs" ]; then
    cortex_repo_root="$HOME/Documents/Code/cortex"
    watch_dir="$detected_cortex_logs"
    echo "检测到 Cortex 仓：$detected_cortex_logs"
  else
    cortex_repo_root=""
    watch_dir="$default_watch_dir"
    used_fallback_watch=1
  fi
fi

if [ -n "$cortex_repo_root" ] && [ ! -d "$cortex_repo_root" ]; then
  cortex_repo_root=""
fi

mkdir -p "$watch_dir"

if [ "$print_watch_plan" -eq 1 ]; then
  echo "watch_dir=$watch_dir"
  echo "cortex_repo_root=${cortex_repo_root}"
  echo "used_fallback_watch=$used_fallback_watch"
  if [ "$watch_dir_explicit" -eq 1 ]; then
    echo "launch_env=CORTEX_SENTINEL_WATCH_DIR=$watch_dir"
  elif [ -n "$cortex_repo_root" ] && [ -d "$cortex_repo_root" ]; then
    echo "launch_env=CORTEX_REPO_ROOT=$cortex_repo_root"
  else
    echo "launch_env="
  fi
  if [ "$used_fallback_watch" -eq 1 ]; then
    echo "没找到 Cortex 仓库，先盯 ~/.cortex-sentinel/logs。要换目录在设置里点「选择」。"
  fi
  exit 0
fi

trash_path_script=""
if [ -n "$cortex_repo_root" ] && [ -f "$cortex_repo_root/scripts/trash_path.sh" ]; then
  trash_path_script="$cortex_repo_root/scripts/trash_path.sh"
fi
trash_existing_path() {
  local path="$1"
  local label="$2"

  [ -e "$path" ] || return 0
  if [ -n "$trash_path_script" ]; then
    bash "$trash_path_script" "$path" "$label"
    return
  fi
  mkdir -p "$backup_dir/Replaced"
  mv "$path" "$backup_dir/Replaced/${label}-$(basename "$path")"
}

if [ -n "$app_source" ]; then
  [ -d "$app_source" ] || { echo "预构建 app 不存在：$app_source" >&2; exit 1; }
  app_source="$(cd "$(dirname "$app_source")" && pwd)/$(basename "$app_source")"
fi

legacy_app_paths=(
  "$package_dir/.build/CortexSentinelBar.app"
  "$HOME/Applications/CortexSentinelBar.app"
)
if [ -n "$cortex_repo_root" ]; then
  legacy_app_paths=(
    "$cortex_repo_root/tools/CortexSentinelBar/.build/CortexSentinelBar.app"
    "${legacy_app_paths[@]}"
  )
fi
package_build_app="$package_dir/.build/CortexSentinelBar.app"

pids_for_executable() {
  local executable="$1"
  ps -axo pid=,command= | awk -v executable="$executable" '
    {
      pid = $1
      $1 = ""
      sub(/^[[:space:]]+/, "")
      if ($0 == executable) print pid
    }
  '
}

stop_exact_executable() {
  local executable="$1"
  local pids
  local remaining
  local attempt

  pids="$(pids_for_executable "$executable")"
  [ -n "$pids" ] || return 0

  echo "停止旧实例：$executable (pid $(echo "$pids" | tr '\n' ' '))"
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill -TERM "$pid"
  done <<< "$pids"

  for attempt in {1..20}; do
    remaining="$(pids_for_executable "$executable")"
    [ -z "$remaining" ] && return 0
    sleep 0.25
  done

  echo "失败：旧实例未退出：$executable (pid $(echo "$remaining" | tr '\n' ' '))" >&2
  return 1
}

remove_login_item_for_path() {
  local app_path="$1"
  local removed

  if [ "$skip_login_item_cleanup" -eq 1 ]; then
    return 0
  fi

  removed="$(osascript - "$app_path" <<'APPLESCRIPT'
on run argv
  set targetPath to item 1 of argv
  tell application "System Events"
    set staleItems to every login item whose path is targetPath
    set removedCount to count of staleItems
    repeat with staleItem in staleItems
      delete staleItem
    end repeat
  end tell
  return removedCount
end run
APPLESCRIPT
)"

  if [ "$removed" -gt 0 ]; then
    echo "已删除旧登录项：$app_path ($removed 条)"
  fi
}

cleanup_legacy_app() {
  local app_path="$1"
  remove_login_item_for_path "$app_path"
  stop_exact_executable "$app_path/Contents/MacOS/CortexSentinelBar"
  "$lsregister" -u "$app_path" 2>/dev/null || true
}

archive_legacy_app() {
  local app_path="$1"
  local archive_name

  [ "$app_path" != "$package_build_app" ] || return 0
  [ -d "$app_path" ] || return 0

  if [ -n "$cortex_repo_root" ]; then
    case "$app_path" in
      "$cortex_repo_root"/*)
        archive_name="cortex-tools-CortexSentinelBar.app"
        ;;
      "$HOME/Applications"/*)
        archive_name="home-Applications-CortexSentinelBar.app"
        ;;
      *)
        echo "拒绝归档未登记路径：$app_path" >&2
        return 1
        ;;
    esac
  else
    case "$app_path" in
      "$HOME/Applications"/*)
        archive_name="home-Applications-CortexSentinelBar.app"
        ;;
      *)
        echo "拒绝归档未登记路径：$app_path" >&2
        return 1
        ;;
    esac
  fi

  mkdir -p "$backup_dir/LegacyApps"
  mv "$app_path" "$backup_dir/LegacyApps/$archive_name"
  echo "已归档旧 app：$app_path"
}

write_launch_agent() {
  local temporary_plist

  mkdir -p "$(dirname "$plist")"
  temporary_plist="$(mktemp "$HOME/Library/LaunchAgents/.$service_label.XXXXXX")"
  plutil -create xml1 "$temporary_plist"
  plutil -insert Label -string "$service_label" "$temporary_plist"
  plutil -insert ProgramArguments -array "$temporary_plist"
  plutil -insert ProgramArguments.0 -string "$app_executable" "$temporary_plist"
  plutil -insert RunAtLoad -bool true "$temporary_plist"
  plutil -insert KeepAlive -bool true "$temporary_plist"
  plutil -insert ProcessType -string Interactive "$temporary_plist"
  plutil -insert EnvironmentVariables -dictionary "$temporary_plist"
  if [ "$watch_dir_explicit" -eq 1 ]; then
    plutil -insert EnvironmentVariables.CORTEX_SENTINEL_WATCH_DIR -string "$watch_dir" "$temporary_plist"
  elif [ -n "$cortex_repo_root" ] && [ -d "$cortex_repo_root" ]; then
    plutil -insert EnvironmentVariables.CORTEX_REPO_ROOT -string "$cortex_repo_root" "$temporary_plist"
  fi
  chmod 0644 "$temporary_plist"
  mv "$temporary_plist" "$plist"
}

if [ ! -d "$watch_dir" ]; then
  echo "失败：监视目录不存在：$watch_dir" >&2
  echo "可设置 CORTEX_SENTINEL_WATCH_DIR 指向日志目录，或设置 CORTEX_REPO_ROOT 指向仓库根。" >&2
  exit 1
fi

echo "== 构建 =="
if [ -z "$app_source" ]; then
  bash "$package_dir/scripts/build-app.sh"
  app_source="$package_build_app"
else
  echo "使用预构建 app：$app_source"
fi
codesign --verify --deep --strict "$app_source"
if ! lipo -archs "$app_source/Contents/MacOS/CortexSentinelBar" | tr ' ' '\n' | grep -qx arm64; then
  echo "失败：预构建 app 不包含 arm64" >&2
  exit 1
fi

backup_dir="$HOME/Library/Application Support/Cortex/SentinelInstallBackups/$(date +%Y%m%d-%H%M%S)"
had_app=0
had_plist=0
mkdir -p "$backup_dir"
if [ -d "$app_dest" ]; then
  ditto "$app_dest" "$backup_dir/Cortex哨兵.app"
  had_app=1
fi
if [ -f "$plist" ]; then
  cp -p "$plist" "$backup_dir/$service_label.plist"
  had_plist=1
fi
echo "== 回滚备份：$backup_dir =="

rollback_on_error() {
  local status=$?
  [ "$status" -ne 0 ] || return 0

  echo "安装失败，正在恢复上一版（原退出码 ${status}）" >&2
  launchctl bootout "gui/$uid/$service_label" 2>/dev/null || true
  trash_existing_path "$app_dest" "sentinel-install-failed"
  if [ "$had_app" -eq 1 ]; then
    ditto "$backup_dir/Cortex哨兵.app" "$app_dest"
  fi
  if [ "$had_plist" -eq 1 ]; then
    cp -p "$backup_dir/$service_label.plist" "$plist"
  else
    trash_existing_path "$plist" "sentinel-plist-failed"
  fi
  if [ "$had_app" -eq 1 ] && [ "$had_plist" -eq 1 ]; then
    launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || true
  fi
  exit "$status"
}
trap rollback_on_error EXIT

echo "== 停止正式托管并清理迁移残留 =="
launchctl bootout "gui/$uid/$service_label" 2>/dev/null || true
sleep 2
for legacy_app_path in "${legacy_app_paths[@]}"; do
  cleanup_legacy_app "$legacy_app_path"
  archive_legacy_app "$legacy_app_path"
done
stop_exact_executable "$app_executable"

echo "== 安装正式 app =="
trash_existing_path "$app_dest" "sentinel-install-replaced"
ditto "$app_source" "$app_dest"
codesign --verify --deep --strict "$app_dest"
"$lsregister" -f "$app_dest"

echo "== 生成自启配置并重新托管 =="
write_launch_agent
launchctl bootstrap "gui/$uid" "$plist"
sleep 4

running_pids="$(pids_for_executable "$app_executable")"
running_count="$(printf '%s\n' "$running_pids" | awk 'NF { count++ } END { print count + 0 }')"
all_sentinel_count="$(ps -axo command= | awk '/\/Contents\/MacOS\/CortexSentinelBar$/ { count++ } END { print count + 0 }')"
if [ "$running_count" -ne 1 ] || [ "$all_sentinel_count" -ne 1 ]; then
  echo "失败：期望 1 个正式实例，实际正式=${running_count}，全部=${all_sentinel_count}" >&2
  exit 1
fi
echo "== 已运行唯一正式实例 pid=$running_pids =="

echo "== 自检（首次换机时 macOS 只应询问一次文稿权限）=="
if [ -n "$cortex_repo_root" ] && [ "$watch_dir_explicit" -eq 0 ]; then
  CORTEX_REPO_ROOT="$cortex_repo_root" "$app_executable" --dump-state
else
  CORTEX_SENTINEL_WATCH_DIR="$watch_dir" "$app_executable" --dump-state
fi

all_sentinel_count="$(ps -axo command= | awk '/\/Contents\/MacOS\/CortexSentinelBar$/ { count++ } END { print count + 0 }')"
if [ "$all_sentinel_count" -ne 1 ]; then
  echo "失败：自检后常驻实例数不是 1：$all_sentinel_count" >&2
  exit 1
fi

trap - EXIT
echo "== 安装完成：自启已修复，常驻实例=1 =="
if [ "$used_fallback_watch" -eq 1 ]; then
  echo "没找到 Cortex 仓库，先盯 ~/.cortex-sentinel/logs。要换目录在设置里点「选择」。"
fi
