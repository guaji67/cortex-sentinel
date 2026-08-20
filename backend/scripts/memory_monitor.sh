#!/usr/bin/env bash
# Cortex 内存监控：每次采样一次，发现内存到顶或 Cortex 进程失控就记一条异常，
# 攒在 data/health/memory-anomalies.md（不打断 Falcon）。到提醒周期且有未处理异常时
# 弹一次 macOS 通知提醒他统一看。由 launchd com.falcon.cortex.memory-monitor 每 10 分钟调一次。
#
# 2026-08-18：不再用 ps RSS 判 next-server。RSS 看不见压缩和换出，
# 回收站里 11 GB 的实例当时报 130 MB，这条监控一次都没响。
# 总占用改走 mem_watch.py 的面板口径（App+联动+已压缩），
# 残留 next dev 交给 dev_server_reaper.py 按 top MEM 收。
# 2026-08-19：同一趟还跑磁盘余量闸 + line_reclaimer.py（合并完的工作树 /
# 过期 Multica 工作区 / 出包上一轮 / 闲置构建缓存）。干完不删才是盘满的根因，
# 不是「开太多线」。
#
# 设计见 docs/reference/cortex-runtime-health-guard.md。
# 永不因采样失败崩（launchd 会无脑重试），全程 fail-soft。
set -uo pipefail
export TZ="Asia/Shanghai"

INSTALL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PYTHONPATH="$INSTALL_ROOT${PYTHONPATH:+:$PYTHONPATH}"
ROOT_DIR="$INSTALL_ROOT"
# 落点三级：CORTEX_HEALTH_DIR（测试用，能不污染真实台账验告警）
#         → CORTEX_DATA_ROOT/health（跟 dev_server_reaper.py 与前端 /api/cortex-health 同一口径）
#         → 仓内 data/health（老落点，都没配时保持原行为）
# 之前这里只写了仓内那一条，于是 reaper 落数据根、monitor 落仓内，同一套健康数据分了两处。
if [[ -n "${CORTEX_HEALTH_DIR:-}" ]]; then
  HEALTH_DIR="$CORTEX_HEALTH_DIR"
elif [[ -n "${CORTEX_DATA_ROOT:-}" ]]; then
  HEALTH_DIR="$CORTEX_DATA_ROOT/health"
else
  HEALTH_DIR="${CORTEX_SENTINEL_HOME:-$HOME/.cortex-sentinel}/health"
fi
ANOMALY_DOC="$HEALTH_DIR/memory-anomalies.md"
STATE_FILE="$HEALTH_DIR/.memory-monitor-state"
STASH_DIR="${TMPDIR:-/tmp}/cortex-mem-monitor-stash"
mkdir -p "$HEALTH_DIR" "$STASH_DIR"
INSTALL_VERIFY_MARKER="$HEALTH_DIR/.install-verify-dry-run"
# 安装器放标记的本意是「紧接着那一轮只验证任务能退出，别动手」。
# 旧实现是「只要标记在就空跑」，频繁安装会把回收器无限期饿死。
# 现在：一个巡检间隔里最多因此空跑一轮；同一间隔里再装，这一轮照常 --apply。
install_verify_dry_run=""
install_verify_state=""

# ── 机器容量（只用于报告总量，不参与「该不该收手」判断）──
mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 51539607552)"
total_mem_gb="$(awk -v b="$mem_bytes" 'BEGIN{printf "%.0f", b/1073741824}')"
COOLDOWN_SECONDS="${CORTEX_MEM_COOLDOWN_SECONDS:-86400}" # 同类异常 24h 内不重复记(2026-07-11 清账教训:同一持续状态每小时刷一条,13 天攒 178 条同质噪音)
REMIND_INTERVAL_SECONDS="${CORTEX_MEM_REMIND_INTERVAL_SECONDS:-259200}" # 3 天提醒一次
# Cortex 进程内存上限（MB），超了=「越占越多」嫌疑，记下来查
# next-server 不在这里判：RSS 失明。改由 dev_server_reaper.py。
declare -a PROC_CAPS=(
  "src.screen_cortex.capture:1200"
  "src.realtime.loop:2000"
  "src.run:3000"
)

