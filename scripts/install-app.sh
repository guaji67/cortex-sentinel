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
restart_command_dest="/Applications/重启 Cortex 哨兵.command"
service_label="com.cortex.sentinelbar"
plist="$HOME/Library/LaunchAgents/$service_label.plist"
uid="$(id -u)"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
app_source=""
verify_integrity_only=0
cortex_repo_root="${CORTEX_REPO_ROOT:-}"
watch_dir="${CORTEX_SENTINEL_WATCH_DIR:-}"
watch_dir_explicit=0
default_watch_dir="$HOME/.cortex-sentinel/logs"
if [ -n "$watch_dir" ]; then
  watch_dir_explicit=1
fi
skip_login_item_cleanup=0
print_watch_plan=0
dry_run=0
cleanup_login_items_only=0
used_fallback_watch=0
if [ -n "${SSH_CONNECTION:-}" ]; then
  skip_login_item_cleanup=1
fi

nfc_normalize() {
  /usr/bin/python3 -c 'import sys, unicodedata; sys.stdout.write(unicodedata.normalize("NFC", sys.argv[1]))' "$1"
}

# 登录项是否属于本哨兵：名字等于 CFBundleName / 显示名 / 包名，或路径 NFC 后等于目标。
# 不匹配 /Applications/Cortex.app，避免误删主仓 app。
login_item_should_remove() {
  local item_name="$1"
  local item_path="${2:-}"
  local target_path="${3:-}"
  local n_name nfc_path nfc_target
  local display_spaced display_compact bundle_name

  n_name="$(nfc_normalize "$item_name")"
  nfc_path="$(nfc_normalize "$item_path")"
  nfc_target="$(nfc_normalize "$target_path")"
  display_spaced="$(nfc_normalize "Cortex 哨兵")"
  display_compact="$(nfc_normalize "Cortex哨兵")"
  bundle_name="$(nfc_normalize "CortexSentinelBar")"

  case "$n_name" in
    Cortex.app|Cortex)
      return 1
      ;;
  esac
  case "$nfc_path" in
    */Cortex.app|*/Cortex.app/)
      return 1
      ;;
  esac

  if [ "$n_name" = "$display_compact" ] || [ "$n_name" = "$display_spaced" ] || [ "$n_name" = "$bundle_name" ]; then
    return 0
  fi
  case "$n_name" in
    *"$display_compact"*|*"$bundle_name"*)
      return 0
      ;;
  esac
  if [[ "$n_name" == *"$display_spaced"* ]]; then
    return 0
  fi

  if [ -n "$nfc_path" ] && [ -n "$nfc_target" ] && [ "$nfc_path" = "$nfc_target" ]; then
    return 0
  fi

  if [ -n "$nfc_path" ]; then
    case "$nfc_path" in
      *"$display_compact".app*|*"CortexSentinelBar.app"*)
        case "$nfc_path" in
          *"/.build/"*"CortexSentinelBar.app"*)
            return 0
            ;;
        esac
        if [[ "$nfc_path" == *"/Applications/Cortex"* ]] && [[ "$nfc_path" != *"Cortex.app/"* ]]; then
          return 0
        fi
        if [[ "$nfc_path" == *"$display_compact"* ]]; then
          return 0
        fi
        ;;
    esac
  fi

  return 1
}

list_login_items() {
  osascript <<'APPLESCRIPT'
tell application "System Events"
  set output to ""
  if (count of login items) is 0 then return output
  set itemNames to name of every login item
  set itemPaths to path of every login item
  set itemCount to count of itemNames
  repeat with i from 1 to itemCount
    set n to item i of itemNames as string
    set p to ""
    try
      set pRaw to item i of itemPaths
      if pRaw is not missing value then set p to pRaw as string
    end try
    if p is "missing value" then set p to ""
    set output to output & n & tab & p
    if i is not itemCount then set output to output & linefeed
  end repeat
end tell
return output
APPLESCRIPT
}

