#!/usr/bin/env bash
# 把内存监控这套东西部署到仓外，再挂 launchd。
#
# 为什么必须部署到仓外（2026-08-18 实测换来的，别把 plist 改回指仓内）：
# 仓住在 ~/Documents，那是 macOS TCC 保护目录。launchd 上下文里访问仓内文件有两种失败，
# 第二种更坏：/bin/bash 直跑仓内 .sh 是 exit 126（干净拒），而仓内 venv/bin/python3
# 当入口时连解释器都启动不了、进程挂住不返回（launchctl print 显示 never exited）。
# 「挂上了」和「在跑」在 launchctl list 上长得一模一样，只有第二列退出码 + ps 运行时长
# 两条一起看才分得出。完整对照见 docs/reference/macos-tcc-authorization-persistence.md
# 「第四条补边界」那节。
#
# 仓外这条路是照 com.falcon.cortex.web 抄的形状（它整个跑在
# ~/Library/Application Support/Cortex/WebRuntime/current/，连续跑三天没事）。
# 仓里仍然是正本，这里做的是安装动作。
#
# 产物落点不搬：三方（本脚本部署的 monitor、dev_server_reaper.py、前端
# /api/cortex-health）都以 CORTEX_DATA_ROOT 为准，默认 ~/CortexData/health，
# 那本来就在仓外，所以 Falcon 和前端看的还是同一份。
#
# 用法：
#   install_health_runtime.sh install      # 装（幂等，等于 update）
#   install_health_runtime.sh update       # 仓内正本改了之后同步仓外那份并重启 job
#   install_health_runtime.sh status       # 两条判据一起看，并报 payload 漂移
#   install_health_runtime.sh drift        # 仓内正本 vs 仓外 current：DIFF / MISSING / EXTRA
#   install_health_runtime.sh drift --repair  # 发现漂移后从本树跑 update；worktree 会拒
#   install_health_runtime.sh uninstall    # 摘 job + 移除 plist（current 进回收站不硬删）
#
# 漂移检测住在仓内 scripts/health/payload_drift.py，故意不进下面的 PAYLOAD。
# 检测器如果也拷到仓外，它自己漂了就报不出来；launchd 也不许回头读仓内（TCC 会挂住）。

set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LABEL="${CORTEX_HEALTH_LAUNCHD_LABEL:-com.falcon.cortex.memory-monitor}"
HOME_DIR="${CORTEX_HEALTH_LAUNCHD_HOME:-$HOME}"
RUNTIME_PARENT="${CORTEX_HEALTH_RUNTIME_PARENT:-$HOME_DIR/Library/Application Support/Cortex/HealthRuntime}"
RUNTIME_ROOT="$RUNTIME_PARENT/current"
LAUNCH_AGENT_DIR="${CORTEX_HEALTH_LAUNCH_AGENT_DIR:-$HOME_DIR/Library/LaunchAgents}"
PLIST_PATH="$LAUNCH_AGENT_DIR/$LABEL.plist"
# 数据根走仓内统一解析层，不在 shell 里硬兜底路径字面量
# （硬兜底会压死解析层探测，2026-07 数据根外置那次就是这么踩的）。
resolve_data_root() {
  if [[ -n "${CORTEX_DATA_ROOT:-}" ]]; then printf '%s' "$CORTEX_DATA_ROOT"; return 0; fi
  # 独立版只认环境变量或 config.toml 里项目的 data_root，不再去问 Cortex 产品层。
  if command -v python3 >/dev/null 2>&1; then
    ( cd "$PROJECT_ROOT" && PYTHONPATH="$PROJECT_ROOT" python3 -c \
      'from cortex_sentinel.paths import projects
ps=projects()
print(next((p.get("data_root") or "" for p in ps if p.get("data_root")), "") or "")' 2>/dev/null ) && return 0
  fi
  return 1
}
DATA_ROOT="$(resolve_data_root || true)"
LOG_DIR="$RUNTIME_PARENT/logs"
LOG_PATH="$LOG_DIR/memory-monitor.log"
INTERVAL="${CORTEX_HEALTH_INTERVAL_SECONDS:-600}"
DOMAIN="gui/$(id -u)"

# 入口解释器：必须是仓外的真身，不能是仓内 venv/bin/python3 那条符号链接
# （那条 launchd 下启动不了，见文件头）。默认取仓内 venv 解析出的真身。
resolve_python() {
  if [[ -n "${CORTEX_HEALTH_PYTHON:-}" && -x "${CORTEX_HEALTH_PYTHON}" ]]; then
    printf '%s' "$CORTEX_HEALTH_PYTHON"; return 0
  fi
  command -v python3 2>/dev/null || true
}

# 要搬到仓外的东西。少一个都跑不起来，所以逐个核。
PAYLOAD=(
  "scripts/memory_monitor.sh"
  "scripts/memory_monitor_launchd.py"
  "scripts/panel_summary.py"
  "scripts/codex_lines.sh"
  "bin/cortex-sentinel"
  "cortex_sentinel/__init__.py"
  "cortex_sentinel/paths.py"
  "cortex_sentinel/registry.py"
  "cortex_sentinel/channel.py"
  "cortex_sentinel/watch.py"
  "cortex_sentinel/memory.py"
  "cortex_sentinel/disk.py"
  "cortex_sentinel/reclaim.py"
  "cortex_sentinel/devserver.py"
  "cortex_sentinel/memwatch.py"
  "cortex_sentinel/cli.py"
  "cortex_sentinel/dispatch/__init__.py"
  "cortex_sentinel/dispatch/codex.py"
  "cortex_sentinel/dispatch/grok.py"
  "cortex_sentinel/dispatch/progress.py"
  "cortex_sentinel/bridges/__init__.py"
  "cortex_sentinel/bridges/multica.py"
  "cortex_sentinel/data/agent-host-map.yaml"
)

die() { echo "ERROR: $*" >&2; exit 1; }

trash_path() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 0
  local helper="$PROJECT_ROOT/scripts/trash_path.sh"
  if [[ -x "$helper" ]]; then
    "$helper" "$target" >/dev/null 2>&1 && return 0
  fi
  local stamp; stamp="$(date +%Y%m%d%H%M%S)"
  mkdir -p "$HOME_DIR/.Trash"
  mv "$target" "$HOME_DIR/.Trash/$(basename "$target").$stamp" 2>/dev/null || die "挪不动 $target"
}

