#!/usr/bin/env bash
# 装「派工占用 + 派工记录」每分钟记账（backend/cortex_sentinel/occupancy.py）。
#
# 做的事：把 occupancy.py、review.py、fallback_audit.py 和 sentinel-occupancy 拷到仓外
# ~/Library/Application Support/CortexSentinel/occupancy-runtime/，写一个每分钟起一次的
# LaunchAgent（记一轮就退出，不是常驻），把查询命令链到 ~/.local/bin/sentinel-occupancy。
# 记录落 ~/Library/Application Support/CortexSentinel/occupancy/，里面有「不要删除.md」。
#
# 用法：
#   install_occupancy_log.sh install     装 / 更新（幂等）
#   install_occupancy_log.sh status      看 job 是不是在转、最近一行记录几点
#   install_occupancy_log.sh uninstall   摘 job 和 plist；已记的两份 jsonl 不动
#
# 恢复：uninstall 即可回到装之前；记录目录永远不删。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.cortex.sentinel.occupancy-log"
SUPPORT="$HOME/Library/Application Support/CortexSentinel"
RUNTIME="$SUPPORT/occupancy-runtime"
DATA_DIR="$SUPPORT/occupancy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
CHECKOUT_BASE="${CORTEX_GATE_CHECKOUT_BASE:-$HOME/Documents/code/cortex}"

pick_python() {
  local health="$HOME/Library/Application Support/Cortex/HealthRuntime/current/bin/python3"
  if [[ -x "$health" ]]; then printf '%s' "$health"; else printf '%s' /usr/bin/python3; fi
}

cmd="${1:-install}"
case "$cmd" in
  install)
    PYTHON3="$(pick_python)"
    mkdir -p "$RUNTIME/bin" "$RUNTIME/cortex_sentinel" "$DATA_DIR" "$HOME/Library/LaunchAgents" "$HOME/.local/bin"
    cp "$HERE/bin/sentinel-occupancy" "$RUNTIME/bin/sentinel-occupancy"
    # fallback_audit（落兜底档对账，tick 每分钟审一次）要读 review 里三台合看的 ssh 读口，一起拷
    cp "$HERE/cortex_sentinel/__init__.py" "$HERE/cortex_sentinel/occupancy.py" \
       "$HERE/cortex_sentinel/review.py" "$HERE/cortex_sentinel/fallback_audit.py" "$RUNTIME/cortex_sentinel/"
    chmod +x "$RUNTIME/bin/sentinel-occupancy"
    # 查询入口：包一层，保证用能跑它的解释器
    cat > "$HOME/.local/bin/sentinel-occupancy" <<WRAP
#!/usr/bin/env bash
exec "$PYTHON3" "$RUNTIME/bin/sentinel-occupancy" "\$@"
WRAP
    chmod +x "$HOME/.local/bin/sentinel-occupancy"
    sed -e "s|@PYTHON3@|$PYTHON3|g" -e "s|@INSTALL_ROOT@|$RUNTIME|g" -e "s|@HOME@|$HOME|g" \
        -e "s|@DATA_DIR@|$DATA_DIR|g" -e "s|@CHECKOUT_BASE@|$CHECKOUT_BASE|g" \
        "$HERE/launchd/$LABEL.plist.tmpl" > "$PLIST"
    plutil -lint "$PLIST" >/dev/null || { echo "plist 不合法" >&2; exit 1; }
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    # bootout 是异步的：等老的真卸干净再挂，否则 bootstrap 会报 Input/output error（实测 5 次里 1 次）
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
      /bin/sleep 1
    done
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || { /bin/sleep 2; launchctl bootstrap "$DOMAIN" "$PLIST"; } \
      || { echo "bootstrap 失败" >&2; exit 1; }
    echo "已装：$LABEL（每分钟一轮），记录目录 $DATA_DIR"
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state|last exit code|runs" || echo "job 没挂"
    ls -la "$DATA_DIR" 2>/dev/null | tail -8
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$HOME/.local/bin/sentinel-occupancy"
    echo "已摘 job；记录目录 $DATA_DIR 保留不动"
    ;;
  *)
    echo "用法：$0 install|status|uninstall" >&2; exit 2 ;;
esac