list_matching_login_items() {
  local app_path="$1"
  local listed name path
  listed="$(list_login_items | tr -d '\r')"
  [ -n "$listed" ] || return 0
  while IFS=$'\t' read -r name path || [ -n "${name:-}" ]; do
    [ -n "${name:-}" ] || [ -n "${path:-}" ] || continue
    if login_item_should_remove "$name" "${path:-}" "$app_path"; then
      printf '%s\t%s\n' "$name" "${path:-}"
    fi
  done <<< "$listed"
}

print_login_item_manual_commands() {
  cat <<'EOF'
手工删除（可抄）：
  osascript -e 'tell application "System Events" to delete (every login item whose name contains "Cortex哨兵")'
  osascript -e 'tell application "System Events" to delete (every login item whose name contains "CortexSentinelBar")'
复核登录项：
  osascript -e 'tell application "System Events" to get the name of every login item'
  osascript -e 'tell application "System Events" to get the path of every login item'
复核实例：
  launchctl list | grep -E 'com\.cortex\.sentinelbar|application\.com\..*sentinelbar'
  ps -axo pid=,command= | awk '/\/Contents\/MacOS\/CortexSentinelBar$/ { print }'
EOF
}

delete_matching_login_items() {
  osascript - "$@" <<'APPLESCRIPT'
on run argv
  set removedCount to 0
  tell application "System Events"
    repeat with i from (count of login items) to 1 by -1
      set li to login item i
      set itemName to name of li as string
      set itemPath to ""
      try
        set pathRaw to path of li
        if pathRaw is not missing value then set itemPath to pathRaw as string
      end try
      if itemPath is "missing value" then set itemPath to ""
      set shouldDelete to false
      repeat with targetName in argv
        if itemName is (targetName as string) then set shouldDelete to true
      end repeat
      if itemName contains "Cortex哨兵" then set shouldDelete to true
      if itemName contains "CortexSentinelBar" then set shouldDelete to true
      if itemPath contains "Cortex哨兵" then set shouldDelete to true
      if (itemPath contains "/.build/") and (itemPath contains "CortexSentinelBar.app") then set shouldDelete to true
      if shouldDelete then
        delete li
        set removedCount to removedCount + 1
      end if
    end repeat
  end tell
  return removedCount
end run
APPLESCRIPT
}

count_sentinel_launchd_jobs() {
  launchctl list | awk '
    $3 == "com.cortex.sentinelbar" || $3 ~ /^application\.com\..*sentinelbar/ { count++ }
    END { print count + 0 }
  '
}

count_sentinel_processes() {
  ps -axo command= | awk '/\/Contents\/MacOS\/CortexSentinelBar$/ { count++ } END { print count + 0 }'
}

print_autostart_gate_failure() {
  echo "失败：自启未修复，不打印「已修复」。" >&2
  print_login_item_manual_commands >&2
}

remove_login_item_for_path() {
  local app_path="$1"
  local listed name path
  local -a delete_names=()
  local removed remaining

  if [ "$skip_login_item_cleanup" -eq 1 ]; then
    return 0
  fi

  listed="$(list_login_items | tr -d '\r')" || {
    echo "失败：无法读取登录项列表（System Events）" >&2
    exit 1
  }

  if [ -n "$listed" ]; then
    while IFS=$'\t' read -r name path || [ -n "${name:-}" ]; do
      [ -n "${name:-}" ] || [ -n "${path:-}" ] || continue
      if login_item_should_remove "$name" "${path:-}" "$app_path"; then
        delete_names+=("$name")
      fi
    done <<< "$listed"
  fi

  if [ "${#delete_names[@]}" -gt 0 ]; then
    removed="$(delete_matching_login_items "${delete_names[@]}")"
  else
    removed="$(delete_matching_login_items)"
  fi

  if [ "${removed:-0}" -gt 0 ]; then
    echo "已删除旧登录项：$app_path ($removed 条，按名字+路径双判)"
  fi

  remaining="$(list_matching_login_items "$app_path")"
  if [ -n "$remaining" ]; then
    echo "失败：登录项仍在，未删干净：" >&2
    echo "$remaining" >&2
    print_login_item_manual_commands >&2
    exit 1
  fi
}

remove_historical_build_login_items() {
  remove_login_item_for_path "$app_dest"
}