now_epoch="$(date +%s)"
now_human="$(date '+%Y-%m-%d %H:%M')"
MONITOR_INTERVAL="${CORTEX_MEM_MONITOR_INTERVAL_SECONDS:-600}"
if [[ -f "$INSTALL_VERIFY_MARKER" ]]; then
  last_skip="$(awk -F= '$1=="last_install_verify_skip_epoch"{print $2; exit}' "$STATE_FILE" 2>/dev/null || true)"
  last_skip="${last_skip:-0}"
  [[ "$last_skip" =~ ^[0-9]+$ ]] || last_skip=0
  if (( now_epoch - last_skip >= MONITOR_INTERVAL )); then
    install_verify_dry_run="1"
    install_verify_state="skipped"
  else
    install_verify_state="applied-despite-recent-skip"
  fi
fi

# 解释器两级：CORTEX_PYTHON（部署时显式钉死）→ PATH 里的 python3。
# 独立版不许绑项目内虚拟环境。
PY=""
if [[ -n "${CORTEX_PYTHON:-}" && -x "${CORTEX_PYTHON}" ]]; then
  PY="$CORTEX_PYTHON"
elif command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python3)"
fi

# ── 系统余量闸：可用 = vm_stat 的 free + inactive；是否收手只认系统压力等级。──
# top 的 PhysMem unused 只是完全空闲页，不含可立即回收的 inactive，不能当可用内存。
# swap 是滞后背景信号，也不能单独推断当前余量。具体解析与退出码由同目录脚本统一负责。
MEMORY_GATE_MOD="cortex_sentinel.memory"
PARSE="$INSTALL_ROOT/scripts/panel_summary.py"
GATE_JSON_FILE="$STASH_DIR/memory_pressure_gate.json"
GATE_ERR="$STASH_DIR/memory_pressure_gate.stderr"
: > "$GATE_JSON_FILE"
: > "$GATE_ERR"
gate_exit=3
available_gb="未知"
pressure_level=""
pressure_name="未知"
gate_fail_reason=""
if [[ -z "$PY" ]]; then
  gate_fail_reason="没找到可用的 python3"
elif [[ ! -f "$INSTALL_ROOT/cortex_sentinel/memory.py" ]]; then
  gate_fail_reason="$INSTALL_ROOT/cortex_sentinel/memory.py 不存在"
else
  # 常驻监控已有 mem_watch 负责进程榜；这里 --top 0 避免每轮重复跑一次 top。
  "$PY" -m "$MEMORY_GATE_MOD" --json --top 0 >"$GATE_JSON_FILE" 2>"$GATE_ERR"
  gate_exit=$?
  if [[ "$gate_exit" -gt 2 || ! -s "$GATE_JSON_FILE" ]]; then
    gate_fail_reason="余量闸没出可信 JSON (exit=${gate_exit})$( [[ -s "$GATE_ERR" ]] && printf '，stderr: %s' "$(head -c 300 "$GATE_ERR" | tr '\n' ' ')" )"
  else
    gate_parse_err="$STASH_DIR/memory_gate_parse.stderr"
    : > "$gate_parse_err"
    available_gb="$("$PY" "$PARSE" --json-file "$GATE_JSON_FILE" --field available_gb 2>>"$gate_parse_err" || true)"
    pressure_level="$("$PY" "$PARSE" --json-file "$GATE_JSON_FILE" --field pressure_level 2>>"$gate_parse_err" || true)"
    pressure_name="$("$PY" "$PARSE" --json-file "$GATE_JSON_FILE" --field pressure_name 2>>"$gate_parse_err" || true)"
    if [[ -z "$available_gb" || -z "$pressure_level" || -z "$pressure_name" ]]; then
      gate_fail_reason="余量闸 JSON 解析失败: $(sort -u "$gate_parse_err" | head -c 240 | tr '\n' ' ')"
      available_gb="未知"
      pressure_level=""
      pressure_name="未知"
    fi
  fi