stage_payload() {
  local staging="$RUNTIME_PARENT/.staging-$(date +%Y%m%d%H%M%S)-$$"
  mkdir -p "$staging" || die "建不了 $staging"
  local rel
  for rel in "${PAYLOAD[@]}"; do
    [[ -f "$PROJECT_ROOT/$rel" ]] || die "仓内缺件: $rel"
    mkdir -p "$staging/$(dirname "$rel")"
    cp "$PROJECT_ROOT/$rel" "$staging/$rel" || die "拷不动 $rel"
  done
  # 逐个核对，缺件要报到具体文件名（仓内板块的老规矩）
  for rel in "${PAYLOAD[@]}"; do
    [[ -f "$staging/$rel" ]] || die "staging 缺件: $rel"
  done
  printf '%s' "$staging"
}

render_plist() {
  local py="$1"
  mkdir -p "$LAUNCH_AGENT_DIR" "$LOG_DIR"
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- 这份 plist 由 scripts/health/install_health_runtime.sh 生成，别手改。
         所有路径都指仓外 HealthRuntime：仓在 ~/Documents（TCC 保护目录），
         launchd 下访问仓内会 exit 126 或直接挂住。 -->
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$RUNTIME_ROOT/scripts/memory_monitor.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>$RUNTIME_ROOT</string>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>$INTERVAL</integer>

    <key>StandardOutPath</key>
    <string>$LOG_PATH</string>

    <key>StandardErrorPath</key>
    <string>$LOG_PATH</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME_DIR</string>
        <key>LANG</key>
        <string>en_US.UTF-8</string>
        <key>LC_ALL</key>
        <string>en_US.UTF-8</string>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
        <!-- 产物落数据根，跟 dev_server_reaper.py 与前端 /api/cortex-health 同一份 -->
        <key>CORTEX_DATA_ROOT</key>
        <string>$DATA_ROOT</string>
        <!-- 仓外那份没有 venv，解释器显式钉死成仓外真身 -->
        <key>CORTEX_PYTHON</key>
        <string>$py</string>
    </dict>
</dict>
</plist>
PLIST
  [[ -s "$PLIST_PATH" ]] || die "plist 没写出来: $PLIST_PATH"
}