assert_autostart_repaired() {
  local all_sentinel_count launch_count remaining
  local failed=0

  all_sentinel_count="$(count_sentinel_processes)"
  launch_count="$(count_sentinel_launchd_jobs)"

  if [ "$all_sentinel_count" -ne 1 ]; then
    echo "失败：常驻实例数=${all_sentinel_count}（期望 1）" >&2
    failed=1
  fi
  if [ "$launch_count" -ne 1 ]; then
    echo "失败：launchctl 哨兵条目数=${launch_count}（期望 1，label=com.cortex.sentinelbar）" >&2
    failed=1
  fi
  if [ "$skip_login_item_cleanup" -eq 0 ]; then
    remaining="$(list_matching_login_items "$app_dest")"
    if [ -n "$remaining" ]; then
      echo "失败：登录项列表里还有本 app：" >&2
      echo "$remaining" >&2
      failed=1
    fi
  fi

  if [ "$failed" -ne 0 ]; then
    print_autostart_gate_failure
    exit 1
  fi
}

# 供 Tests/scripts/test_login_item_match.sh 只加载比对函数，不跑安装。
if [ "${SENTINEL_LOGIN_ITEM_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

usage() {
  cat <<'EOF'
用法：
  bash scripts/install-app.sh
  bash scripts/install-app.sh --app-source /path/to/Cortex哨兵.app
  bash scripts/install-app.sh --app-source /path/to/Cortex哨兵.app --cortex-root /path/to/cortex
  bash scripts/install-app.sh --app-source /path/to/Cortex哨兵.app --skip-login-item-cleanup
  bash scripts/install-app.sh --cleanup-login-items-only
  bash scripts/install-app.sh --dry-run
  bash scripts/install-app.sh --verify-installer-integrity --app-source /path/to/Cortex哨兵.app

监视目录（写入 launchd）：
  CORTEX_SENTINEL_WATCH_DIR   优先，直接指向日志目录
  CORTEX_REPO_ROOT / --cortex-root   兼容旧装法，读取 <root>/logs（目录必须存在）
  都没有时创建并使用 ~/.cortex-sentinel/logs；此时不往 LaunchAgent 写 CORTEX_REPO_ROOT
  给了无效的 CORTEX_REPO_ROOT 不会失败，按上面顺序继续往下落

不传 --app-source 时从当前源码构建；DMG 分发使用预构建 app，不依赖目标机 Swift/Xcode。
SSH/headless 环境会自动跳过可能阻塞的 System Events 查询；旧 app 仍会被归档，因此不会再次启动。
--cleanup-login-items-only 只按名字+路径清旧登录项，不构建、不重装、不重启。
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
    --cleanup-login-items-only)
      cleanup_login_items_only=1
      shift
      ;;
    --verify-installer-integrity)
      verify_integrity_only=1
      shift
      ;;
    --print-watch-plan)
      print_watch_plan=1
      shift
      ;;
    --dry-run)
      dry_run=1
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

if [ "$cleanup_login_items_only" -eq 1 ]; then
  skip_login_item_cleanup=0
  remove_login_item_for_path "$app_dest"
  echo "登录项清理完成：列表里已无 Cortex哨兵 / CortexSentinelBar"
  exit 0
fi

installer_script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