fi

# ── 磁盘余量闸：可用认 df -kP Available；<20G 警告，<10G 危急并该拦住新并行派工。──
DISK_GATE_MOD="cortex_sentinel.disk"
DISK_JSON_FILE="$STASH_DIR/disk_pressure_gate.json"
DISK_ERR="$STASH_DIR/disk_pressure_gate.stderr"
: > "$DISK_JSON_FILE"
: > "$DISK_ERR"
disk_exit=3
disk_available_gb="未知"
disk_pressure_level=""
disk_pressure_name="未知"
disk_fail_reason=""
if [[ -z "$PY" ]]; then
  disk_fail_reason="没找到可用的 python3"
elif [[ ! -f "$INSTALL_ROOT/cortex_sentinel/disk.py" ]]; then
  disk_fail_reason="$INSTALL_ROOT/cortex_sentinel/disk.py 不存在"
else
  "$PY" -m "$DISK_GATE_MOD" --json --path "${HOME:-/}" >"$DISK_JSON_FILE" 2>"$DISK_ERR"
  disk_exit=$?
  if [[ "$disk_exit" -gt 2 || ! -s "$DISK_JSON_FILE" ]]; then
    disk_fail_reason="磁盘闸没出可信 JSON (exit=${disk_exit})$( [[ -s "$DISK_ERR" ]] && printf '，stderr: %s' "$(head -c 300 "$DISK_ERR" | tr '\n' ' ')" )"
  else
    disk_parse_err="$STASH_DIR/disk_gate_parse.stderr"
    : > "$disk_parse_err"
    disk_available_gb="$("$PY" "$PARSE" --json-file "$DISK_JSON_FILE" --field available_gb 2>>"$disk_parse_err" || true)"
    disk_pressure_level="$("$PY" "$PARSE" --json-file "$DISK_JSON_FILE" --field pressure_level 2>>"$disk_parse_err" || true)"
    disk_pressure_name="$("$PY" "$PARSE" --json-file "$DISK_JSON_FILE" --field pressure_name 2>>"$disk_parse_err" || true)"
    if [[ -z "$disk_available_gb" || -z "$disk_pressure_level" || -z "$disk_pressure_name" ]]; then
      disk_fail_reason="磁盘闸 JSON 解析失败: $(sort -u "$disk_parse_err" | head -c 240 | tr '\n' ' ')"
      disk_available_gb="未知"
      disk_pressure_level=""
      disk_pressure_name="未知"
    fi
  fi
fi

# ── 面板口径：App + 联动 + 已压缩。对不上 iStat 的旧公式（active+wired+compressed）丢掉了。──
#
# 2026-08-18：这一段原来把 mem_watch 的 stderr 丢进 /dev/null，失败原因永远看不到，
# 退化之后只在「当时大头」那一行留一句备注，总占用那个数字换了口径却一声不响。
# 静默降级比不监控更危险——它长得像在工作。现在：失败原因落盘、口径记成变量、
# 退化本身单独成为一条异常。
used_gb=""
top_eaters=""
panel_source="panel"          # panel = 面板口径；vm_stat-fallback / ps-fallback = 已退化
panel_fail_reason=""
MEM_WATCH_ERR="$STASH_DIR/mem_watch.stderr"
: > "$MEM_WATCH_ERR"
if [[ -z "$PY" ]]; then
  panel_fail_reason="没找到可用的 python3（CORTEX_PYTHON 和 PATH 里都没有）"
elif [[ ! -d "$INSTALL_ROOT/cortex_sentinel" ]]; then
  panel_fail_reason="$INSTALL_ROOT/cortex_sentinel 不存在"