verify_job() {
  # 两条判据一起看。只看退出码会被「挂住」骗过去：从没退出过的 job
  # 在 launchctl list 里显示的也是 0。
  local line rc pid etime secs
  line="$(launchctl list 2>/dev/null | grep -F "$LABEL" || true)"
  [[ -n "$line" ]] || { echo "  判据①失败: launchctl list 里没有 $LABEL"; return 1; }
  pid="$(awk '{print $1}' <<<"$line")"
  rc="$(awk '{print $2}' <<<"$line")"
  echo "  launchctl list → pid=$pid 退出码=$rc"
  if [[ "$rc" != "0" ]]; then
    echo "  判据①失败: 退出码 ${rc}（126 = 挂上了但每次被 TCC 拒）"
    return 1
  fi
  if [[ "$pid" == "-" ]]; then
    echo "  判据②通过: 当前没在跑（上一轮已正常退出）"
    return 0
  fi
  etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
  secs="$(awk -F: '{n=NF; s=0; m=1; for(i=n;i>=1;i--){s+=$i*m; m=(m==1?60:m*60)} print s}' <<<"${etime:-0}")"
  echo "  ps → 已运行 ${etime:-?}（${secs:-?} 秒），StartInterval=$INTERVAL"
  if [[ -n "$secs" ]] && (( secs > INTERVAL )); then
    echo "  判据②失败: 运行时长超过 StartInterval，这是挂住不是在跑"
    return 1
  fi
  echo "  判据②通过"
  return 0
}

