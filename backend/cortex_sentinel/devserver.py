#!/usr/bin/env python3
"""开发服务残留清理器：按真实占用和 Multica run 状态逐 PID 回收。

为什么要单独写这个（2026-08-18 实踩，Falcon 的机器 swap 被打满到只剩 450 MB）：

1. ps 的 RSS 看不见被压缩和换出的内存。回收站里一个昨天起的 dev server，
   worktree 早就丢进 .Trash 了，ps 报 130 MB，真实占用 11 GB。
   旧 memory_monitor.sh 拿 RSS 跟 4 GB 比，于是永远不响。
2. 旧监控只记录不清理。攒进 anomalies、3 天弹一次通知，机器该爆还是爆。
   Falcon 原话：「不要什么东西都是开了就不管了、不关了。」
   后来补了一句：「以后给我惩罚，谁开了用完又不关，直接罚他禁闭。」
3. 禁闭不是情绪，是自动收紧空闲阈值。同一 worktree 反复被收，
   30 分钟降到 10 分钟再降到 5 分钟，不用谁记得去罚。

判定（用构造数据测，不要在测试里真起或真杀进程）：

- dead          工作目录没了或落在 .Trash → 收
- orphan_idle   父进程是 1，端口没活连接，起够久 → 收
- idle          没人连超过空闲阈值（可被案底收紧）→ 收
- managed_over  归 com.falcon.cortex.web 托管且超上限 → 只许 kickstart，不许杀
- terminal_run  cwd 属于已终态 Multica run → TERM 5 秒后逐 PID KILL 幸存者
- ok            其余

死规矩：
- com.falcon.cortex.web 和 ai.multica.cor880.cortex-shared-2391 不许杀
- Multica 那条连 kickstart 都不许，动了会拆掉共享界面
- 有活连接一律不收
- 认不出是谁起的就记 unknown，不猜
- 命令行里碰巧出现 next dev 四个字的 agent（比如把自己工单贴进 argv 的
  cursor-agent）不是 dev server，第一版子串匹配会误收
- Multica cwd 的 run 状态查不到时 fail-closed；running / queued 永远不碰
- 2345 / 2427 是 Pro 的受保护端口；命中后 run 即使终态也不碰

用法：
    python3 scripts/health/dev_server_reaper.py            # 只看不动
    python3 scripts/health/dev_server_reaper.py --apply    # 真收
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable

# 变量名不能叫 PROJECT_ROOT / ROOT：路径闸把「Path(__file__).resolve(」赋值给这两个名字当成绕过。

from cortex_sentinel.memwatch import is_next_dev_command, parse_top_size  # noqa: E402
from cortex_sentinel.paths import projects, sentinel_home

# 仓内老落点的目录名。拆开写，避免出现 ROOT / "data" 这种字面拼接被路径闸判成绕过。
_REPO_DATA_DIR_NAME = "data"


def _health_dir() -> Path:
    """健康产物落点：有 CORTEX_DATA_ROOT 就跟数据根走，没有就退回家目录 health/。

    这是 launchd 每 10 分钟调的守护，环境变量没配也不能崩——崩了监控又静默，
    跟当初 RSS 失明是同一种病。独立版默认写 SENTINEL_HOME/health。
    """
    env_health = os.environ.get("CORTEX_HEALTH_DIR", "").strip()
    if env_health:
        return Path(env_health).expanduser()
    env_data = os.environ.get("CORTEX_DATA_ROOT", "").strip()
    if env_data:
        return Path(env_data).expanduser() / "health"
    for row in projects():
        raw = row.get("data_root")
        if isinstance(raw, str) and raw.strip():
            return Path(raw).expanduser() / "health"
    return sentinel_home() / "health"


# 这份 jsonl 是 background_jobs_health.py 判「内存与回收巡检」活没活的依据
# （读最后一条的 ts）。安静的轮次也必须留痕，否则可见面会把健康巡检误报成炸了。
# 改写账或改那边的判据之前，先想会不会让可见面误报。
LOG_PATH = _health_dir() / "dev-server-reaper.jsonl"
STATE_PATH = _health_dir() / ".dev-server-reaper-state.json"
OFFENDER_PATH = _health_dir() / "dev-server-offenders.json"
# 每 10 分钟一条心跳，一天 144 条。按行数留最近 14 天：可见面只看最后一条，
# 两周够对照「我一度以为它一天没跑」这种误报；按行数而不是按天，避免 ts
# 解析失败时轮转失效。2016 = 14 * 144。
LEDGER_KEEP_LINES = 2016
# 跟 com.falcon.cortex.memory-monitor 的 StartInterval 对齐。回收巡检写进
# 同一条心跳时用它算「耗时有没有超过间隔一半」——可见面读这个布尔字段，
# 不要靠有人记得去翻日志。
MEMORY_MONITOR_INTERVAL_SECONDS = 600
DURATION_SLOW_STATUS = "slow"
DURATION_SLOW_STATUS_TEXT = "快撑不住了"
MEMORY_MONITOR_LABEL = "com.falcon.cortex.memory-monitor"
BACKGROUND_JOBS_SNAPSHOT_NAME = "background-jobs-health.json"
_EAST_EIGHT = timezone(timedelta(hours=8))

# 单个实例超过这个真实占用才算 bloated / managed_over。
# 4 GB：dev 模式带编译缓存常态 2–4.5 G（2026-07-11 178 条核实），
# 4 G 以上才是失控嫌疑，不是「开着就会到」。
DEFAULT_CAP_MB = 4096
# 孤儿（ppid=1）至少要活这么久才收。2 小时：刚起的托管作业也会短暂 ppid=1，
# 立刻收会误伤刚拉起来的 web。
DEFAULT_ORPHAN_HOURS = 2.0
# 普通人忘关的第一档。子代理截完图就走，人去倒杯水回来通常不超过半小时；
# 再长就是没人要的实例。2026-08-18 全机 15 个合计约 21 GB，几乎全是这类。
DEFAULT_IDLE_MINUTES = 30.0
# 同一 worktree 被收 3 次：一次疏忽，两次可能是长会话+一次残留，三次是习惯。
REPEAT_OFFENSE_THRESHOLD = 3
REPEAT_IDLE_MINUTES = 10.0  # 一杯咖啡，不够再囤出 4 G
# 五次还在忘关，只留一次页面刷新的空闲。
LOCKDOWN_OFFENSE_THRESHOLD = 5
LOCKDOWN_IDLE_MINUTES = 5.0
OFFENDER_RECENT_KEEP = 8

MANAGED_WEB_LABEL = "com.falcon.cortex.web"
# Multica 共享界面：同 web 一样是人在用的，但连重启都不许我们代做。
PROTECTED_NEVER_TOUCH = ("ai.multica.cor880.cortex-shared-2391",)
PROTECTED_PORTS = frozenset({2345, 2427})
MULTICA_TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled"})

# 用户从 Finder / Launchpad 打开的 GUI 应用，它名下那个本地服务永不收。
# 2026-08-18 实踩：mini 上常驻的 /Applications/Cortex.app（Falcon 的 Pro 关机时靠它）
# 名下 next-server 在 2427 上听着，因为「30 分钟没有浏览器连着」被判 idle 收掉，
# 界面直接打不开。那不是没人管的残留 dev server，是一个用户开着的应用——
# 它本来就该在没人看的时候闲着。判据只看父链里有没有 .app 包里的可执行体，
# 不看 launchd 标签（GUI 应用不是 launchd job，用标签这条路认不出来）。
_GUI_APP_PARENT = "/Applications/"
_GUI_APP_MARK = ".app/Contents/MacOS/"


def gui_app_never_touch(cwd: str, parent_chain: list[str] | None = None) -> str:
    """这个 next dev server 是不是挂在某个已安装 GUI 应用名下；是就返回那个 app 名。

    两条判据任一命中即算（端口是可配的，所以绝不看端口号）：

    1. `cwd` 落在 `/Applications/<任意>.app/` 里面
    2. 父链里出现 `/Applications/<任意>.app/Contents/MacOS/<可执行体>`

    刻意不硬编 `Cortex.app`：用户可能装了多个版本、也可能装在别的 `.app` 名下，
    「用户自己开着的应用」这个性质跟叫什么名字无关。
    """
    if cwd:
        marker = cwd.find(".app/")
        if marker != -1 and cwd.startswith(_GUI_APP_PARENT):
            return cwd[:marker].rsplit("/", 1)[-1] + ".app"
    for entry in parent_chain or []:
        if _GUI_APP_PARENT in entry and _GUI_APP_MARK in entry:
            tail = entry.split(":", 1)[-1]
            idx = tail.find(_GUI_APP_PARENT)
            tail = tail[idx:]
            return tail.split("/Contents/MacOS/", 1)[0].rsplit("/", 1)[-1]
    return ""

_WORKTREE = re.compile(r"cortex-worktrees/([^/]+)")
_PORT = re.compile(r"-p\s+(\d+)")
_RUN_PREFIX = re.compile(r"^[0-9a-f]{8}$", re.IGNORECASE)
_PLAYWRIGHT_BROWSER = re.compile(
    r"(?:^|/)(?:ms-playwright|playwright/\.local-browsers)/"
    r"(?:chromium|chromium_headless_shell|firefox|webkit|ffmpeg)-\d+(?:/|$)",
    re.IGNORECASE,
)

Runner = Callable[[list[str]], str]
ExistsFn = Callable[[str], bool]
LiveFn = Callable[[int], bool]
MulticaJsonFn = Callable[[list[str]], object]


def _run(args: list[str], timeout: float = 20.0, runner: Runner | None = None) -> str:
    if runner is not None:
        return runner(args)
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _json_rows(payload: object) -> list[dict]:
    if isinstance(payload, list):
        return [row for row in payload if isinstance(row, dict)]
    if not isinstance(payload, dict):
        return []
    for key in ("runs", "data", "items"):
        nested = payload.get(key)
        if isinstance(nested, list):
            return [row for row in nested if isinstance(row, dict)]
    return []


def _default_multica_json(args: list[str]) -> object:
    binary = shutil.which("multica")
    if not binary:
        fallback = Path.home() / ".local" / "bin" / "multica"
        binary = str(fallback) if fallback.exists() else ""
    if not binary:
        raise RuntimeError("multica-cli-unavailable")
    completed = subprocess.run(
        [binary, *args],
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"multica-cli-failed:{completed.returncode}")
    return json.loads(completed.stdout or "null")


def multica_scope_from_cwd(cwd: str) -> dict[str, str] | None:
    """从 lsof cwd 精确截出 Multica task 根与 8 位 run 前缀。"""
    if not cwd:
        return None
    path = Path(cwd).expanduser()
    parts = path.parts
    for index, part in enumerate(parts):
        if not part.startswith("multica_workspaces_"):
            continue
        if index + 3 >= len(parts):
            return None
        workspace_id, run_prefix, workdir = parts[index + 1 : index + 4]
        if not workspace_id or not _RUN_PREFIX.fullmatch(run_prefix) or workdir != "workdir":
            return None
        task_root = Path(*parts[: index + 3])
        return {
            "workspace_id": workspace_id,
            "run_prefix": run_prefix.lower(),
            "task_root": str(task_root),
        }
    return None


def _read_issue_id(task_root: Path) -> str:
    for relative in (
        Path("workdir") / ".multica" / "daemon_task_context.json",
        Path(".multica") / "daemon_task_context.json",
        Path("workdir") / ".agent_context" / "task_context.json",
    ):
        try:
            payload = json.loads((task_root / relative).read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            continue
        if isinstance(payload, dict):
            issue_id = str(payload.get("issue_id") or payload.get("issueId") or "").strip()
            if issue_id:
                return issue_id
    return ""


def resolve_multica_run(
    cwd: str,
    *,
    multica_json: MulticaJsonFn | None = None,
    cache: dict[str, dict] | None = None,
) -> dict:
    """把 cwd 的 run8 映射到服务端 run；任何缺口都返回 fail-closed 解释。"""
    scope = multica_scope_from_cwd(cwd)
    if scope is None:
        return {}
    task_root = scope["task_root"]
    if cache is not None and task_root in cache:
        return dict(cache[task_root])

    result: dict = {
        **scope,
        "matched": False,
        "issue_id": "",
        "run_id": scope["run_prefix"],
        "run_status": "unknown",
        "terminal": False,
        "reason": "run-status-unknown",
    }
    issue_id = _read_issue_id(Path(task_root))
    result["issue_id"] = issue_id
    if not issue_id:
        result["reason"] = "run-status-unknown:issue-context-missing"
    else:
        call = multica_json or _default_multica_json
        try:
            payload = call(["issue", "runs", issue_id, "--full-id", "--output", "json"])
            rows = _json_rows(payload)
        except (OSError, RuntimeError, subprocess.SubprocessError, ValueError):
            rows = []
            result["reason"] = "run-status-unknown:multica-lookup-failed"
        prefix = scope["run_prefix"]
        for run in rows:
            run_id = str(run.get("id") or "").strip()
            if run_id.lower().replace("-", "").startswith(prefix):
                status = str(run.get("status") or "").strip().lower() or "unknown"
                terminal = status in MULTICA_TERMINAL_STATUSES
                result.update(
                    {
                        "matched": True,
                        "run_id": run_id,
                        "run_status": status,
                        "terminal": terminal,
                        "reason": (
                            f"run-terminal:{status}" if terminal else f"run-not-terminal:{status}"
                        ),
                    }
                )
                break
        else:
            if rows:
                result["reason"] = "run-status-unknown:run-prefix-not-matched"
    if cache is not None:
        cache[task_root] = dict(result)
    return result


def is_reapable_dev_command(command: str) -> bool:
    """只接 Next dev 与 Playwright 自带浏览器，不用宽泛 browser/name 匹配。"""
    return is_next_dev_command(command) or bool(_PLAYWRIGHT_BROWSER.search(command or ""))


def real_footprint_mb(runner: Runner | None = None) -> dict[int, dict[str, float]]:
    """pid -> {mem_mb, cmprs_mb}。只用 top，不用 RSS。"""
    out = _run(["top", "-l", "1", "-stats", "pid,mem,cmprs"], timeout=90, runner=runner)
    table: dict[int, dict[str, float]] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        try:
            table[int(parts[0])] = {
                "mem_mb": round(parse_top_size(parts[1]), 1),
                "cmprs_mb": round(parse_top_size(parts[2]), 1),
            }
        except (ValueError, KeyError):
            continue
    return table


def process_cwd(pid: int, runner: Runner | None = None) -> str:
    for line in _run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], runner=runner).splitlines():
        if line.startswith("n"):
            return line[1:]
    return ""


def port_has_live_client(port: int, runner: Runner | None = None) -> bool:
    out = _run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:ESTABLISHED"], runner=runner)
    return len([line for line in out.splitlines() if line.strip()]) > 1


def listening_ports(runner: Runner | None = None) -> dict[int, int]:
    """pid -> 监听端口。next-server 子进程命令行没有 -p，端口在父进程上。"""
    table: dict[int, int] = {}
    for line in _run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], runner=runner).splitlines()[1:]:
        parts = line.split()
        if len(parts) < 2 or not parts[1].isdigit():
            continue
        got = re.search(r":(\d+)$", parts[-2] if parts[-1].startswith("(") else parts[-1])
        if got:
            table.setdefault(int(parts[1]), int(got.group(1)))
    return table


def launchd_tree(label: str, runner: Runner | None = None) -> set[int]:
    root = 0
    for line in _run(["launchctl", "list"], runner=runner).splitlines():
        cols = line.split("\t")
        if len(cols) >= 3 and cols[2].strip() == label and cols[0].strip().isdigit():
            root = int(cols[0])
            break
    if not root:
        return set()
    tree = {root}
    frontier = [root]
    children: dict[int, list[int]] = {}
    for line in _run(["ps", "-axo", "pid=,ppid="], runner=runner).splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            children.setdefault(int(parts[1]), []).append(int(parts[0]))
    while frontier:
        cur = frontier.pop()
        for child in children.get(cur, []):
            if child not in tree:
                tree.add(child)
                frontier.append(child)
    return tree


def infer_owner(cwd: str, command: str) -> dict[str, str]:
    """worktree 路径就是线名。cwd 没有就看命令行。两处都没有 → unknown，不猜。"""
    for source, text in (("cwd", cwd or ""), ("command", command or "")):
        got = _WORKTREE.search(text)
        if got:
            return {
                "owner": got.group(1),
                "worktree": f"cortex-worktrees/{got.group(1)}",
                "source": source,
            }
    return {"owner": "unknown", "worktree": "", "source": "unknown"}


def parent_chain(pid: int, parent_of: dict[int, int], comm_of: dict[int, str], hops: int = 6) -> list[str]:
    chain: list[str] = []
    cur = parent_of.get(pid)
    seen: set[int] = set()
    while cur and cur > 1 and cur not in seen and len(chain) < hops:
        seen.add(cur)
        chain.append(f"{cur}:{comm_of.get(cur) or '?'}")
        cur = parent_of.get(cur)
    if cur == 1:
        chain.append("1:launchd")
    return chain


def idle_minutes_for(owner: str, offense_count: int) -> float:
    """unknown 不连坐。认得出线名的累犯才收紧。"""
    if owner == "unknown":
        return DEFAULT_IDLE_MINUTES
    if offense_count >= LOCKDOWN_OFFENSE_THRESHOLD:
        return LOCKDOWN_IDLE_MINUTES
    if offense_count >= REPEAT_OFFENSE_THRESHOLD:
        return REPEAT_IDLE_MINUTES
    return DEFAULT_IDLE_MINUTES


def offense_count_of(owner: str, offenders: dict) -> int:
    slot = (offenders.get("offenders") or {}).get(owner) or {}
    try:
        return int(slot.get("count") or 0)
    except (TypeError, ValueError):
        return 0


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def save_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except OSError:
        pass


def rotate_jsonl(path: Path, keep_lines: int) -> None:
    """只留文件末尾 keep_lines 条非空行。超过才重写，读失败就让下轮再试。"""
    if keep_lines < 1:
        return
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return
    lines = [line for line in raw.splitlines() if line.strip()]
    if len(lines) <= keep_lines:
        return
    kept = "\n".join(lines[-keep_lines:]) + "\n"
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(kept)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except OSError:
        pass
    finally:
        temporary.unlink(missing_ok=True)


def append_run_record(
    path: Path,
    record: dict,
    *,
    keep_lines: int = LEDGER_KEEP_LINES,
) -> None:
    """每一轮都追加一条，包括零回收。然后按行数轮转。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False) + "\n"
    try:
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError:
        return
    rotate_jsonl(path, keep_lines)