fi
if [[ -n "$PY" && -d "$INSTALL_ROOT/cortex_sentinel" ]]; then
  PANEL_JSON_FILE="$STASH_DIR/mem_watch.json"
  "$PY" -m cortex_sentinel.memwatch --json > "$PANEL_JSON_FILE" 2>"$MEM_WATCH_ERR" || true
  if [[ ! -s "$PANEL_JSON_FILE" ]]; then
    panel_fail_reason="mem_watch.py 没出 JSON$( [[ -s "$MEM_WATCH_ERR" ]] && printf '，stderr: %s' "$(head -c 300 "$MEM_WATCH_ERR" | tr '\n' ' ')" )"
  else
    # 两段解析都走独立脚本，不再内嵌 python -c：原来内嵌那版因为 bash 单引号里给
    # f-string 的引号加了反斜杠，top_eaters 那段一直是 SyntaxError，而 SyntaxError
    # 是编译期的、外层 try/except 抓不到，stderr 又被丢掉，于是这一栏从没成功过。
    parse_err="$STASH_DIR/panel_parse.stderr"
    : > "$parse_err"
    used_gb="$("$PY" "$PARSE" --json-file "$PANEL_JSON_FILE" --field used_gb 2>>"$parse_err" || true)"
    top_eaters="$("$PY" "$PARSE" --json-file "$PANEL_JSON_FILE" --field top_eaters 2>>"$parse_err" || true)"
    if [[ -z "$used_gb" || -z "$top_eaters" ]] && [[ -s "$parse_err" ]]; then
      # 两个字段各调一次解析，同一句原因会写两遍，去重后再截断
      panel_fail_reason="面板 JSON 解析失败: $(sort -u "$parse_err" | head -c 240 | tr '\n' ' ')"
    fi
  fi
fi

if [[ -z "$used_gb" ]]; then
  # mem_watch 没出来才退回 vm_stat，避免监控整段哑掉。
  # 注意这是**另一个口径**（active+wired+compressed），跟面板/iStat 对不上，
  # 所以下面会把 panel_source 标成退化，并单独报一条异常。
  panel_source="vm_stat-fallback"
  [[ -n "$panel_fail_reason" ]] || panel_fail_reason="mem_watch 出了 JSON 但取不到 used_gb（解析脚本没报错也没给值）"
  vm="$(vm_stat 2>/dev/null || true)"
  page_size="$(printf '%s\n' "$vm" | awk '/page size of/ {for(i=1;i<=NF;i++) if($i=="of" && $(i+1) ~ /^[0-9]+$/){print $(i+1); exit}}')"
  get_pages() { printf '%s\n' "$vm" | awk -v k="$1" '$0 ~ k {gsub(/\./,"",$NF); print $NF; exit}'; }
  active="$(get_pages 'Pages active')"; active="${active:-0}"
  wired="$(get_pages 'Pages wired down')"; wired="${wired:-0}"
  compressed="$(get_pages 'occupied by compressor')"; compressed="${compressed:-0}"
  if [[ "$page_size" =~ ^[0-9]+$ && "$page_size" -gt 0 ]]; then
    used_gb="$(awk -v a="$active" -v w="$wired" -v c="$compressed" -v p="$page_size" \
      'BEGIN{printf "%.1f", (a+w+c)*p/1073741824}')"
  else
    used_gb="未知"
    panel_fail_reason="${panel_fail_reason}; vm_stat 没给动态页大小，拒绝猜 4096/16384"
  fi
fi
if [[ -z "$top_eaters" ]]; then
  # ps 的 RSS 看不见被压缩和换出的部分（实测一个报 130MB 的进程真实占 11GB，差 86 倍），
  # 所以这份兜底名单基本没有参考价值，只是不让这一栏空着。
  [[ "$panel_source" == "panel" ]] && panel_source="ps-fallback"
  [[ -n "$panel_fail_reason" ]] || panel_fail_reason="mem_watch 出了 JSON 但 apps 字段解析不出大头名单"
  top_eaters="(面板采样失败，退回 ps RSS，RSS 看不见压缩与换出，这份名单不可信) $(ps -Ao rss,comm -m 2>/dev/null | awk 'NR>1 && NR<=5 {printf "%.0fMB %s; ", $1/1024, $2}')"
