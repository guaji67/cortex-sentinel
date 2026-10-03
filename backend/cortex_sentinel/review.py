#!/usr/bin/env python3
"""模型口碑：每张活交回来，验收的窗口顺手记一句「好 / 一般 / 差 + 一句感受」，按模型攒起来。

Falcon 10-04 01:5x：不是跑分、不是派单去测、不是从回执里自动判；是日常用的时候，不同的派工、不同的模型，
做得好、做得坏，像用户好评差评一样一条条攒。所以这里只有人写的评价，程序只负责把「这张票是哪个模型、
哪个执行者、哪台机器、哪个号做的」自动带上，省得评价人去翻。

记录：~/Library/Application Support/CortexSentinel/reviews/reviews.jsonl（一行一条评价，只追加）。
读口复用占用记录那一套：派工记录 dispatch-YYYY-MM-DD.jsonl 里找这张票最近一条 run，找不到再用
`multica issue runs` 现查；pending 读当前 run 状态也走 occupancy 的 fetch_agent_runs。

用法：
    sentinel-review add COR-12366 好 "6.7 分钟一次做对，回执与实物对得上" [--run 前缀] [--by 窗口名] [--model 手填]
    sentinel-review summary [--days 7] [--local]
    sentinel-review pending [--since 今天] [--local]

summary 和 pending 默认三台合看：评价各机写各机的 reviews.jsonl，这里用 ssh（cortex-pro / cortex-mini，
只读 cat 对方的 reviews.jsonl 和派工记录）合起来；连不上的机器在输出里写一行，不静默。pending 另扫看板上
各执行者最近的 run，派工记录里没有的完工票也列出来。--local 只看本机。

只读 Multica，不写看板、不碰钥匙。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence

try:  # 作为包导入（测试、装好的运行时）
    from . import occupancy as occ
except ImportError:  # 直接当脚本跑
    import occupancy as occ  # type: ignore

SCHEMA = 1
GRADES = ("好", "一般", "差")
NOTE_SHOW_CHARS = 40
RECENT_NOTES = 3
IN_FLIGHT = ("queued", "dispatched", "running", "waiting_local_directory")

KEEP_NOTE = (
    "CORTEX-KEEP\n"
    "# 不要删除 · 一定保留 · DO NOT DELETE\n\n"
    "这是模型口碑记录：每张活交回来，验收的窗口写一句好 / 一般 / 差加感受，按模型攒着，\n"
    "留给以后挑模型、派工时看（Falcon 10-04）。清理程序和任何窗口都不要动：\n\n"
    "- reviews.jsonl：一行一条评价，北京时刻、票号、run 号、模型、执行者、机器、号、评价档、感受原句、评价人。\n\n"
    "记：sentinel-review add COR-12345 好|一般|差 \"一句感受\"\n"
    "看：sentinel-review summary [--days 7]；sentinel-review pending\n"
    "（时刻按北京时间。）\n"
)


# ---------------------------------------------------------------- 路径与读写

def reviews_dir() -> Path:
    raw = os.environ.get("CORTEX_SENTINEL_REVIEWS_DIR", "").strip()
    base = Path(raw).expanduser() if raw else (
        Path.home() / "Library" / "Application Support" / "CortexSentinel" / "reviews"
    )
    base.mkdir(parents=True, exist_ok=True)
    keep = base / "不要删除.md"
    if not keep.exists():
        keep.write_text(KEEP_NOTE, encoding="utf-8")
    return base


def reviews_file(base: Path) -> Path:
    return base / "reviews.jsonl"


def normalize_ticket(text: str) -> str:
    raw = (text or "").strip().upper()
    if re.fullmatch(r"\d{3,6}", raw):
        return f"COR-{raw}"
    return raw


def default_reviewer(env: Optional[Mapping[str, str]] = None) -> str:
    """评价人缺省：环境里的窗口名；没有就退到会话号前 8 位（传话能凭它找人）；都读不到写 unknown。"""
    env = os.environ if env is None else env
    for key in ("CORTEX_REVIEWER", "CLAUDE_WINDOW_NAME", "CLAUDE_CODE_WINDOW_NAME",
                "CLAUDE_SESSION_NAME", "CORTEX_WINDOW_NAME"):
        value = (env.get(key) or "").strip()
        if value:
            return value
    sid = (env.get("CLAUDE_CODE_SESSION_ID") or "").strip()
    return f"会话 {sid[:8]}" if sid else "unknown"


def machine_word(name: str) -> str:
    word = occ.machine_word_of_name(name)
    if word == "-" and "ryan" in (name or "").lower():
        return "ryan"
    return word


# ---------------------------------------------------------------- 找这张票的 run

def _dispatch_rows(occ_base: Path, ticket: Optional[str] = None) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(occ_base.glob("dispatch-*.jsonl")):
        for row in occ.read_jsonl(path):
            if ticket is None or str(row.get("ticket") or "").upper() == ticket:
                rows.append(row)
    return rows


def run_from_dispatch(occ_base: Path, ticket: str, run_prefix: str = "") -> Optional[dict[str, Any]]:
    """派工记录里这张票最近一条 run（按创建时刻）；指定 --run 就只认那一条。"""
    rows = _dispatch_rows(occ_base, ticket)
    if run_prefix:
        rows = [r for r in rows if str(r.get("run_id") or "").startswith(run_prefix)]
    if not rows:
        return None
    row = max(rows, key=lambda r: str(r.get("created_bj") or r.get("ts_bj") or ""))
    return {
        "run_id": row.get("run_id"), "model": row.get("model"), "executor": row.get("executor"),
        "executor_id": row.get("executor_id"), "machine": row.get("machine") or machine_word(str(row.get("executor") or "")),
        "account": row.get("account") or "-", "run_created_bj": row.get("created_bj"), "source": "派工记录",
    }


def fetch_agents_all() -> tuple[Optional[list], Optional[str]]:
    """含已归档的执行者：老 run 的执行者可能后来被归档（COR-12366 的 Pro MiMo），清单不带它就查不到模型。"""
    out, err = occ._run([occ.multica_bin(), "agent", "list", "--include-archived", "--output", "json"],
                        env=occ._env(), timeout=30)
    rows = occ._json_from(out)
    if not isinstance(rows, list):
        return None, err or "agent list 解析不了"
    return rows, None


def fetch_issue_runs(ticket: str) -> tuple[Optional[list], Optional[str]]:
    out, err = occ._run([occ.multica_bin(), "issue", "runs", ticket, "--output", "json"],
                        env=occ._env(), timeout=40)
    rows = occ._json_from(out)
    if not isinstance(rows, list):
        return None, err or "issue runs 解析不了"
    return rows, None


def run_from_multica(
    ticket: str, run_prefix: str = "", *,
    occ_base: Optional[Path] = None,
    runs_fn: Callable[[str], tuple[Optional[list], Optional[str]]] = fetch_issue_runs,
    agents_fn: Callable[[], tuple[Optional[list], Optional[str]]] = fetch_agents_all,
) -> Optional[dict[str, Any]]:
    """现查：multica issue runs 最近一条（新到旧），模型和执行者名从 agent 清单取，号从派工记录里同一执行者借。"""
    runs, _err = runs_fn(ticket)
    if not runs:
        return None
    if run_prefix:
        runs = [r for r in runs if str(r.get("id") or "").startswith(run_prefix)]
    if not runs:
        return None
    run = max(runs, key=lambda r: str(r.get("created_at") or ""))
    agents, _err = agents_fn()
    agent = next((a for a in agents or [] if a.get("id") == run.get("agent_id")), {})
    name = str(agent.get("name") or "")
    account = "-"
    if occ_base is not None:
        for row in reversed(_dispatch_rows(occ_base)):
            if row.get("executor_id") == run.get("agent_id") and row.get("account") not in (None, "-"):
                account = str(row["account"])
                break
    created = occ.parse_utc(run.get("created_at"))
    return {
        "run_id": run.get("id"), "model": agent.get("model"), "executor": name or None,
        "executor_id": run.get("agent_id"), "machine": machine_word(name), "account": account,
        "run_created_bj": occ.fmt_bj(created) if created else None, "source": "multica 现查",
    }


def find_run(ticket: str, run_prefix: str, occ_base: Path, **live: Any) -> Optional[dict[str, Any]]:
    return run_from_dispatch(occ_base, ticket, run_prefix) or run_from_multica(
        ticket, run_prefix, occ_base=occ_base, **live)


# ---------------------------------------------------------------- 记一条

def build_review(*, now: datetime, ticket: str, grade: str, note: str, by: str,
                 run: Optional[Mapping[str, Any]], model_override: str = "") -> dict[str, Any]:
    run = run or {}
    return {
        "schema": SCHEMA,
        "ts_bj": occ.fmt_bj(now),
        "ticket": ticket,
        "run_id": run.get("run_id"),
        "model": model_override or run.get("model") or "未知",
        "executor": run.get("executor") or "-",
        "machine": run.get("machine") or "-",
        "account": run.get("account") or "-",
        "grade": grade,
        "note": note.strip(),
        "by": by,
        "run_created_bj": run.get("run_created_bj"),
        "source": run.get("source") or ("手填模型" if model_override else "未找到 run"),
    }


def add_review(
    base: Path, occ_base: Path, *, ticket: str, grade: str, note: str, by: str = "",
    run_prefix: str = "", model_override: str = "", now: Optional[datetime] = None, **live: Any,
) -> dict[str, Any]:
    if grade not in GRADES:
        raise ValueError(f"评价档只能写 {' / '.join(GRADES)}，收到：{grade}")
    if not note.strip():
        raise ValueError("感受不能空：写一句做得好在哪、坏在哪")
    ticket = normalize_ticket(ticket)
    run = find_run(ticket, run_prefix, occ_base, **live)
    if run is None and not model_override:
        raise LookupError(f"{ticket} 派工记录和 multica issue runs 都没找到 run；"
                          f"确实是本机线或别的做法，就加 --model 手填模型")
    row = build_review(now=now or datetime.now(timezone.utc), ticket=ticket, grade=grade, note=note,
                       by=by or default_reviewer(), run=run, model_override=model_override)
    occ.append_jsonl(reviews_file(base), row)
    return row


# ---------------------------------------------------------------- 三台合看（ssh 只读 cat）

PEER_ALIASES = {"pro": "cortex-pro", "mini": "cortex-mini", "m1max": "cortex-m1max"}
SSH_BASE = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
PEER_TIMEOUT = 30


def local_machine() -> str:
    """本机是三台里哪台：环境变量优先；Pro、mini 的主机名带 Cortex-Pro / Mac-mini，其余按 M1 Max。"""
    forced = os.environ.get("CORTEX_SENTINEL_MACHINE", "").strip().lower()
    if forced in PEER_ALIASES:
        return forced
    host = socket.gethostname().lower()
    if host.startswith("cortex-pro"):
        return "pro"
    if "mac-mini" in host:
        return "mini"
    return "m1max"


def peer_aliases() -> list[str]:
    raw = os.environ.get("CORTEX_SENTINEL_PEERS", "").strip()
    if raw:
        return [a.strip() for a in raw.split(",") if a.strip()]
    me = local_machine()
    return [alias for word, alias in PEER_ALIASES.items() if word != me]


def parse_jsonl_text(text: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("@@"):
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue
        if isinstance(value, dict):
            rows.append(value)
    return rows


def read_peer(alias: str, dispatch_days: Sequence[str], *,
              runner: Callable[..., tuple[Optional[str], Optional[str]]] = occ._run,
              ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], Optional[str]]:
    """只读 cat 对方的评价记录和（要的话）派工记录；不写对方任何东西。返回 (评价, 派工行, 错误说明)。"""
    files = " ".join(f'"$D/occupancy/dispatch-{day}.jsonl"' for day in dispatch_days)
    script = (
        'D="$HOME/Library/Application Support/CortexSentinel"; '
        'echo "@@reviews"; cat "$D/reviews/reviews.jsonl" 2>/dev/null; echo; '
        f'echo "@@dispatch"; for f in {files}; do cat "$f" 2>/dev/null; echo; done; true'
    ) if dispatch_days else (
        'D="$HOME/Library/Application Support/CortexSentinel"; '
        'echo "@@reviews"; cat "$D/reviews/reviews.jsonl" 2>/dev/null; echo; true'
    )
    out, err = runner(SSH_BASE + [alias, script], timeout=PEER_TIMEOUT)
    if out is None:
        return [], [], err or "读不到"
    head, _sep, tail = out.partition("@@dispatch")
    return parse_jsonl_text(head), parse_jsonl_text(tail), None


def dedupe(rows: Sequence[Mapping[str, Any]], key: Callable[[Mapping[str, Any]], Any]) -> list[dict[str, Any]]:
    seen: set = set()
    result: list[dict[str, Any]] = []
    for row in rows:
        k = key(row)
        if k in seen:
            continue
        seen.add(k)
        result.append(dict(row))
    return result


def review_key(row: Mapping[str, Any]) -> tuple:
    return (row.get("ts_bj"), row.get("ticket"), row.get("by"), row.get("note"))


def gather(base: Path, occ_base: Path, *, since: Optional[datetime] = None, peers: bool = True,
           now: Optional[datetime] = None, reader: Callable[..., Any] = read_peer,
           aliases: Optional[Sequence[str]] = None,
           ) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[str], list[str]]:
    """本机 + 对方两台合起来：(评价, 派工行, 读到的机器, 没读到的机器说明)。since 给了才读派工行。"""
    reviews = read_reviews(base)
    rows: list[dict[str, Any]] = []
    days: list[str] = []
    if since is not None:
        rows = occ.runs_between(occ_base, since)
        last = occ.to_beijing(now or datetime.now(timezone.utc)).date()
        day = since.date()
        while day <= last:
            days.append(day.strftime("%Y-%m-%d"))
            day += timedelta(days=1)
    read_from, missed = ["本机"], []
    if peers:
        targets = list(aliases) if aliases is not None else peer_aliases()
        with ThreadPoolExecutor(max_workers=4) as pool:
            for alias, (p_rev, p_rows, err) in zip(targets, pool.map(lambda a: reader(a, days), targets)):
                if err:
                    missed.append(f"{alias}（{err[-80:]}）")
                    continue
                reviews += p_rev
                rows += p_rows
                read_from.append(alias)
    return (dedupe(reviews, review_key), dedupe(rows, lambda r: r.get("run_id")), read_from, missed)


# ---------------------------------------------------------------- 看板兜底

BOARD_RUNS_PER_AGENT = 200


def fetch_board_runs(agent_id: str) -> tuple[Optional[list], Optional[str]]:
    out, err = occ._run([occ.multica_bin(), "agent", "tasks", agent_id, "--limit", str(BOARD_RUNS_PER_AGENT),
                         "--output", "json"], env=occ._env(), timeout=40)
    rows = occ._json_from(out)
    if not isinstance(rows, list):
        return None, err or "agent tasks 解析不了"
    return rows, None


def board_rows(
    agents: Sequence[Mapping[str, Any]], board: Mapping[str, Sequence[Mapping[str, Any]]],
    known_run_ids: set, since: datetime, issue_cache: dict[str, str],
    lookup_issue: Callable[[str], Optional[str]] = occ.fetch_issue_identifier,
) -> list[dict[str, Any]]:
    """派工记录里没有的 run 补成行：时段内完工的、还在飞的。票号先翻占用记录的票号缓存，没有再 issue get。"""
    start = occ.fmt_bj(since)
    picked: list[tuple[Mapping[str, Any], Mapping[str, Any]]] = []
    for agent in agents:
        for run in board.get(str(agent.get("id")), []) or []:
            if str(run.get("id")) in known_run_ids:
                continue
            status = str(run.get("status") or "")
            finished = occ.parse_utc(run.get("completed_at"))
            done = status == "completed" and finished is not None and occ.fmt_bj(finished) >= start
            if done or status in IN_FLIGHT:
                picked.append((agent, run))
    missing = sorted({str(r.get("issue_id") or "") for _a, r in picked} - set(issue_cache) - {""})
    if missing:
        with ThreadPoolExecutor(max_workers=8) as pool:
            for issue_id, found in zip(missing, pool.map(lookup_issue, missing)):
                if found:
                    issue_cache[issue_id] = found
    rows = []
    for agent, run in picked:
        issue_id = str(run.get("issue_id") or "")
        name = str(agent.get("name") or "")
        created = occ.parse_utc(run.get("created_at"))
        rows.append({
            "run_id": run.get("id"), "ticket": issue_cache.get(issue_id) or issue_id[:8], "model": agent.get("model"),
            "executor": name, "executor_id": agent.get("id"), "machine": machine_word(name), "account": "-",
            "created_bj": occ.fmt_bj(created) if created else None, "source": "看板",
        })
    return rows


# ---------------------------------------------------------------- summary

def read_reviews(base: Path) -> list[dict[str, Any]]:
    return occ.read_jsonl(reviews_file(base))


def clip(text: str, limit: int = NOTE_SHOW_CHARS) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def latest_per_run(rows: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """同一张票同一条 run 只留最新一条评价（后评覆盖前评，旧行留在文件里不删）。
    补评、翻案都靠再 add 一条；汇总只认最新，不让同一次活算两回。"""
    latest: dict[tuple[str, str], Mapping[str, Any]] = {}
    for row in sorted(rows, key=lambda r: str(r.get("ts_bj") or "")):
        latest[(str(row.get("ticket") or "").upper(), str(row.get("run_id") or ""))] = row
    return list(latest.values())


def summarize(rows: Sequence[Mapping[str, Any]], *, now: datetime, days: int = 7) -> list[dict[str, Any]]:
    start = occ.fmt_bj(now - timedelta(days=days))
    by_model: dict[str, list[Mapping[str, Any]]] = {}
    for row in latest_per_run(rows):
        if str(row.get("ts_bj") or "") >= start:
            by_model.setdefault(str(row.get("model") or "未知"), []).append(row)
    result = []
    for model, items in by_model.items():
        items = sorted(items, key=lambda r: str(r.get("ts_bj") or ""), reverse=True)
        counts = {g: sum(1 for r in items if r.get("grade") == g) for g in GRADES}
        result.append({
            "model": model, "good": counts["好"], "ok": counts["一般"], "bad": counts["差"], "total": len(items),
            "recent": [{"ticket": r.get("ticket"), "grade": r.get("grade"), "note": clip(str(r.get("note") or ""))}
                       for r in items[:RECENT_NOTES]],
        })
    return sorted(result, key=lambda r: (-r["total"], r["model"]))


def format_sources(read_from: Sequence[str], missed: Sequence[str]) -> list[str]:
    lines = [f"（合看：{'、'.join(read_from)}）"] if len(read_from) > 1 or missed else []
    lines += [f"没读到：{m}" for m in missed]
    return lines


def format_summary(entries: Sequence[Mapping[str, Any]], days: int,
                   read_from: Sequence[str] = (), missed: Sequence[str] = ()) -> str:
    if not entries:
        return "\n".join([f"最近 {days} 天没有评价"] + format_sources(read_from, missed))
    lines = [f"模型口碑（最近 {days} 天，北京时间）"]
    for e in entries:
        recent = " / ".join(f"{r['ticket']} {r['grade']}：{r['note']}" for r in e["recent"])
        lines.append(f"{e['model']}  好 {e['good']} / 一般 {e['ok']} / 差 {e['bad']}  最近：{recent}")
    return "\n".join(lines + format_sources(read_from, missed))


# ---------------------------------------------------------------- pending

def fetch_current_runs(
    rows: Sequence[Mapping[str, Any]], *,
    seed: Optional[Mapping[str, Mapping[str, Any]]] = None,
    agent_runs_fn: Callable[[str], tuple[Optional[list], Optional[str]]] = occ.fetch_agent_runs,
    issue_runs_fn: Callable[[str], tuple[Optional[list], Optional[str]]] = fetch_issue_runs,
) -> dict[str, dict[str, Any]]:
    """派工行里每条 run 的当前状态：有 seed（整个看板扫出来的 run）就直接用；没有就先按执行者批量取
    （占用记录同一个读方）。都没覆盖到的（执行者 run 太多、翻出了窗口）再按票现查。"""
    current: dict[str, dict[str, Any]] = {k: dict(v) for k, v in (seed or {}).items()}
    with ThreadPoolExecutor(max_workers=8) as pool:
        if seed is None:
            agent_ids = sorted({str(r.get("executor_id") or "") for r in rows} - {""})
            for runs, _err in pool.map(agent_runs_fn, agent_ids):
                for run in runs or []:
                    current[str(run.get("id"))] = run
        missing = sorted({str(r.get("ticket") or "") for r in rows
                          if str(r.get("run_id") or "") not in current} - {""})
        for runs, _err in pool.map(issue_runs_fn, missing):
            for run in runs or []:
                current[str(run.get("id"))] = run
    return current


def compute_pending(
    rows: Sequence[Mapping[str, Any]], current: Mapping[str, Mapping[str, Any]], reviewed: set[str],
) -> tuple[list[dict[str, Any]], int]:
    """已完工、没有任何评价的票。票上还有 run 在飞的（评论叫醒又起了一轮）算没交回，不进清单，只报个数。"""
    by_ticket: dict[str, list[Mapping[str, Any]]] = {}
    for row in rows:
        by_ticket.setdefault(str(row.get("ticket") or ""), []).append(row)
    pending: list[dict[str, Any]] = []
    in_flight = 0
    for ticket, items in by_ticket.items():
        if not ticket or ticket in reviewed:
            continue
        states = [(row, current.get(str(row.get("run_id")))) for row in items]
        if any(run and str(run.get("status")) in IN_FLIGHT for _row, run in states):
            in_flight += 1
            continue
        done = [(row, run) for row, run in states if run and run.get("status") == "completed" and run.get("completed_at")]
        if not done:
            continue
        row, run = max(done, key=lambda pair: str(pair[1].get("completed_at")))
        finished = occ.parse_utc(run.get("completed_at"))
        pending.append({
            "ticket": ticket, "model": row.get("model") or "未知", "executor": row.get("executor"),
            "machine": row.get("machine"), "completed_bj": occ.fmt_bj(finished) if finished else None,
            "run_id": row.get("run_id"),
        })
    return sorted(pending, key=lambda p: str(p["completed_bj"])), in_flight


def parse_since(text: str, now: Optional[datetime] = None) -> datetime:
    now_bj = occ.to_beijing(now or datetime.now(timezone.utc))
    midnight = now_bj.replace(hour=0, minute=0, second=0, microsecond=0)
    word = text.strip()
    if word in ("今天", "today"):
        return midnight
    if word in ("昨天", "yesterday"):
        return midnight - timedelta(days=1)
    return occ.parse_when(word, today=now)


def format_pending(items: Sequence[Mapping[str, Any]], in_flight: int, since: datetime,
                   read_from: Sequence[str] = (), missed: Sequence[str] = ()) -> str:
    head = f"待评价（{occ.fmt_bj(since)} 起已完工、还没评价的票）"
    lines = [head] if items else [head + "：没有"]
    for p in items:
        lines.append(f"{p['ticket']}  {p['model']}  完工 {p['completed_bj']}  {p.get('executor') or '-'}")
    if in_flight:
        lines.append(f"（另有 {in_flight} 张票还有 run 在跑，没算交回）")
    return "\n".join(lines + format_sources(read_from, missed))


# ---------------------------------------------------------------- 命令行

def collect_pending(base: Path, occ_base: Path, since: datetime, now: datetime, *, peers: bool = True,
                    ) -> tuple[list[dict[str, Any]], int, list[str], list[str]]:
    """三台派工记录 + 看板各执行者最近的 run，合起来判：已完工、没评价的票。"""
    # 往前多翻一天的派工行，昨晚起的、今天凌晨才交回的也不漏；最后再按完工时刻卡 since。
    reviews, rows, read_from, missed = gather(base, occ_base, since=since - timedelta(days=1), peers=peers, now=now)
    # 含归档的执行者一起扫：零点前完工的票常是后来被归档的执行者做的。
    live, _err_agents = fetch_agents_all()
    agents = live
    live = list(live or [])
    board: dict[str, Sequence[Mapping[str, Any]]] = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        for agent, (runs, _e) in zip(live, pool.map(lambda a: fetch_board_runs(str(a["id"])), live)):
            if runs is not None:
                board[str(agent["id"])] = runs
            else:
                missed.append(f"看板：{agent.get('name')} 的 run 读不到")
    if agents is None:
        missed.append("看板：agent 清单读不到，只用派工记录判")
    state = occ.load_state(occ_base)
    extra = board_rows(live, board, {str(r.get("run_id")) for r in rows}, since, state["issues"])
    rows = rows + extra
    seed = {str(run.get("id")): run for runs in board.values() for run in runs}
    current = fetch_current_runs(rows, seed=seed)
    reviewed = {str(r.get("ticket") or "").upper() for r in reviews}
    items, in_flight = compute_pending(rows, current, reviewed)
    items = [p for p in items if str(p["completed_bj"]) >= occ.fmt_bj(since)]
    return items, in_flight, read_from, missed


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="sentinel-review", description="模型口碑：交回来的活记一句好 / 一般 / 差（北京时间）")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_add = sub.add_parser("add", help="给一张票记一条评价")
    p_add.add_argument("ticket")
    p_add.add_argument("grade", choices=GRADES)
    p_add.add_argument("note", help="一句感受")
    p_add.add_argument("--run", default="", help="run 号前缀；缺省取这张票最近一条")
    p_add.add_argument("--by", default="", help="评价人窗口名；缺省读环境里的会话名")
    p_add.add_argument("--model", default="", help="找不到 run 时手填模型")
    p_sum = sub.add_parser("summary", help="按模型汇总（默认三台合看）")
    p_sum.add_argument("--days", type=int, default=7)
    p_sum.add_argument("--local", action="store_true", help="只看本机")
    p_sum.add_argument("--json", action="store_true")
    p_pen = sub.add_parser("pending", help="已完工还没评价的票（默认三台合看 + 看板兜底）")
    p_pen.add_argument("--since", default="今天")
    p_pen.add_argument("--local", action="store_true", help="只看本机派工记录")
    p_pen.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    base, occ_base = reviews_dir(), occ.data_dir()
    now = datetime.now(timezone.utc)
    try:
        if args.cmd == "add":
            row = add_review(base, occ_base, ticket=args.ticket, grade=args.grade, note=args.note,
                             by=args.by, run_prefix=args.run, model_override=args.model, now=now)
            run_short = str(row.get("run_id") or "-")[:8]
            print(f"已记 {row['ticket']} {row['grade']}  模型 {row['model']}  {row['executor']}@{row['machine']}"
                  f"  号 {row['account']}  run {run_short}（{row['source']}）  评价人 {row['by']}")
            return 0
        if args.cmd == "summary":
            reviews, _rows, read_from, missed = gather(base, occ_base, peers=not args.local)
            entries = summarize(reviews, now=now, days=args.days)
            if args.json:
                print(json.dumps({"models": entries, "read_from": read_from, "missed": missed}, ensure_ascii=False))
            else:
                print(format_summary(entries, args.days, read_from, missed))
            return 0
        since = parse_since(args.since, now)
    except (ValueError, LookupError) as exc:
        print(str(exc), file=sys.stderr)
        return 2

    items, in_flight, read_from, missed = collect_pending(base, occ_base, since, now, peers=not args.local)
    if args.json:
        print(json.dumps({"pending": items, "in_flight": in_flight, "read_from": read_from, "missed": missed},
                         ensure_ascii=False))
    else:
        print(format_pending(items, in_flight, since, read_from, missed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