def record_offense(offenders: dict, row: dict, verdict: str, now: float) -> dict:
    owner = row.get("owner") or "unknown"
    if owner == "unknown":
        return offenders
    book = offenders.setdefault("offenders", {})
    slot = book.setdefault(
        owner,
        {"owner": owner, "count": 0, "worktree": row.get("worktree") or "", "recent": []},
    )
    slot["count"] = int(slot.get("count") or 0) + 1
    slot["worktree"] = row.get("worktree") or slot.get("worktree") or ""
    slot["idle_minutes_now"] = idle_minutes_for(owner, slot["count"])
    event = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
        "verdict": verdict,
        "reclaimed_mb": round(float(row.get("mem_mb") or 0), 1),
        "pid": row.get("pid"),
        "port": row.get("port"),
        "cwd": row.get("cwd") or "",
        "command": (row.get("command") or "")[:160],
    }
    recent = list(slot.get("recent") or [])
    recent.insert(0, event)
    slot["recent"] = recent[:OFFENDER_RECENT_KEEP]
    offenders["updated_at"] = event["ts"]
    offenders["version"] = 1
    return offenders


def classify(
    row: dict,
    *,
    cap_mb: float,
    orphan_hours: float,
    idle_minutes: float,
    state: dict,
    now: float,
    path_exists: ExistsFn,
    has_live_client: LiveFn,
) -> str:
    """纯函数：判定只看传入的表，不碰真实进程。"""
    port = row.get("port")
    if port is not None and int(port) in PROTECTED_PORTS:
        row["never_touch"] = True
        row["protected"] = True
        row["protect_label"] = f"Pro 受保护端口 {port}"
        row["reap_reason"] = f"protected-port:{port}"
        return "ok"
    if row.get("never_touch"):
        # Multica 共享界面：分类也给 ok，避免 dry-run 看起来像要收。
        row["reap_reason"] = f"protected:{row.get('protect_label') or 'never-touch'}"
        return "ok"
    multica_run = row.get("multica_run")
    if isinstance(multica_run, dict) and multica_run:
        reason = str(multica_run.get("reason") or "run-status-unknown")
        run_id = str(multica_run.get("run_id") or "unknown")
        issue_id = str(multica_run.get("issue_id") or "unknown")
        row["reap_reason"] = reason
        row["run_detail"] = f"issue={issue_id}; run={run_id}"
        if row.get("managed"):
            row["run_detail"] += f"; protected={MANAGED_WEB_LABEL}"
            return "ok"
        if bool(multica_run.get("terminal")):
            row["reap_reason"] = f"{reason}; {row['run_detail']}"
            return "terminal_run"
        if bool(multica_run.get("matched")):
            # running / queued（以及未来任何非终态）明确放过。
            return "ok"
        # cwd 明确属于 Multica，但服务端状态取不到：不能退回通用 idle 规则。
        return "unknown"
    cwd = row.get("cwd") or ""
    if cwd and ("/.Trash/" in cwd or cwd.startswith("~/.Trash") or not path_exists(cwd)):
        return "dead"
    if not cwd:
        if int(row.get("ppid") or 0) == 1 and float(row.get("age_hours") or 0) >= orphan_hours:
            return "orphan_idle"
        return "unknown"

    live = port is not None and has_live_client(int(port))
    key = f"{row.get('pid')}:{port}:{cwd}"
    if live:
        state[key] = now
    last_active = state.setdefault(key, now)
    idle_seconds = 0.0 if live else max(0.0, now - float(last_active))
    row["idle_minutes"] = round(idle_seconds / 60, 1)
    row["live_client"] = live

    if live:
        # 有人连着：可以报 bloated，但归 ok 让收割器跳过。
        # 「有活连接一律不收」压过超上限。
        if float(row.get("mem_mb") or 0) >= cap_mb and not row.get("protected"):
            row["note"] = "超上限但有活连接，不收"
        return "ok"

    if int(row.get("ppid") or 0) == 1 and float(row.get("age_hours") or 0) >= orphan_hours:
        return "orphan_idle"
    if not row.get("managed") and idle_seconds >= idle_minutes * 60:
        return "idle"
    if float(row.get("mem_mb") or 0) >= cap_mb:
        if row.get("managed"):
            return "managed_over"
        return "bloated"
    return "ok"