fi

vm="$(vm_stat 2>/dev/null || true)"
swapouts="$(printf '%s\n' "$vm" | awk '/Swapouts/ {gsub(/\./,"",$NF); print $NF; exit}')"; swapouts="${swapouts:-0}"

# ── swap 仅做报告背景，不再单独触发「内存到顶」──
swap_line="$(sysctl -n vm.swapusage 2>/dev/null || true)"

# ── 残留 next dev：按真实占用收死的、孤儿的、长时间没人连的 ──
REAPER_MOD="cortex_sentinel.devserver"
reaper_note=""
if [[ -n "$PY" && -d "$INSTALL_ROOT/cortex_sentinel" ]]; then
  REAPER_ERR="$STASH_DIR/reaper.stderr"
  # 只看不收开关。默认真收（这条监控存在的意义就是自动收残留），
  # 但验这套告警文本的人必须能在不动任何进程的前提下跑一遍。
  # 2026-08-18 实踩：验「口径退化告警」时只隔离了产物落点、没隔离 reaper 的副作用，
  # 那一跑把 Falcon 常驻 Cortex 名下的 next-server 连带收掉，2427 界面直接打不开。
  # --apply 藏在脚本中段，从外面看不出来，所以这个开关不是方便而是必需。
  reaper_apply="--apply"
  if [[ -n "${CORTEX_HEALTH_REAPER_DRY_RUN:-}" || -n "$install_verify_dry_run" ]]; then
    reaper_apply=""
  fi
  reaper_json="$("$PY" -m "$REAPER_MOD" ${reaper_apply:+$reaper_apply} --json 2>"$REAPER_ERR" || true)"
  if [[ -z "$reaper_json" && -s "$REAPER_ERR" ]]; then
    reaper_note="收割器这一轮没出结果，stderr: $(head -c 200 "$REAPER_ERR" | tr '\n' ' ')"
  fi
  if [[ -n "$reaper_json" ]]; then
    reaper_note="$(printf '%s' "$reaper_json" | "$PY" -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if d.get("reaped"):
    print(f"收掉残留 dev server {d[\"reaped\"]} 个, 回收 {d[\"reclaimed_mb\"]:.0f}MB")
' 2>/dev/null || true)"
  fi
fi

# ── 并行线副本回收：合并完的 worktree / 过期 Multica 工作区 / 出包上一轮 / 闲置缓存 ──
# 跟 reaper 一样无条件跑，不是等磁盘到顶才收。干完不删才是盘满的根因。
RECLAIMER_MOD="cortex_sentinel.reclaim"
reclaim_note=""
if [[ -n "$PY" && -d "$INSTALL_ROOT/cortex_sentinel" ]]; then
  RECLAIM_ERR="$STASH_DIR/reclaimer.stderr"
  reclaim_apply="--apply"
  # 跟 reaper 共用隔离开关：验告警文本时不许顺手把工作树送进回收站。
  if [[ -n "${CORTEX_HEALTH_REAPER_DRY_RUN:-}" || -n "${CORTEX_HEALTH_RECLAIM_DRY_RUN:-}" || -n "$install_verify_dry_run" ]]; then
    reclaim_apply=""
  fi
  reclaim_heartbeat_args=()
  if [[ "$install_verify_state" == "skipped" ]]; then
    reclaim_heartbeat_args+=(--skip-reason install-verify-marker)
  elif [[ "$install_verify_state" == "applied-despite-recent-skip" ]]; then
    reclaim_heartbeat_args+=(--install-verify-state applied-despite-recent-skip)
  fi
  # launchd 入口是 /bin/bash 3.2。set -u 下空数组 "${arr[@]}" 会 unbound variable，
  # 子 shell 直接退出，回收器根本不会被调用，心跳也就停更。bash 5（PATH 里 brew
  # 那个）没有这个问题，所以只跑 PATH bash 的测试会绿、真机每 10 分钟却静默。
  # ${arr[@]+"${arr[@]}"}：空数组展开成零个参数，有内容才带上。
  reclaim_json="$("$PY" -m "$RECLAIMER_MOD" ${reclaim_apply:+$reclaim_apply} ${reclaim_heartbeat_args[@]+"${reclaim_heartbeat_args[@]}"} --json --home "${HOME:-}" 2>"$RECLAIM_ERR" || true)"
  if [[ -z "$reclaim_json" && -s "$RECLAIM_ERR" ]]; then
    reclaim_note="回收器这一轮没出结果，stderr: $(head -c 200 "$RECLAIM_ERR" | tr '\n' ' ')"
  fi
  if [[ -n "$reclaim_json" ]]; then
    reclaim_note="$(printf '%s' "$reclaim_json" | "$PY" -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