cmd_install() {
  local py; py="$(resolve_python)"
  [[ -n "$py" && -x "$py" ]] || die "找不到可用的仓外 python3（试过 CORTEX_HEALTH_PYTHON、仓内 venv 的真身、PATH）"
  case "$py" in
    "$PROJECT_ROOT"/*) die "解析出来的 python 落在仓内（${py}），launchd 下起不来；用 CORTEX_HEALTH_PYTHON 指一个仓外的" ;;
  esac
  echo "入口解释器（必须在仓外）: $py"

  [[ -n "$DATA_ROOT" ]] || die "解析不出数据根：既没有 CORTEX_DATA_ROOT，产品的 get_data_root() 也给不出。显式传 CORTEX_DATA_ROOT=<绝对路径> 再来"

  # 解析出来的数据根不在启动卷上时不许直接用。
  # mini 上 get_data_root() 解析出的是镜像盘（Pro 单向镜像过来的真身副本），
  # 而「禁写镜像盘」是红线：那是别人数据的镜像，不是本机该写运行时证据的地方。
  # 判据是「跟家目录在同一个卷」，不写死任何盘名。
  # 不能拿「挂载点是不是 /」当判据：APFS 卷组下家目录的挂载点是 /System/Volumes/Data，
  # 那么写会把本机盘也一起拦掉（第一版就是这么错的）。
  local root_mount home_mount
  root_mount="$(df -P "${DATA_ROOT}" 2>/dev/null | awk 'NR==2{print $NF}')"
  home_mount="$(df -P "${HOME_DIR}" 2>/dev/null | awk 'NR==2{print $NF}')"
  if [[ -n "$root_mount" && -n "$home_mount" && "$root_mount" != "$home_mount" ]]; then
    die "解析出的数据根跟家目录不在同一个卷（${DATA_ROOT} 在 ${root_mount}，家目录在 ${home_mount}）。健康监控每 10 分钟要往 health/ 写东西，不往外挂或镜像卷写。显式传一个本机盘的 CORTEX_DATA_ROOT=<绝对路径> 再来"
  fi

  # RunAtLoad 这一轮只验证 job 能正常退出，不拿真实缓存/进程做验收样本。
  # monitor 结束时把 marker mv 成 used；下一轮起恢复真实自动回收。
  local install_verify_marker="$DATA_ROOT/health/.install-verify-dry-run"
  mkdir -p "$(dirname "$install_verify_marker")" || die "建不了 health 状态目录"
  printf 'created_at=%s\n' "$(TZ=Asia/Shanghai date '+%Y-%m-%dT%H:%M:%S%z')" > "$install_verify_marker"

  local staging; staging="$(stage_payload)" || exit 1
  echo "staging: $staging"

  # 已经装过就先摘 job，避免替换 current 的时候它正在读
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true

  if [[ -d "$RUNTIME_ROOT" ]]; then
    trash_path "$RUNTIME_ROOT"
  fi
  mv "$staging" "$RUNTIME_ROOT" || die "换不上 current"
  echo "current: $RUNTIME_ROOT"

  # 首装/无状态时从现在开始计 7 天；update 保留原 schedule。
  CORTEX_DATA_ROOT="$DATA_ROOT" "$py" \
    "$RUNTIME_ROOT/scripts/health/dev_cache_reclaimer.py" \
    --mark-installed --home "$HOME_DIR" \
    --state "$DATA_ROOT/health/.dev-cache-reclaimer-state.json" >/dev/null \
    || die "播种开发缓存周冷却失败"

  render_plist "$py"
  echo "plist: $PLIST_PATH"

  launchctl bootstrap "$DOMAIN" "$PLIST_PATH" 2>&1 || echo "  (bootstrap 返回非 0，继续核实际状态)"
  echo "等 15 秒让它跑一轮…"
  sleep 15
  verify_job
}

cmd_uninstall() {
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  [[ -f "$PLIST_PATH" ]] && trash_path "$PLIST_PATH"
  [[ -d "$RUNTIME_ROOT" ]] && trash_path "$RUNTIME_ROOT"
  echo "已摘 ${LABEL}；plist 与 current 都进回收站，没硬删"
}

cmd_status() {
  echo "label=$LABEL"
  echo "runtime=$RUNTIME_ROOT $( [[ -d "$RUNTIME_ROOT" ]] && echo '(在)' || echo '(不在)')"
  echo "plist=$PLIST_PATH $( [[ -f "$PLIST_PATH" ]] && echo '(在)' || echo '(不在)')"
  # 显示已装的那份 plist 里真正写着的落点，不是本次解析出来的值——
  # 这两个可以不一样（装的时候可能显式传过别的），只显示解析值会误导人。
  local installed_root=""
  if [[ -f "$PLIST_PATH" ]]; then
    installed_root="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:CORTEX_DATA_ROOT' "$PLIST_PATH" 2>/dev/null || true)"
  fi
  echo "data_root(已装的 plist 里写着的)=${installed_root:-（plist 里没有或没装）}"
  echo "data_root(本次解析出来的)=${DATA_ROOT:-（解析不出）}"
  verify_job || true
  echo "最近日志尾部:"
  [[ -s "$LOG_PATH" ]] && tail -5 "$LOG_PATH" | sed 's/^/    /' || echo "    (空，monitor 正常时静默)"
  echo "payload 漂移（仓内正本 vs 仓外 current）:"
  cmd_drift
}

resolve_repo_python() {
  # 漂移检测在仓内跑（人、git hook、agent），可以用仓内 venv。
  # launchd 巡检不许走这条：仓内解释器在后台任务里会挂住。
  if [[ -x "$PROJECT_ROOT/venv/bin/python3" ]]; then
    printf '%s' "$PROJECT_ROOT/venv/bin/python3"
    return 0
  fi
  command -v python3 2>/dev/null || true
}

cmd_drift() {
  local want_repair=0
  [[ "${1:-}" == "--repair" ]] && want_repair=1
  local py; py="$(resolve_repo_python)"
  [[ -n "$py" && -x "$py" ]] || die "找不到 python3，跑不了 payload 漂移检测"
  local drift="$PROJECT_ROOT/scripts/health/payload_drift.py"
  [[ -f "$drift" ]] || die "仓内缺件: scripts/health/payload_drift.py（检测器必须住在仓内，不进拷贝）"
  local installer="$PROJECT_ROOT/scripts/health/install_health_runtime.sh"
  [[ -f "$installer" ]] || installer="${BASH_SOURCE[0]}"
  if "$py" "$drift" --source "$PROJECT_ROOT" --runtime "$RUNTIME_ROOT" --installer "$installer"; then
    return 0
  fi
  if [[ "$want_repair" -ne 1 ]]; then
    return 1
  fi
  if [[ -f "$PROJECT_ROOT/.git" ]]; then
    die "这是 git worktree，不把未合入的副本刷进机器上的巡检。从主仓跑: CORTEX_DATA_ROOT=\"\$HOME/CortexData\" bash scripts/health/install_health_runtime.sh update"
  fi
  echo "检测到漂移，从本树跑 update…"
  cmd_install
  "$py" "$drift" --source "$PROJECT_ROOT" --runtime "$RUNTIME_ROOT" --installer "$installer"
}

case "${1:-}" in
  install|update) cmd_install ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  drift) cmd_drift "${2:-}" ;;
  *) echo "用法: $0 {install|update|status|uninstall|drift}" >&2; exit 2 ;;
esac