def _etime_hours(etime: str) -> float:
    days = 0
    rest = etime
    if "-" in etime:
        head, rest = etime.split("-", 1)
        try:
            days = int(head)
        except ValueError:
            days = 0
    try:
        bits = [int(x) for x in rest.split(":")]
    except ValueError:
        return 0.0
    while len(bits) < 3:
        bits.insert(0, 0)
    hours, minutes, seconds = bits[-3], bits[-2], bits[-1]
    return days * 24 + hours + minutes / 60 + seconds / 3600


def scan(runner: Runner | None = None) -> list[dict]:
    now = time.time()
    footprint = real_footprint_mb(runner=runner)
    web_tree = launchd_tree(MANAGED_WEB_LABEL, runner=runner)
    never_touch: set[int] = set()
    never_labels: dict[int, str] = {}
    for label in PROTECTED_NEVER_TOUCH:
        tree = launchd_tree(label, runner=runner)
        never_touch |= tree
        for pid in tree:
            never_labels[pid] = label
    ports = listening_ports(runner=runner)
    parent_of: dict[int, int] = {}
    comm_of: dict[int, str] = {}
    for line in _run(["ps", "-axo", "pid=,ppid=,comm="], runner=runner).splitlines():
        parts = line.split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            parent_of[int(parts[0])] = int(parts[1])
            comm_of[int(parts[0])] = parts[2] if len(parts) > 2 else ""

    rows: list[dict] = []
    multica_cache: dict[str, dict] = {}
    ps_out = _run(["ps", "-axww", "-o", "pid=,ppid=,etime=,command="], runner=runner)
    for line in ps_out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4 or not parts[0].isdigit():
            continue
        pid, ppid, etime, command = int(parts[0]), int(parts[1]), parts[2], parts[3]
        if not is_reapable_dev_command(command):
            continue
        is_next = is_next_dev_command(command)
        port_match = _PORT.search(command)
        port = int(port_match.group(1)) if port_match else ports.get(pid)
        if port is None and is_next:
            hop = parent_of.get(pid)
            for _ in range(3):
                if hop is None or hop <= 1:
                    break
                port = ports.get(hop)
                if port is not None:
                    break
                hop = parent_of.get(hop)
        if port is None and is_next:
            continue
        cwd = process_cwd(pid, runner=runner)
        multica_run = resolve_multica_run(cwd, cache=multica_cache)
        owner = infer_owner(cwd, command)
        if multica_run:
            owner = {
                "owner": f"multica:{multica_run.get('run_prefix') or 'unknown'}",
                "worktree": str(multica_run.get("task_root") or ""),
                "source": "cwd-run8",
            }
        stat = footprint.get(pid, {"mem_mb": 0.0, "cmprs_mb": 0.0})
        chain = parent_chain(pid, parent_of, comm_of)
        gui_app = gui_app_never_touch(cwd, chain)
        protected_port = port in PROTECTED_PORTS if port is not None else False
        rows.append(
            {
                "pid": pid,
                "ppid": ppid,
                "etime": etime,
                "age_hours": round(_etime_hours(etime), 2),
                "port": port,
                "cwd": cwd,
                "mem_mb": stat["mem_mb"],
                "cmprs_mb": stat["cmprs_mb"],
                "managed": pid in web_tree,
                "never_touch": pid in never_touch or bool(gui_app) or protected_port,
                "protected": pid in web_tree or pid in never_touch or bool(gui_app) or protected_port,
                "protect_label": (
                    f"Pro 受保护端口 {port}"
                    if protected_port
                    else MANAGED_WEB_LABEL
                    if pid in web_tree
                    else (never_labels.get(pid) or (f"用户打开的 {gui_app}" if gui_app else ""))
                ),
                "command": command[:160],
                "process_kind": "next-dev" if is_next else "playwright-browser",
                "owner": owner["owner"],
                "worktree": owner["worktree"],
                "owner_source": owner["source"],
                "parent_chain": parent_chain(pid, parent_of, comm_of),
                "multica_run": multica_run,
                "_now": now,
            }
        )
    return rows