s = d.get("summary") or {}
n = int(s.get("trash") or 0)
a = int(s.get("alert") or 0)
if n or a:
    gb = float(s.get("reclaimed_bytes") or 0) / (1024**3)
    print(f"回收计划 trash={n} alert={a} ~{gb:.1f}G" + (" APPLIED" if d.get("applied") else " DRY-RUN"))
' 2>/dev/null || true)"
  fi
fi

# ── 可再生开发缓存：每 10 分钟经过一次，脚本内 7 天冷却，只在到期周清。──
CACHE_RECLAIMER="$INSTALL_ROOT/scripts/dev_cache_reclaimer.py"
cache_reclaim_note=""
if [[ -n "$PY" && -f "$CACHE_RECLAIMER" ]]; then
  CACHE_RECLAIM_ERR="$STASH_DIR/cache-reclaimer.stderr"
  cache_reclaim_apply="--apply"
  if [[ -n "${CORTEX_HEALTH_REAPER_DRY_RUN:-}" || -n "${CORTEX_HEALTH_CACHE_DRY_RUN:-}" || -n "$install_verify_dry_run" ]]; then
    cache_reclaim_apply=""
  fi
  cache_reclaim_json="$("$PY" "$CACHE_RECLAIMER" ${cache_reclaim_apply:+$cache_reclaim_apply} --json --home "${HOME:-}" --state "$HEALTH_DIR/.dev-cache-reclaimer-state.json" 2>"$CACHE_RECLAIM_ERR" || true)"
  if [[ -z "$cache_reclaim_json" && -s "$CACHE_RECLAIM_ERR" ]]; then
    cache_reclaim_note="开发缓存周清理没出结果，stderr: $(head -c 200 "$CACHE_RECLAIM_ERR" | tr '\n' ' ')"
  fi
  if [[ -n "$cache_reclaim_json" ]]; then
    cache_reclaim_note="$(printf '%s' "$cache_reclaim_json" | "$PY" -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
n = int(d.get("moved") or 0)
if n:
    gb = float(d.get("moved_bytes") or 0) / (1024**3)
    print(f"开发缓存周清理 moved={n} ~{gb:.1f}G")
' 2>/dev/null || true)"
  fi
fi

# ── 异常判定（每条带 key，冷却按类独立算）──
anomalies=()
anomaly_keys=()
# 口径退化自己就是一条异常。不这么写的话，总占用那个数字会悄悄换成另一个口径，
# 报告看起来照常在工作，趋势对比却已经在拿两把尺子量。
if [[ "$panel_source" != "panel" ]]; then
  anomalies+=("内存口径退化: 本次总占用与大头名单不是面板口径而是 ${panel_source}，数字跟活动监视器/iStat 对不上、也不能跟历史条目比。原因: ${panel_fail_reason:-未知}")
  anomaly_keys+=("panel_degraded")