verify_installer_integrity() {
  local app_path="$1"
  local manifest_path="$app_path/Contents/Resources/installer-manifest.json"
  local expected_sha256
  local actual_sha256
  local normalized_expected_sha256
  local normalized_actual_sha256

  [ -d "$app_path" ] || {
    echo "失败：待安装 app 不存在：$app_path" >&2
    return 1
  }
  [ -f "$manifest_path" ] || {
    echo "失败：app 内缺少安装器完整性清单：$manifest_path" >&2
    return 1
  }
  if ! expected_sha256="$(plutil -extract installer_sha256 raw -o - "$manifest_path" 2>/dev/null)"; then
    echo "失败：读取安装器完整性清单失败：$manifest_path" >&2
    return 1
  fi
  if [[ ! "$expected_sha256" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "失败：安装器完整性清单中的 SHA-256 格式不正确：$expected_sha256" >&2
    return 1
  fi
  actual_sha256="$(shasum -a 256 "$installer_script_path" | awk '{print $1}')"
  normalized_expected_sha256="$(printf '%s' "$expected_sha256" | tr '[:upper:]' '[:lower:]')"
  normalized_actual_sha256="$(printf '%s' "$actual_sha256" | tr '[:upper:]' '[:lower:]')"
  if [ "$normalized_expected_sha256" != "$normalized_actual_sha256" ]; then
    echo "失败：安装器完整性校验不匹配：manifest=${expected_sha256}，实际=${actual_sha256}，文件=${installer_script_path}" >&2
    return 1
  fi
  echo "安装器完整性校验通过：sha256=$normalized_actual_sha256"
}

if [ "$verify_integrity_only" -eq 1 ]; then
  [ -n "$app_source" ] || {
    echo "失败：--verify-installer-integrity 必须配合 --app-source" >&2
    exit 2
  }
  app_source="$(cd "$(dirname "$app_source")" && pwd)/$(basename "$app_source")"
  verify_installer_integrity "$app_source"
  exit 0
fi

if [ -z "$watch_dir" ]; then
  if [ -n "$cortex_repo_root" ] && [ -d "$cortex_repo_root/logs" ]; then
    watch_dir="$cortex_repo_root/logs"
  else
    cortex_repo_root=""
    watch_dir="$default_watch_dir"
    used_fallback_watch=1
  fi
fi

if [ -n "$cortex_repo_root" ] && [ ! -d "$cortex_repo_root" ]; then
  cortex_repo_root=""
fi

if [ "$dry_run" -eq 1 ]; then
  echo "registration_route=LaunchAgent:$plist"
  echo "app_self_registration=disabled (SMAppService 不调用 register/unregister)"
  echo "historical_login_item_cleanup=delete login items whose name is Cortex哨兵/CortexSentinelBar or whose NFC path equals /Applications/Cortex哨兵.app"
  echo "cleanup_scope=install/uninstall script only; no current machine state changed"
  exit 0
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
verify_installer_integrity "$app_source"
if [ ! -x "$app_source/Contents/Resources/sentinel-ctl.sh" ]; then
  echo "失败：app 内缺少哨兵重启脚本：$app_source/Contents/Resources/sentinel-ctl.sh" >&2
  exit 1
fi
if ! lipo -archs "$app_source/Contents/MacOS/CortexSentinelBar" | tr ' ' '\n' | grep -qx arm64; then
  echo "失败：预构建 app 不包含 arm64" >&2
  exit 1
fi

backup_dir="$HOME/Library/Application Support/Cortex/SentinelInstallBackups/$(date +%Y%m%d-%H%M%S)"
had_app=0
had_plist=0
had_restart_command=0
mkdir -p "$backup_dir"
if [ -d "$app_dest" ]; then
  ditto "$app_dest" "$backup_dir/Cortex哨兵.app"
  had_app=1
fi
if [ -f "$plist" ]; then
  cp -p "$plist" "$backup_dir/$service_label.plist"
  had_plist=1
fi
if [ -f "$restart_command_dest" ]; then
  cp -p "$restart_command_dest" "$backup_dir/restart-sentinel.command"
  had_restart_command=1
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
  if [ "$had_restart_command" -eq 1 ]; then
    cp -p "$backup_dir/restart-sentinel.command" "$restart_command_dest"
  else
    rm -f "$restart_command_dest"
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
remove_historical_build_login_items
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
cp "$package_dir/scripts/restart-sentinel.command" "$restart_command_dest"
chmod 0755 "$restart_command_dest"
echo "== 已安装独立重启入口：$restart_command_dest =="

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
remove_login_item_for_path "$app_dest"
assert_autostart_repaired
echo "== 安装完成：自启已修复，常驻实例=1 =="
if [ "$used_fallback_watch" -eq 1 ]; then
  echo "没找到 Cortex 仓库，先盯 ~/.cortex-sentinel/logs。要换目录在设置里点「选择」。"
fi