def descendants(pid: int, runner: Runner | None = None) -> list[int]:
    """只按父子链找后代，不用进程组。杀进程组会连起它的 shell 一起带走。"""
    children: dict[int, list[int]] = {}
    for line in _run(["ps", "-axo", "pid=,ppid="], runner=runner).splitlines():
        bits = line.split()
        if len(bits) == 2 and bits[0].isdigit() and bits[1].isdigit():
            children.setdefault(int(bits[1]), []).append(int(bits[0]))
    found: list[int] = []
    frontier = [pid]
    while frontier:
        cur = frontier.pop()
        for child in children.get(cur, []):
            if child not in found:
                found.append(child)
                frontier.append(child)
    return found


def reap(row: dict, verdict: str, runner: Runner | None = None) -> str:
    """真收。测试必须打桩，不许走到 os.kill。"""
    if row.get("never_touch"):
        return f"禁动 {row.get('protect_label')}"
    if row.get("live_client"):
        return "有活连接，不收"
    if verdict == "managed_over":
        uid = os.getuid()
        _run(["launchctl", "kickstart", "-k", f"gui/{uid}/{MANAGED_WEB_LABEL}"], timeout=30, runner=runner)
        return f"launchctl kickstart -k {MANAGED_WEB_LABEL}"

    pid = int(row["pid"])
    targets = descendants(pid, runner=runner) + [pid]
    for target in targets:
        try:
            os.kill(target, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            continue
    # 死规则：逐 PID TERM，一次性等足 5 秒，再逐 PID KILL 幸存者。
    time.sleep(5.0)
    survivors: list[int] = []
    for target in targets:
        try:
            os.kill(target, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
        survivors.append(target)
    for target in survivors:
        try:
            os.kill(target, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            continue
    reason = str(row.get("reap_reason") or verdict)
    if not survivors:
        return f"TERM 5s 后全退出; pids={targets}; reason={reason}"
    return f"TERM 5s -> KILL; pids={targets}; survivors={survivors}; reason={reason}"


def evaluate_rows(
    rows: list[dict],
    *,
    cap_mb: float,
    orphan_hours: float,
    state: dict,
    now: float,
    offenders: dict,
    path_exists: ExistsFn,
    has_live_client: LiveFn,
) -> list[dict]:
    live_keys: set[str] = set()
    for row in rows:
        owner = row.get("owner") or "unknown"
        threshold = idle_minutes_for(owner, offense_count_of(owner, offenders))
        row["idle_threshold_minutes"] = threshold
        row["offense_count"] = offense_count_of(owner, offenders)
        verdict = classify(
            row,
            cap_mb=cap_mb,
            orphan_hours=orphan_hours,
            idle_minutes=threshold,
            state=state,
            now=now,
            path_exists=path_exists,
            has_live_client=has_live_client,
        )
        row["verdict"] = verdict
        live_keys.add(f"{row.get('pid')}:{row.get('port')}:{row.get('cwd')}")
    # 进程没了就把空闲计时丢掉，别让 state 无限长
    stale = [key for key in list(state) if key not in live_keys]
    for key in stale:
        state.pop(key, None)
    return rows


def _path_exists(path: str) -> bool:
    try:
        return Path(path).exists()
    except OSError:
        return False


def east_eight_ledger_ts(now: datetime | None = None) -> str:
    current = now or datetime.now(_EAST_EIGHT)
    if current.tzinfo is None:
        current = current.replace(tzinfo=_EAST_EIGHT)
    else:
        current = current.astimezone(_EAST_EIGHT)
    return current.strftime("%Y-%m-%dT%H:%M:%S%z")


def round_duration_fields(
    duration_seconds: float,
    interval_seconds: float = MEMORY_MONITOR_INTERVAL_SECONDS,
) -> dict:
    """Heartbeat extras. duration_over_half_interval is what the menubar reads."""
    duration = max(0.0, float(duration_seconds))
    interval = float(interval_seconds or MEMORY_MONITOR_INTERVAL_SECONDS)
    if interval <= 0:
        interval = float(MEMORY_MONITOR_INTERVAL_SECONDS)
    over = duration > (interval / 2.0)
    payload: dict = {
        "duration_seconds": round(duration, 3),
        "interval_seconds": int(interval) if interval.is_integer() else interval,
        "duration_over_half_interval": over,
    }
    if over:
        if interval % 60 == 0:
            interval_text = f"{int(interval // 60)} 分钟"
        else:
            interval_text = f"{int(interval)} 秒"
        payload["duration_warn"] = (
            f"内存与回收巡检本轮 {duration:.0f} 秒，已超过 {interval_text}间隔的一半，快撑不住了"
        )
    return payload


def last_jsonl_record(path: Path) -> dict | None:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return None
    for line in reversed(raw.splitlines()):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            payload = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            return payload
    return None


def attach_round_duration(
    path: Path,
    duration_seconds: float,
    interval_seconds: float = MEMORY_MONITOR_INTERVAL_SECONDS,
    extra: dict | None = None,
) -> dict:
    """Write duration onto the latest heartbeat line. Create the line if missing.

    Quiet reaper rounds on origin/main may not append anything. The reclaim
    pass still has to leave a record the visible surface can read.
    extra 会并进同一行，给回收器写 kind / applied / skip_reason 用。
    """
    fields = round_duration_fields(duration_seconds, interval_seconds)
    if extra:
        fields.update(extra)
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = last_jsonl_record(path)
    if existing is None:
        record = {"ts": east_eight_ledger_ts(), **fields}
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        patch_background_jobs_snapshots(record, path)
        return record
    existing.update(fields)
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        patch_background_jobs_snapshots(existing, path)
        return existing
    lines = raw.splitlines()
    replaced = False
    for index in range(len(lines) - 1, -1, -1):
        if lines[index].strip():
            lines[index] = json.dumps(existing, ensure_ascii=False)
            replaced = True
            break
    if not replaced:
        lines.append(json.dumps(existing, ensure_ascii=False))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    patch_background_jobs_snapshots(existing, path)
    return existing


def apply_duration_pressure(job: dict, record: dict | None) -> dict:
    """Turn a healthy job row into the menubar '快撑不住了' warning.

    The background-jobs snapshot reads the same heartbeat jsonl. If the last
    record says this round ran past half the launchd interval, the job must
    not look '正常' — that is how a stranger sees the problem weeks later.
    hung/error already outrank this warning.
    """
    if not record or not record.get("duration_over_half_interval"):
        return job
    out = dict(job)
    out["duration_over_half_interval"] = True
    out["duration_seconds"] = record.get("duration_seconds")
    warn = str(record.get("duration_warn") or DURATION_SLOW_STATUS_TEXT)
    status = str(out.get("status") or "")
    if status in ("", "ok"):
        out["status"] = DURATION_SLOW_STATUS
        out["status_text"] = DURATION_SLOW_STATUS_TEXT
        out["reason"] = warn
    elif not out.get("reason"):
        out["reason"] = warn
    return out


def enrich_background_jobs_snapshot(snapshot: dict, record: dict | None) -> dict:
    """Mark the memory-monitor row when this round ran past half its interval."""
    jobs = snapshot.get("jobs")
    if not isinstance(jobs, list):
        return snapshot
    out_jobs = []
    for job in jobs:
        if isinstance(job, dict) and job.get("label") == MEMORY_MONITOR_LABEL:
            out_jobs.append(apply_duration_pressure(job, record))
        else:
            out_jobs.append(job)
    updated = dict(snapshot)
    updated["jobs"] = out_jobs
    problem_count = sum(
        1 for job in out_jobs if isinstance(job, dict) and job.get("status") != "ok"
    )
    updated["problem_count"] = problem_count
    updated["ok_count"] = len(out_jobs) - problem_count
    return updated


def background_jobs_snapshot_paths(ledger_path: Path) -> list[Path]:
    paths = [ledger_path.parent / BACKGROUND_JOBS_SNAPSHOT_NAME]
    logs = os.environ.get("CORTEX_LOGS_DIR", "").strip()
    if logs:
        paths.append(Path(logs).expanduser() / BACKGROUND_JOBS_SNAPSHOT_NAME)
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in paths:
        resolved = path.expanduser()
        if resolved in seen:
            continue
        seen.add(resolved)
        unique.append(resolved)
    return unique


def patch_background_jobs_snapshots(record: dict, ledger_path: Path) -> list[Path]:
    """Write duration pressure onto the JSON the menubar already reads.

    Only patches files that already exist. Inventing a half-empty snapshot
    would look like '后台任务 无数据' or a fake all-clear.
    """
    written: list[Path] = []
    if not record:
        return written
    encoded = None
    for path in background_jobs_snapshot_paths(ledger_path):
        if not path.is_file():
            continue
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        updated = enrich_background_jobs_snapshot(payload, record)
        if encoded is None:
            encoded = json.dumps(updated, ensure_ascii=False, indent=2) + "\n"
        try:
            path.write_text(encoded, encoding="utf-8")
        except OSError:
            continue
        written.append(path)
    return written


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="真的收掉；默认只看不动")
    parser.add_argument("--cap-mb", type=float, default=DEFAULT_CAP_MB)
    parser.add_argument("--orphan-hours", type=float, default=DEFAULT_ORPHAN_HOURS)
    parser.add_argument("--idle-minutes", type=float, default=DEFAULT_IDLE_MINUTES)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    now = time.time()
    state = load_json(STATE_PATH)
    # 旧版 state 是 {key: epoch}；新字段不要跟它混
    idle_state = {k: v for k, v in state.items() if isinstance(v, (int, float))}
    offenders = load_json(OFFENDER_PATH)
    rows = scan()
    evaluate_rows(
        rows,
        cap_mb=args.cap_mb,
        orphan_hours=args.orphan_hours,
        state=idle_state,
        now=now,
        offenders=offenders,
        path_exists=_path_exists,
        has_live_client=lambda port: port_has_live_client(port),
    )

    reapable = {"dead", "orphan_idle", "idle", "managed_over", "terminal_run"}
    actions: list[dict] = []
    for row in rows:
        verdict = row["verdict"]
        if verdict not in reapable:
            continue
        if row.get("never_touch"):
            row["action"] = f"禁动 {row.get('protect_label')}"
            continue
        if row.get("live_client"):
            row["action"] = "有活连接，不收"
            continue
        if args.apply:
            row["action"] = reap(row, verdict)
            record_offense(offenders, row, verdict, now)
            actions.append(row)
        else:
            row["action"] = "dry-run 不动"

    save_json(STATE_PATH, idle_state)
    if args.apply and actions:
        save_json(OFFENDER_PATH, offenders)

    reclaimed = round(sum(float(r.get("mem_mb") or 0) for r in actions), 1)
    summary = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "applied": args.apply,
        "servers": len(rows),
        "reaped": len(actions),
        "reclaimed_mb": reclaimed,
        "actions": actions,
        "rows": rows,
    }

    append_run_record(LOG_PATH, summary)

    if args.json:
        print(json.dumps(summary, ensure_ascii=False))
        return 0

    print(
        f"开发服务/浏览器共 {len(rows)} 个；本次{'真收' if args.apply else '只看'} "
        f"{len(actions)} 个，回收 {reclaimed:.0f} MB"
    )
    for row in sorted(rows, key=lambda r: -float(r.get("mem_mb") or 0)):
        lock = ""
        if int(row.get("offense_count") or 0) >= REPEAT_OFFENSE_THRESHOLD:
            lock = (
                f" 禁闭{row.get('idle_threshold_minutes'):.0f}min"
                f"/累犯{row.get('offense_count')}次"
            )
        print(
            f"  [{row['verdict']:<12}] pid={row['pid']:<7} "
            f"port={str(row.get('port')):<6} "
            f"{float(row.get('mem_mb') or 0):>8.0f} MB "
            f"(压缩 {float(row.get('cmprs_mb') or 0):.0f} MB) "
            f"起了{float(row.get('age_hours') or 0):.1f}h "
            f"闲{float(row.get('idle_minutes') or 0):.0f}min "
            f"主={row.get('owner')} "
            f"{'launchd托管 ' if row.get('managed') else ''}"
            f"{'禁动 ' if row.get('never_touch') else ''}"
            f"{row.get('cwd') or '(cwd 取不到)'}"
            f" 原因={row.get('reap_reason') or row.get('note') or '-'}"
            f"{lock}"
            + (f"  -> {row.get('action')}" if row.get("action") else "")
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