fi
if [[ -n "$gate_fail_reason" ]]; then
  anomalies+=("内存余量闸退化: ${gate_fail_reason}")
  anomaly_keys+=("pressure_gate_degraded")
elif [[ "$pressure_level" == "2" ]]; then
  anomalies+=("内存压力警告: 系统等级=2，可用=${available_gb}G；应停止增加负载并检查大头。${reaper_note}")
  anomaly_keys+=("pressure_warning")
elif [[ "$pressure_level" == "4" ]]; then
  anomalies+=("内存压力危急: 系统等级=4，可用=${available_gb}G；应立即收敛负载。${reaper_note}")
  anomaly_keys+=("pressure_critical")
fi
if [[ -n "$disk_fail_reason" ]]; then
  anomalies+=("磁盘余量闸退化: ${disk_fail_reason}")
  anomaly_keys+=("disk_gate_degraded")
elif [[ "$disk_pressure_level" == "2" ]]; then
  anomalies+=("磁盘压力警告: 可用=${disk_available_gb}G，已低于 20G。${reclaim_note}")
  anomaly_keys+=("disk_warning")
elif [[ "$disk_pressure_level" == "4" ]]; then
  anomalies+=("磁盘压力危急: 可用=${disk_available_gb}G，已低于 10G；新并行派工应被拦住。${reclaim_note}")
  anomaly_keys+=("disk_critical")
fi
all_ps="$(ps -Ao rss,command 2>/dev/null || true)"
for entry in "${PROC_CAPS[@]}"; do
  pat="${entry%%:*}"; cap="${entry##*:}"
  rss_mb="$(printf '%s' "$all_ps" | grep -F "$pat" | grep -v grep | awk '{s+=$1} END{printf "%.0f", s/1024}')"
  rss_mb="${rss_mb:-0}"
  if [[ "$rss_mb" -gt "$cap" ]]; then
    anomalies+=("进程失控: ${pat} 占 ${rss_mb}MB (上限${cap}MB, 越占越多嫌疑)")
    anomaly_keys+=("proc_$(printf '%s' "$pat" | tr -c 'a-zA-Z0-9' '_')")
  fi
done

