#!/usr/bin/env python3
"""派工占用与派工记录（Falcon 10-04 00:2x：每时每刻的占用、每次派工都要留记录）。

两份按北京日期分的 jsonl，落在 ~/Library/Application Support/CortexSentinel/occupancy/：

- YYYY-MM-DD.jsonl        每分钟一行：每个号的在跑/上限、看板 run / 本机线 / 手开窗口 /
                          排队分开写、每个执行者的在跑/看板帽/归档、三台机器内存压力。
- dispatch-YYYY-MM-DD.jsonl  每条新起的 run 一行（按 run 号去重）：票号、执行者、机器、
                          号、模型、run 类型、触发评论开头 40 字、当刻各号在跑数。

数法不另写一套：号的在跑数直接读哨兵面板那份读数（闸运行时 scripts/glm_plan_status.py
--json，即面板「在跑 n/7」的来源），三机内存读闸运行时 sentry_telemetry.read_machines()
（面板三机总览同一入口）。面板口径与派工器 GLM_ACCOUNT_LEDGER、号超上限哨兵的差异见
README 与交活报告，这里不去统一，各口径原值并排写进行里（plans[*] 是面板口径，plans[*].ledger 是派工器账本口径）。

只读：不写 Multica、不碰钥匙，只追加自己的两份记录和一份去重状态。
查询：sentinel-occupancy at "2026-10-04 00:05" / sentinel-occupancy runs --since "00:00"。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence

BEIJING = timezone(timedelta(hours=8))
SCHEMA = 1
# 新 run 只在创建后这段时间内才写（冷启动或停机恢复不倒灌历史）；超过 5 分钟才被看到的标 backfill。
NEW_RUN_WINDOW = timedelta(hours=2)
BACKFILL_AFTER = timedelta(minutes=5)
SEEN_KEEP = timedelta(days=3)
RUNS_PER_AGENT = 60
OCCUPYING_STATUSES = ("running",)
QUEUED_STATUSES = ("queued", "dispatched", "waiting_local_directory")
TRIGGER_HEAD_CHARS = 40

KEEP_NOTE = (
    "CORTEX-KEEP\n"
    "# 不要删除 · 一定保留 · DO NOT DELETE\n\n"
    "这里是 Cortex 哨兵给派工复盘留的记录，至少保留 30 天，清理程序和任何窗口都不要动：\n\n"
    "- YYYY-MM-DD.jsonl：每分钟一行，各号在跑数与上限（看板 run / 本机线 / 手开窗口 / 排队分开），"
    "各执行者在跑与看板帽，三台机器内存压力。\n"
    "- dispatch-YYYY-MM-DD.jsonl：每条新起的 run 一行，票号、执行者、机器、号、模型、"
    "run 类型、触发评论开头 40 字、当刻各号在跑数。\n"
    "- state.json：去重状态（已记过的 run 号、票号缓存），可由程序重建。\n\n"
    "查询：sentinel-occupancy at \"2026-10-04 00:05\" 或 sentinel-occupancy runs --since \"00:00\"。\n"
    "（日期按北京时间。）\n"
)


# ---------------------------------------------------------------- 路径与时间

def data_dir() -> Path:
    raw = os.environ.get("CORTEX_SENTINEL_OCCUPANCY_DIR", "").strip()
    base = Path(raw).expanduser() if raw else (
        Path.home() / "Library" / "Application Support" / "CortexSentinel" / "occupancy"
    )
    base.mkdir(parents=True, exist_ok=True)
    keep = base / "不要删除.md"
    if not keep.exists():
        keep.write_text(KEEP_NOTE, encoding="utf-8")
    return base


def to_beijing(moment: datetime) -> datetime:
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(BEIJING)


def fmt_bj(moment: datetime) -> str:
    return to_beijing(moment).strftime("%Y-%m-%d %H:%M:%S")


def parse_utc(text: Any) -> Optional[datetime]:
    raw = str(text or "").strip()
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def occupancy_file(base: Path, day: str) -> Path:
    return base / f"{day}.jsonl"


def dispatch_file(base: Path, day: str) -> Path:
    return base / f"dispatch-{day}.jsonl"


def append_jsonl(path: Path, row: Mapping[str, Any]) -> None:
    line = json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n"
    # 单次 write 追加，一行一条，崩在中间最多丢这一行。
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(line)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            rows.append(value)
    return rows


# ---------------------------------------------------------------- 取数（子进程，只读）

def gate_runtime() -> Path:
    raw = os.environ.get("CORTEX_GATE_RUNTIME", "").strip()
    return Path(raw).expanduser() if raw else (
        Path.home() / "Library" / "Application Support" / "Cortex" / "GateRuntime" / "current"
    )


def checkout_base() -> str:
    raw = os.environ.get("CORTEX_GATE_CHECKOUT_BASE", "").strip()
    return raw or str(Path.home() / "Documents" / "code" / "cortex")


def multica_bin() -> str:
    found = Path.home() / ".local" / "bin" / "multica"
    return str(found) if found.exists() else "multica"


def _run(argv: Sequence[str], *, cwd: Optional[Path] = None, env: Optional[dict] = None,
         stdin: str = "", timeout: float = 40.0) -> tuple[Optional[str], Optional[str]]:
    """跑一个只读子进程，返回 (stdout, 错误说明)。超时只杀自己起的这一个。"""
    try:
        proc = subprocess.run(
            list(argv), cwd=str(cwd) if cwd else None, env=env, input=stdin,
            capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None, f"超时 {argv[-1] if argv else ''}"
    except OSError as exc:
        return None, f"起不来：{exc}"
    if proc.returncode != 0:
        return None, f"退出码 {proc.returncode}：{(proc.stderr or '').strip()[-160:]}"
    return proc.stdout, None


def _json_from(text: Optional[str]) -> Any:
    if not text:
        return None
    starts = [i for i in (text.find("{"), text.find("[")) if i >= 0]
    if not starts:
        return None
    try:
        return json.loads(text[min(starts):])
    except ValueError:
        return None


def _env() -> dict:
    env = dict(os.environ)
    home = str(Path.home())
    env["PATH"] = ":".join([f"{home}/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                            "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    env["CORTEX_GATE_CHECKOUT_BASE"] = checkout_base()
    env["PYTHONPATH"] = str(gate_runtime())
    return env


def gate_python() -> str:
    """闸运行时脚本要 3.10+：优先自己这份解释器（够新就用），否则 Cortex 主检出的 venv。"""
    if sys.version_info >= (3, 10):
        return sys.executable
    venv = Path(checkout_base()) / ".venv" / "bin" / "python3"
    return str(venv) if venv.exists() else "/usr/bin/python3"


def fetch_panel_payload() -> tuple[Optional[dict], Optional[str]]:
    """面板「在跑 n/7」的同一份读数：glm_plan_status.py --json（用量从 stdin 喂空，不影响在跑数）。"""
    out, err = _run([gate_python(), "scripts/glm_plan_status.py", "--json"],
                    cwd=gate_runtime(), env=_env(), stdin="", timeout=60)
    payload = _json_from(out)
    if not isinstance(payload, dict) or "plans" not in payload:
        return None, err or "面板读数解析不了"
    return payload, err


def fetch_machines() -> tuple[Optional[list], Optional[str]]:
    """面板三机总览同一入口：sentry_telemetry.read_machines()。"""
    code = "import json;from scripts.sentry_telemetry import read_machines;print(json.dumps(read_machines()))"
    out, err = _run([gate_python(), "-c", code], cwd=gate_runtime(), env=_env(), timeout=40)
    rows = _json_from(out)
    if not isinstance(rows, list):
        return None, err or "三机读数解析不了"
    return rows, None


def fetch_ledger() -> tuple[Optional[dict], Optional[str]]:
    """派工器账本口径的读数：号超上限哨兵同一个读方（account_cap_sentinel.collect_round →
    account_running_counts），看板行不按帽封顶，另含手开窗口 / 监工占位 / 预占。只读。"""
    code = (
        "import json,collections\n"
        "from datetime import datetime, timezone\n"
        "from scripts.account_cap_sentinel import collect_round\n"
        "r = collect_round(now=datetime.now(timezone.utc))\n"
        "kinds = collections.defaultdict(lambda: collections.Counter())\n"
        "for l in r.lines:\n"
        "    kinds[str(l.account)][str(l.kind)] += 1\n"
        "print(json.dumps({'totals': dict(r.totals), 'kinds': {a: dict(c) for a, c in kinds.items()}, 'notes': list(r.notes)}, ensure_ascii=False))\n"
    )
    out, err = _run([gate_python(), "-c", code], cwd=gate_runtime(), env=_env(), timeout=60)
    data = _json_from(out)
    if not isinstance(data, dict) or "totals" not in data:
        return None, err or "账本读数解析不了"
    return data, None


def fetch_agents() -> tuple[Optional[list], Optional[str]]:
    out, err = _run([multica_bin(), "agent", "list", "--output", "json"], env=_env(), timeout=30)
    rows = _json_from(out)
    if not isinstance(rows, list):
        return None, err or "agent list 解析不了"
    return rows, None


def fetch_agent_runs(agent_id: str) -> tuple[Optional[list], Optional[str]]:
    out, err = _run([multica_bin(), "agent", "tasks", agent_id, "--limit", str(RUNS_PER_AGENT),
                     "--output", "json"], env=_env(), timeout=30)
    rows = _json_from(out)
    if not isinstance(rows, list):
        return None, err or "agent tasks 解析不了"
    return rows, None


def fetch_issue_identifier(issue_id: str) -> Optional[str]:
    out, _err = _run([multica_bin(), "issue", "get", issue_id, "--output", "json"], env=_env(), timeout=20)
    data = _json_from(out)
    if isinstance(data, dict) and data.get("identifier"):
        return str(data["identifier"])
    return None


# ---------------------------------------------------------------- 纯函数：口径与组行

def machine_word_of_name(name: str) -> str:
    lowered = (name or "").lower()
    if "m1max" in lowered or "m1 max" in lowered:
        return "m1max"
    if "mini" in lowered:
        return "mini"
    if "pro" in lowered:
        return "pro"
    return "-"


def executor_index(payload: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    """执行者号 → {account, name, machine}；机器优先取面板 lines 里 cortex 侧归好的，认不出再看名字。"""
    by_name_machine: dict[str, str] = {}
    for plan in payload.get("plans") or []:
        for line in plan.get("lines") or []:
            if line.get("executor") and line.get("machine"):
                by_name_machine[str(line["executor"])] = str(line["machine"])
    index: dict[str, dict[str, Any]] = {}
    for plan in payload.get("plans") or []:
        for ex in plan.get("executors") or []:
            name = str(ex.get("name") or "")
            index[str(ex.get("id") or "")] = {
                "account": str(plan.get("id") or ""),
                "name": name,
                "machine": by_name_machine.get(name) or machine_word_of_name(name),
            }
    return index


def _kind_counts(zcode_other: Any) -> dict[str, dict[str, int]]:
    """三机上报的 zcode_other → {号: {manual: n, supervisor: n}}，形状容错：缺了就空。"""
    result: dict[str, dict[str, int]] = {}
    if not isinstance(zcode_other, Mapping):
        return result
    for account, kinds in zcode_other.items():
        if isinstance(kinds, Mapping):
            result[str(account)] = {str(k): int(v or 0) for k, v in kinds.items() if isinstance(v, (int, float))}
        elif isinstance(kinds, (int, float)):
            result[str(account)] = {"manual": int(kinds)}
    return result


def scan_board_runs(runs_by_agent: Mapping[str, Sequence[Mapping[str, Any]]],
                    index: Mapping[str, Mapping[str, Any]]) -> dict[str, dict[str, int]]:
    """看板 run 状态数（我们自己扫 multica agent tasks 的结果）：按号数 running 与排队。"""
    per_account: dict[str, dict[str, int]] = {}
    for agent_id, runs in runs_by_agent.items():
        account = (index.get(agent_id) or {}).get("account")
        if not account:
            continue
        bucket = per_account.setdefault(account, {"scan_running": 0, "scan_queued": 0})
        for run in runs or []:
            status = str(run.get("status") or "")
            if status in OCCUPYING_STATUSES:
                bucket["scan_running"] += 1
            elif status in QUEUED_STATUSES:
                bucket["scan_queued"] += 1
    return per_account


def _ledger_of(ledger: Optional[Mapping[str, Any]], account: str) -> Optional[dict[str, Any]]:
    """账本口径并排写：total 是派工器 / 号超上限哨兵的合计，other = total - 看板行 - 本机线
    （手开窗口、监工占位、预占，不细分，细分归属在账本那边有已知对调，见 README）。"""
    if not isinstance(ledger, Mapping) or account not in (ledger.get("totals") or {}):
        return None
    total = int(ledger["totals"][account] or 0)
    kinds = (ledger.get("kinds") or {}).get(account) or {}
    board, local = int(kinds.get("board_run", 0)), int(kinds.get("local_line", 0))
    return {"total": total, "board_run": board, "local_line": local, "other": total - board - local}


def build_occupancy_row(
    *,
    now: datetime,
    payload: Optional[Mapping[str, Any]],
    machines: Optional[Sequence[Mapping[str, Any]]],
    scan: Optional[Mapping[str, Mapping[str, int]]] = None,
    ledger: Optional[Mapping[str, Any]] = None,
    notes: Sequence[str] = (),
) -> dict[str, Any]:
    plans_out: dict[str, Any] = {}
    executors_out: list[dict[str, Any]] = []
    machine_manual: dict[str, dict[str, dict[str, int]]] = {}
    for row in machines or []:
        machine_manual[str(row.get("machine") or "")] = _kind_counts(row.get("zcode_other"))
    manual_by_account: dict[str, int] = {}
    supervisor_by_account: dict[str, int] = {}
    for kinds_by_account in machine_manual.values():
        for account, kinds in kinds_by_account.items():
            manual_by_account[account] = manual_by_account.get(account, 0) + kinds.get("manual", 0)
            supervisor_by_account[account] = supervisor_by_account.get(account, 0) + kinds.get("supervisor", 0)

    for plan in (payload or {}).get("plans") or []:
        account = str(plan.get("id") or "")
        multica_raw = plan.get("running_multica")
        multica_eff = plan.get("running_multica_effective")
        gap = (multica_raw - multica_eff) if isinstance(multica_raw, int) and isinstance(multica_eff, int) else None
        scan_bucket = (scan or {}).get(account) or {}
        plans_out[account] = {
            "label": plan.get("label"),
            # 面板口径：在跑 n / 上限（= 本机线 + 按单执行者看板帽封顶的看板条数）
            "running": plan.get("running"),
            "cap": plan.get("max_parallel"),
            "hard_cap": plan.get("hard_parallel"),
            "board_runs": multica_raw,
            "board_runs_capped": multica_eff,
            "local_lines": plan.get("running_local"),
            "local_lines_known": plan.get("local_lines_known"),
            # 手开窗口与监工占位：三机上报的 zcode_other 按号合计；面板口径本身不含它们
            "manual_windows": manual_by_account.get(account, 0),
            "supervisor_windows": supervisor_by_account.get(account, 0),
            # 排队：看板超出帽的条数（面板口径）与自己扫 run 状态数到的 queued 类
            "queued_over_cap": gap,
            "queued_scan": scan_bucket.get("scan_queued"),
            "running_scan": scan_bucket.get("scan_running"),
            "dispatchable": plan.get("dispatchable"),
            "skip_code": plan.get("skip_code"),
            "cooldown_until": plan.get("cooldown_until"),
            "read_error": plan.get("read_error"),
            "ledger": _ledger_of(ledger, account),
        }
        for ex in plan.get("executors") or []:
            name = str(ex.get("name") or "")
            executors_out.append({
                "id": ex.get("id"),
                "name": name,
                "account": account,
                "machine": machine_word_of_name(name),
                "running": ex.get("running"),
                "board_cap": ex.get("max_concurrent_tasks"),
                "on_board": ex.get("on_board"),
                "off_board_reason": ex.get("off_board_reason"),
                "archived": ex.get("off_board_reason") == "archived",
                "stopped": plan.get("dispatchable") is False,
            })

    machines_out: dict[str, Any] = {}
    for row in machines or []:
        word = str(row.get("machine") or "")
        swap = row.get("swap") if isinstance(row.get("swap"), Mapping) else {}
        machines_out[word] = {
            "mem_pressure_pct": row.get("mem_pressure_pct"),
            "pressure_level": row.get("pressure_level"),
            "mem_free_pct": row.get("mem_free_pct"),
            "mem_used_pct": row.get("mem_used_pct"),
            "swap_used": swap.get("used"),
            "swap_total": swap.get("total"),
            "cpu_pct": row.get("cpu_pct"),
            "report_ts": row.get("ts"),
            "running_lines": row.get("running_lines"),
        }

    row_notes = list(notes)
    if payload is None:
        row_notes.append("面板读数没读到，plans 为空")
    if machines is None:
        row_notes.append("三机读数没读到，machines 为空")
    if ledger is None:
        row_notes.append("账本口径读数没读到，plans[*].ledger 为空")
    return {
        "schema": SCHEMA,
        "ts_bj": fmt_bj(now),
        "ts_utc": now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "plans": plans_out,
        "executors": executors_out,
        "machines": machines_out,
        "notes": row_notes,
    }


def account_running_summary(payload: Optional[Mapping[str, Any]]) -> dict[str, int]:
    return {str(p.get("id")): p.get("running") for p in (payload or {}).get("plans") or []}


def new_dispatch_rows(
    *,
    now: datetime,
    runs_by_agent: Mapping[str, Sequence[Mapping[str, Any]]],
    agents_by_id: Mapping[str, Mapping[str, Any]],
    index: Mapping[str, Mapping[str, Any]],
    running_by_account: Mapping[str, Any],
    seen: dict[str, str],
    issue_cache: dict[str, str],
    lookup_issue: Callable[[str], Optional[str]] = fetch_issue_identifier,
) -> list[dict[str, Any]]:
    """没记过的 run 各出一行；seen（run 号 → 创建时刻）就地更新，按 run 号去重。"""
    fresh: list[tuple[str, Mapping[str, Any]]] = []
    for agent_id, runs in runs_by_agent.items():
        for run in runs or []:
            run_id = str(run.get("id") or "")
            if not run_id or run_id in seen:
                continue
            created = parse_utc(run.get("created_at"))
            # 无论写不写都登记已见：太老的（冷启动倒灌）只记已见不出行。
            seen[run_id] = str(run.get("created_at") or fmt_bj(now))
            if created is None or now - created > NEW_RUN_WINDOW:
                continue
            fresh.append((agent_id, run))
    fresh.sort(key=lambda item: str(item[1].get("created_at") or ""))
    # 票号缓存里没有的 issue 并发查一次（只对新 run 查，稳态一轮几乎不查）。
    missing = sorted({str(run.get("issue_id") or "") for _a, run in fresh} - set(issue_cache) - {""})
    if missing:
        with ThreadPoolExecutor(max_workers=8) as pool:
            for issue_id, found in zip(missing, pool.map(lookup_issue, missing)):
                if found:
                    issue_cache[issue_id] = found
    rows: list[dict[str, Any]] = []
    for agent_id, run in fresh:
        issue_id = str(run.get("issue_id") or "")
        info = index.get(agent_id) or {}
        agent = agents_by_id.get(agent_id) or {}
        name = str(info.get("name") or agent.get("name") or "")
        created = parse_utc(run.get("created_at"))
        evidence = ((run.get("attribution") or {}).get("evidence") or {}).get("kind")
        kind = str(run.get("kind") or "")
        rows.append({
            "schema": SCHEMA,
            "ts_bj": fmt_bj(now),
            "created_bj": fmt_bj(created) if created else None,
            "run_id": run.get("id"),
            "ticket": issue_cache.get(issue_id) or (issue_id[:8] if issue_id else None),
            "executor": name,
            "executor_id": agent_id,
            "machine": info.get("machine") or machine_word_of_name(name),
            "account": info.get("account") or "-",
            "model": agent.get("model"),
            "kind": kind,
            "kind_zh": {"direct": "新派", "comment": "评论叫醒"}.get(kind, kind or "未知"),
            "trigger": evidence,
            "status_at_seen": run.get("status"),
            "trigger_head": str(run.get("trigger_summary") or "")[:TRIGGER_HEAD_CHARS],
            "backfill": bool(created and now - created > BACKFILL_AFTER),
            "account_running": dict(running_by_account),
        })
    return rows


def prune_seen(seen: dict[str, str], now: datetime) -> None:
    for run_id in [k for k, v in seen.items()
                   if (parse_utc(v) is not None and now - parse_utc(v) > SEEN_KEEP)]:
        del seen[run_id]


# ---------------------------------------------------------------- 一轮

def load_state(base: Path) -> dict[str, Any]:
    path = base / "state.json"
    if path.exists():
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                value.setdefault("seen", {})
                value.setdefault("issues", {})
                return value
        except ValueError:
            pass
    return {"seen": {}, "issues": {}}


def save_state(base: Path, state: Mapping[str, Any]) -> None:
    tmp = base / "state.json.tmp"
    tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    tmp.replace(base / "state.json")


def tick(now: Optional[datetime] = None, base: Optional[Path] = None) -> dict[str, Any]:
    now = now or datetime.now(timezone.utc)
    base = base or data_dir()
    notes: list[str] = []
    runs_by_agent: dict[str, list] = {}
    # 面板读数、三机读数、agent 清单一起发；清单一到就并发扫各执行者的 run，不等面板读数。
    with ThreadPoolExecutor(max_workers=10) as pool:
        f_payload = pool.submit(fetch_panel_payload)
        f_machines = pool.submit(fetch_machines)
        f_agents = pool.submit(fetch_agents)
        f_ledger = pool.submit(fetch_ledger)
        agents, err = f_agents.result()
        if err and agents is None:
            notes.append(f"agent 清单：{err}")
        agents_by_id = {str(a.get("id")): a for a in agents or []}
        scan_ids = [aid for aid, a in agents_by_id.items() if not a.get("archived_at")]
        f_runs = {aid: pool.submit(fetch_agent_runs, aid) for aid in scan_ids}
        payload, err = f_payload.result()
        if err and payload is None:
            notes.append(f"面板读数：{err}")
        machines, err = f_machines.result()
        if err and machines is None:
            notes.append(f"三机读数：{err}")
        ledger, err = f_ledger.result()
        if err and ledger is None:
            notes.append(f"账本读数：{err}")
        for agent_id, future in f_runs.items():
            runs, err = future.result()
            if runs is None:
                notes.append(f"{(agents_by_id[agent_id].get('name') or agent_id)}：run 读不到")
                continue
            runs_by_agent[agent_id] = runs
    index = executor_index(payload or {})

    day = to_beijing(now).strftime("%Y-%m-%d")
    occ = build_occupancy_row(now=now, payload=payload, machines=machines,
                              scan=scan_board_runs(runs_by_agent, index), ledger=ledger, notes=notes)
    append_jsonl(occupancy_file(base, day), occ)

    state = load_state(base)
    rows = new_dispatch_rows(
        now=now, runs_by_agent=runs_by_agent, agents_by_id=agents_by_id, index=index,
        running_by_account=account_running_summary(payload),
        seen=state["seen"], issue_cache=state["issues"],
    )
    for row in rows:
        append_jsonl(dispatch_file(base, to_beijing(now).strftime("%Y-%m-%d")), row)
    prune_seen(state["seen"], now)
    save_state(base, state)
    return {"occupancy": occ["ts_bj"], "dispatch_rows": len(rows), "notes": notes}


# ---------------------------------------------------------------- 查询

def parse_when(text: str, *, today: Optional[datetime] = None) -> datetime:
    """'2026-10-04 00:05' 或 '00:05'（今天，北京）→ 北京时刻。"""
    raw = text.strip()
    today = to_beijing(today or datetime.now(timezone.utc))
    if re.fullmatch(r"\d{1,2}:\d{2}(:\d{2})?", raw):
        raw = f"{today.strftime('%Y-%m-%d')} {raw}"
    for pattern in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(raw, pattern).replace(tzinfo=BEIJING)
        except ValueError:
            continue
    raise ValueError(f"时刻认不出：{text}（写 2026-10-04 00:05 或 00:05，北京时间）")


def row_at(base: Path, when: datetime) -> Optional[dict[str, Any]]:
    """那一刻（含这一分钟末）之前最近的一行；当天文件没有就往前找一天。"""
    limit = fmt_bj(when.replace(second=59))
    for back in (0, 1):
        day = (when - timedelta(days=back)).strftime("%Y-%m-%d")
        candidates = [r for r in read_jsonl(occupancy_file(base, day)) if str(r.get("ts_bj") or "") <= limit]
        if candidates:
            return max(candidates, key=lambda r: str(r.get("ts_bj") or ""))
    return None


def runs_between(base: Path, since: datetime, until: Optional[datetime] = None) -> list[dict[str, Any]]:
    start, end = fmt_bj(since), fmt_bj(until) if until else None
    rows: list[dict[str, Any]] = []
    day = since.date()
    last = (until or datetime.now(BEIJING)).date()
    while day <= last:
        rows.extend(read_jsonl(dispatch_file(base, day.strftime("%Y-%m-%d"))))
        day += timedelta(days=1)
    rows = [r for r in rows if str(r.get("created_bj") or r.get("ts_bj") or "") >= start
            and (end is None or str(r.get("created_bj") or r.get("ts_bj") or "") <= end)]
    return sorted(rows, key=lambda r: str(r.get("created_bj") or r.get("ts_bj") or ""))


def format_occupancy(row: Mapping[str, Any]) -> str:
    lines = [f"占用记录 {row.get('ts_bj')}（北京）"]
    for account, p in (row.get("plans") or {}).items():
        lines.append(
            f"  {account:<7} 在跑 {p.get('running')}/{p.get('cap')}  看板 {p.get('board_runs')}"
            f"（封顶后 {p.get('board_runs_capped')}，超帽排队 {p.get('queued_over_cap')}，扫到排队 {p.get('queued_scan')}）"
            f"  本机线 {p.get('local_lines')}  手开 {p.get('manual_windows')}  监工 {p.get('supervisor_windows')}"
            f"  可派 {p.get('dispatchable')}  账本合计 {(p.get('ledger') or {}).get('total')}"
            f"（其他占位 {(p.get('ledger') or {}).get('other')}）")
    for ex in row.get("executors") or []:
        flag = "  [归档]" if ex.get("archived") else ""
        lines.append(f"    {ex.get('account')}/{ex.get('name')}  在跑 {ex.get('running')}/{ex.get('board_cap')}{flag}")
    for word, m in (row.get("machines") or {}).items():
        lines.append(f"  机器 {word}  内存压力 {m.get('mem_pressure_pct')}%（档 {m.get('pressure_level')}）"
                     f"  可用 {m.get('mem_free_pct')}%  swap {m.get('swap_used')}/{m.get('swap_total')}")
    for note in row.get("notes") or []:
        lines.append(f"  注：{note}")
    return "\n".join(lines)


def format_run(row: Mapping[str, Any]) -> str:
    head = f"  「{row.get('trigger_head')}」" if row.get("trigger_head") else ""
    mark = " [补记]" if row.get("backfill") else ""
    return (f"{row.get('created_bj')}  {row.get('ticket')}  {row.get('executor')}@{row.get('machine')}"
            f"  号 {row.get('account')}  {row.get('model')}  {row.get('kind_zh')}/{row.get('trigger')}"
            f"  当刻在跑 {row.get('account_running')}{mark}{head}")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="sentinel-occupancy", description="哨兵占用记录与派工记录查询（北京时间）")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_at = sub.add_parser("at", help="某一刻最近一行的各号占用")
    p_at.add_argument("when")
    p_at.add_argument("--json", action="store_true")
    p_runs = sub.add_parser("runs", help="一段时间内的派工行")
    p_runs.add_argument("--since", required=True)
    p_runs.add_argument("--until")
    p_runs.add_argument("--json", action="store_true")
    sub.add_parser("tick", help="记一轮（launchd 每分钟调一次）")
    args = parser.parse_args(argv)

    if args.cmd == "tick":
        print(json.dumps(tick(), ensure_ascii=False))
        return 0
    base = data_dir()
    try:
        if args.cmd == "at":
            when = parse_when(args.when)
            row = row_at(base, when)
            if row is None:
                print(f"没有 {args.when} 之前的占用记录（目录 {base}）", file=sys.stderr)
                return 1
            print(json.dumps(row, ensure_ascii=False) if args.json else format_occupancy(row))
            return 0
        since = parse_when(args.since)
        until = parse_when(args.until) if args.until else None
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    rows = runs_between(base, since, until)
    for row in rows:
        print(json.dumps(row, ensure_ascii=False) if args.json else format_run(row))
    if not rows and not args.json:
        print("这段时间没有派工记录", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
