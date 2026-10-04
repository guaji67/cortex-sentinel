#!/usr/bin/env bash
# 装「模型口碑」命令 sentinel-review（backend/cortex_sentinel/review.py）。
#
# 做的事：把 review.py、occupancy.py（读口复用）和 sentinel-review 拷到仓外
# ~/Library/Application Support/CortexSentinel/review-runtime/，把命令包一层链到 ~/.local/bin/sentinel-review。
# 没有 launchd job，不是常驻。评价记录落 ~/Library/Application Support/CortexSentinel/reviews/，
# 里面有「不要删除.md」；uninstall 只摘命令，记录永远不删。
#
# 用法：
#   install_review.sh install     装 / 更新（幂等）
#   install_review.sh status      看命令和记录目录
#   install_review.sh uninstall   摘命令和运行时；评价记录不动
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/CortexSentinel"
RUNTIME="$SUPPORT/review-runtime"
DATA_DIR="$SUPPORT/reviews"

pick_python() {
  local health="$HOME/Library/Application Support/Cortex/HealthRuntime/current/bin/python3"
  if [[ -x "$health" ]]; then printf '%s' "$health"; else printf '%s' /usr/bin/python3; fi
}

cmd="${1:-install}"
case "$cmd" in
  install)
    PYTHON3="$(pick_python)"
    mkdir -p "$RUNTIME/bin" "$RUNTIME/cortex_sentinel/data" "$DATA_DIR" "$HOME/.local/bin"
    # 俗名表（list --model 用）：随代码带一份；第一次用时拷到评价记录目录，改那一份，重装不覆盖
    cp "$HERE/cortex_sentinel/data/model-aliases.json" "$RUNTIME/cortex_sentinel/data/model-aliases.json"
    cp "$HERE/bin/sentinel-review" "$RUNTIME/bin/sentinel-review"
    cp "$HERE/cortex_sentinel/__init__.py" "$HERE/cortex_sentinel/occupancy.py" "$HERE/cortex_sentinel/review.py" "$RUNTIME/cortex_sentinel/"
    chmod +x "$RUNTIME/bin/sentinel-review"
    cat > "$HOME/.local/bin/sentinel-review" <<WRAP
#!/usr/bin/env bash
exec "$PYTHON3" "$RUNTIME/bin/sentinel-review" "\$@"
WRAP
    chmod +x "$HOME/.local/bin/sentinel-review"
    # 第一次装顺手把「不要删除.md」落好
    "$HOME/.local/bin/sentinel-review" summary --days 1 >/dev/null 2>&1 || true
    echo "已装：sentinel-review，评价记录目录 $DATA_DIR"
    ;;
  status)
    ls -l "$HOME/.local/bin/sentinel-review" 2>/dev/null || echo "命令没装"
    ls -la "$DATA_DIR" 2>/dev/null | tail -5
    ;;
  uninstall)
    rm -f "$HOME/.local/bin/sentinel-review"
    rm -rf "$RUNTIME"
    echo "已摘命令；评价记录目录 $DATA_DIR 保留不动"
    ;;
  *)
    echo "用法：$0 install|status|uninstall" >&2; exit 2 ;;
esac