get_state_key() { awk -F= -v k="$1" '$1==k{print $2; exit}' "$STATE_FILE" 2>/dev/null; }
to_record=()
recorded_keys=()
if [[ ${#anomalies[@]} -gt 0 ]]; then
  for i in "${!anomalies[@]}"; do
    key="${anomaly_keys[$i]}"
    last="$(get_state_key "last_anomaly_epoch_${key}")"; last="${last:-0}"
    if [[ $((now_epoch - last)) -ge "$COOLDOWN_SECONDS" ]]; then
      to_record+=("${anomalies[$i]}")
      recorded_keys+=("$key")
    fi
  done
fi

if [[ ${#to_record[@]} -gt 0 ]]; then
    if [[ ! -f "$ANOMALY_DOC" ]]; then
      cat > "$ANOMALY_DOC" <<'HDR'
# Cortex 内存异常记录

> 监控每 10 分钟采样一次。系统内存压力告警或危急 / Cortex 进程失控时记一条，攒在这里。
> **不用马上处理**，到点（默认 3 天）有未处理的我会弹通知提醒你一起看。
> 处理完把对应条目从「待处理」剪到「已处理」或删掉即可。
> 设计与排查方法见 docs/reference/cortex-runtime-health-guard.md。

## 待处理

## 已处理
HDR
    fi
    entry="$STASH_DIR/anomaly-entry.$$"
    {
      echo "- **${now_human}** | available ${available_gb}G · pressure ${pressure_level:-未知}/${pressure_name} · disk ${disk_available_gb}G/${disk_pressure_name:-未知} · used ${used_gb}G/${total_mem_gb}G [口径=${panel_source}] · swapout ${swapouts} · ${swap_line:-swap 未取到} | $(printf '%s; ' "${to_record[@]}")"
      echo "  - 当时大头: ${top_eaters}"
    } > "$entry"
    awk -v f="$entry" '
      {print}
      /^## 待处理[[:space:]]*$/ && !done {while((getline line < f)>0) print line; done=1}
    ' "$ANOMALY_DOC" > "$ANOMALY_DOC.tmp" && mv "$ANOMALY_DOC.tmp" "$ANOMALY_DOC"
    mv "$entry" "$STASH_DIR/anomaly-entry.$$.done" 2>/dev/null || true
    {
      for key in "${recorded_keys[@]}"; do printf 'last_anomaly_epoch_%s=%s\n' "$key" "$now_epoch"; done
      if [[ -f "$STATE_FILE" ]]; then
        awk -F= -v ks=" $(printf '%s ' "${recorded_keys[@]}")" '
          $1 == "last_anomaly_epoch" { next }
          /^last_anomaly_epoch_/ { k=substr($1,20); if (index(ks, " " k " ") > 0) next }
          { print }
        ' "$STATE_FILE"
      fi
    } > "$STATE_FILE.new"
    mv "$STATE_FILE.new" "$STATE_FILE"
fi

# 后台常驻任务健康快照：给哨兵栏看。失败不许拖垮本轮监控。
JOBS_HEALTH="$INSTALL_ROOT/scripts/background_jobs_health.py"
if [[ -n "$PY" && -f "$JOBS_HEALTH" ]]; then
  "$PY" "$JOBS_HEALTH" --write >/dev/null 2>>"$STASH_DIR/background-jobs-health.stderr" || true
fi
OVERVIEW="$INSTALL_ROOT/scripts/automation_overview.py"
if [[ -n "$PY" && -f "$OVERVIEW" ]]; then
  "$PY" "$OVERVIEW" --write >/dev/null 2>>"$STASH_DIR/automation-overview.stderr" || true
fi

pending_count=0
if [[ -f "$ANOMALY_DOC" ]]; then
  pending_count="$(awk '/^## 待处理/{f=1;next} /^## 已处理/{f=0} f && /^- /{c++} END{print c+0}' "$ANOMALY_DOC")"
fi
last_remind_epoch=0
[[ -f "$STATE_FILE" ]] && last_remind_epoch="$(awk -F= '/^last_remind_epoch=/{print $2}' "$STATE_FILE" 2>/dev/null || echo 0)"
last_remind_epoch="${last_remind_epoch:-0}"

if [[ "$pending_count" -gt 0 && $((now_epoch - last_remind_epoch)) -ge "$REMIND_INTERVAL_SECONDS" ]]; then
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"攒了 ${pending_count} 条内存异常，有空一起看：$ANOMALY_DOC\" with title \"Cortex 内存监控\" sound name \"\"" >/dev/null 2>&1 || true
  fi
  {
    if [[ -f "$STATE_FILE" ]]; then
      awk -F= '$1 != "last_remind_epoch" { print }' "$STATE_FILE"
    fi
    printf 'last_remind_epoch=%s\n' "$now_epoch"
  } > "$STATE_FILE.new"
  mv "$STATE_FILE.new" "$STATE_FILE"
fi

if [[ -n "$install_verify_state" && -f "$INSTALL_VERIFY_MARKER" ]]; then
  mv "$INSTALL_VERIFY_MARKER" "$HEALTH_DIR/install-verify-dry-run.used.$(date +%Y%m%d%H%M%S).$$"
fi
if [[ "$install_verify_state" == "skipped" ]]; then
  {
    if [[ -f "$STATE_FILE" ]]; then
      awk -F= '$1 != "last_install_verify_skip_epoch" { print }' "$STATE_FILE"
    fi
    printf 'last_install_verify_skip_epoch=%s\n' "$now_epoch"
  } > "$STATE_FILE.new"
  mv "$STATE_FILE.new" "$STATE_FILE"
fi

exit 0
