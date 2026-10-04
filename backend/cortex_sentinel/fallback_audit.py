#!/usr/bin/env python3
"""落兜底档对账：免费窗里派工器没选 ZCode、落到小米或别的通道的那一行，当时号是不是真满了。

Falcon 10-04 01:3x：满了落小米是正常的冗余设计，怕的是没满就选过去了。
派工器（Cortex 主线 #5888 起）每次落兜底档，往各机主检出 logs/dispatch-fallback.jsonl 追加一行：
北京时刻、票号、选中谁、四个号各自的占用与帽、读数来源、判满理由。这里每分钟把三台的行合起来，
每一行拿同一分钟占用记录里四个号的真在跑数比：某个号真在跑 < 它的帽（预占不算在跑）就判误选，
记进 ~/Library/Application Support/CortexSentinel/occupancy/fallback-audit-YYYY-MM-DD.jsonl。

只读：本机直接读自己主检出的那份，Pro / mini 用 ssh 只读 tail 对方的那份，不写对方任何东西。
查询：sentinel-occupancy fallback-audit [--day 今天] [--local] [--report-only] [--json]
"""

from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Sequence

try:
    from . import occupancy as occ
    from . import review as rv
except ImportError:  # 直接当脚本跑
    import occupancy as occ  # type: ignore
    import review as rv  # type: ignore

SCHEMA = 1
FALLBACK_LOG = "dispatch-fallback.jsonl"
# 各机主检出的位置（他给的口径：Pro、mini 是 Documents/Code/cortex，M1 Max 是 Documents/code/cortex）。
CHECKOUT_REL = {"pro": "Documents/Code/cortex", "mini": "Documents/Code/cortex", "m1max": "Documents/code/cortex"}
PEER_TAIL_LINES = 400
PEER_TIMEOUT = 20
# 兜底行写下后，同一分钟的占用记录最迟这么久会到；等不到就记「没法判」，不卡着。
DEFER = timedelta(minutes=3)
LOOKBACK_DAYS = 1  # 只审昨天和今天的行


def audit_file(base: Path, day: str) -> Path:
    return base / f"fallback-audit-{day}.jsonl"


def is_mimo(picked: Mapping[str, Any]) -> bool:
    text = f"{picked.get('model') or ''} {picked.get('name') or ''}".lower()
    return "mimo" in text or "小米" in text


def line_time(line: Mapping[str, Any]) -> Optional[datetime]:
    raw = str(line.get("ts_beijing") or "").strip()
    try:
        moment = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=occ.BEIJING)
    return moment.astimezone(occ.BEIJING)


def line_key(line: Mapping[str, Any]) -> str:
    picked = line.get("picked") or {}
    return "|".join(str(x) for x in (line.get("ts_beijing"), line.get("_machine"), picked.get("id"),
                                     line.get("ticket"), line.get("slug")))


# ---------------------------------------------------------------- 读三台的兜底行（只读）

def local_log_path() -> Path:
    return Path(occ.checkout_base()) / "logs" / FALLBACK_LOG


def read_local(path: Optional[Path] = None) -> list[dict[str, Any]]:
    rows = occ.read_jsonl(path or local_log_path())
    machine = rv.local_machine()
    return [{**row, "_machine": machine} for row in rows]


def peer_machine_word(alias: str) -> str:
    for word, name in rv.PEER_ALIASES.items():
        if name == alias:
            return word
    return "pro"


def read_peer(alias: str, *, runner: Callable[..., tuple[Optional[str], Optional[str]]] = occ._run,
              ) -> tuple[list[dict[str, Any]], Optional[str]]:
    """ssh 只读 tail 对方主检出的兜底档；文件还没有不算错（派工器没落过兜底档就没有这个文件）。"""
    word = peer_machine_word(alias)
    rel = CHECKOUT_REL.get(word, CHECKOUT_REL["pro"])
    script = f'tail -n {PEER_TAIL_LINES} "$HOME/{rel}/logs/{FALLBACK_LOG}" 2>/dev/null; true'
    out, err = runner(rv.SSH_BASE + [alias, script], timeout=PEER_TIMEOUT)
    if out is None:
        return [], err or "读不到"
    return [{**row, "_machine": word} for row in rv.parse_jsonl_text(out)], None


def gather_lines(*, peers: bool = True, local_path: Optional[Path] = None,
                 reader: Callable[[str], tuple[list, Optional[str]]] = read_peer,
                 aliases: Optional[Sequence[str]] = None,
                 ) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    """三台合起来：(兜底行, 读到的机器, 没读到的机器说明)。"""
    lines = read_local(local_path)
    read_from, missed = ["本机"], []
    if peers:
        targets = list(aliases) if aliases is not None else rv.peer_aliases()
        with ThreadPoolExecutor(max_workers=4) as pool:
            for alias, (rows, err) in zip(targets, pool.map(reader, targets)):
                if err:
                    missed.append(f"{alias}（{str(err)[-80:]}）")
                    continue
                lines += rows
                read_from.append(alias)
    seen: set[str] = set()
    unique = []
    for line in lines:
        key = line_key(line)
        if key not in seen:
            seen.add(key)
            unique.append(line)
    return unique, read_from, missed


# ---------------------------------------------------------------- 判

def occupancy_row_for(base: Path, moment: datetime) -> Optional[dict[str, Any]]:
    """同一分钟的占用记录（一分钟里有几行取最后一行）；那一分钟没有就是 None。"""
    minute = moment.astimezone(occ.BEIJING).strftime("%Y-%m-%d %H:%M")
    day = minute[:10]
    rows = [r for r in occ.read_jsonl(occ.occupancy_file(base, day)) if str(r.get("ts_bj") or "").startswith(minute)]
    return max(rows, key=lambda r: str(r.get("ts_bj"))) if rows else None


def judge(line: Mapping[str, Any], row: Optional[Mapping[str, Any]], *, now: datetime) -> dict[str, Any]:
    """一行兜底行 + 同一分钟占用记录 → 对账结果。

    真在跑数取占用记录里的 plans[号].running（面板读数，跟派工器同一个号账读方，预占不在里面）；
    帽取派工器当时记的 cap（行里没有号账视图就取占用记录里的）。某个号 cap>0 且真在跑 < cap，就是有空位。"""
    picked = line.get("picked") or {}
    when = line_time(line)
    line_accounts = line.get("accounts") if isinstance(line.get("accounts"), Mapping) else None
    result: dict[str, Any] = {
        "schema": SCHEMA,
        "ts_bj": occ.fmt_bj(when) if when else str(line.get("ts_beijing")),
        "audited_bj": occ.fmt_bj(now),
        "from_machine": line.get("_machine"),
        "ticket": line.get("ticket") or "",
        "slug": line.get("slug") or "",
        "picked": {"name": picked.get("name"), "id": picked.get("id"), "model": picked.get("model"),
                   "machine": picked.get("machine")},
        "to_mimo": is_mimo(picked),
        "free_window": line.get("free_window"),
        "view_missing": line_accounts is None,
        "line_reason": str(line.get("reason") or "")[:300],
    }
    if row is None:
        result.update({"match": "无同分钟占用记录", "occupancy_ts": None, "accounts": {}, "open_accounts": [],
                       "misselect": None, "reserve_only": False})
        return result
    plans = row.get("plans") or {}
    accounts: dict[str, Any] = {}
    open_accounts: list[dict[str, Any]] = []
    for account in sorted(set((line_accounts or {}).keys()) | set(plans.keys())):
        seen = (line_accounts or {}).get(account) or {}
        plan = plans.get(account) or {}
        real = plan.get("running")
        cap = seen.get("cap") if seen.get("cap") is not None else plan.get("cap")
        if real is None or cap is None:
            accounts[account] = {"real_running": real, "cap": cap, "note": "读数缺，不判这个号"}
            continue
        reserved = int(seen.get("reserved") or 0)
        entry = {"line_running": seen.get("running"), "real_running": int(real), "cap": int(cap), "reserved": reserved}
        accounts[account] = entry
        if int(cap) > 0 and int(real) < int(cap):
            blockers = [str(code) for code, _detail in (seen.get("busy_reasons") or []) if str(code) != "account_parallel"]
            open_accounts.append({"account": account, "running": int(real), "cap": int(cap), "reserved": reserved,
                                  "blockers": blockers})
    result.update({
        "match": "同一分钟", "occupancy_ts": row.get("ts_bj"), "accounts": accounts, "open_accounts": open_accounts,
        "misselect": bool(open_accounts),
        # 预占不算在跑：有空位就照判误选；占用加预占已经撑满的单独标出来，让人知道是预占挡的
        "reserve_only": bool(open_accounts) and all(
            a["reserved"] > 0 and a["running"] + a["reserved"] >= a["cap"] for a in open_accounts),
    })
    return result


def audit(base: Path, lines: Sequence[Mapping[str, Any]], *, now: Optional[datetime] = None) -> dict[str, Any]:
    """没审过的兜底行各出一条对账结果追加进当天文件（按行的北京日期分文件，按行去重）。"""
    now = now or datetime.now(timezone.utc)
    now_bj = occ.to_beijing(now)
    cutoff = (now_bj - timedelta(days=LOOKBACK_DAYS)).strftime("%Y-%m-%d")
    done: dict[str, set[str]] = {}

    def keys_for(day: str) -> set[str]:
        if day not in done:
            done[day] = {str(r.get("_key")) for r in occ.read_jsonl(audit_file(base, day))}
        return done[day]

    added = deferred = 0
    for line in sorted(lines, key=lambda l: str(l.get("ts_beijing"))):
        when = line_time(line)
        if when is None:
            continue
        day = when.strftime("%Y-%m-%d")
        key = line_key(line)
        if day < cutoff or key in keys_for(day):
            continue
        row = occupancy_row_for(base, when)
        if row is None and now_bj - when < DEFER:
            deferred += 1
            continue
        result = judge(line, row, now=now)
        result["_key"] = key
        occ.append_jsonl(audit_file(base, day), result)
        keys_for(day).add(key)
        added += 1
    return {"added": added, "deferred": deferred}


# ---------------------------------------------------------------- 报

def report(base: Path, day: str) -> dict[str, Any]:
    rows = occ.read_jsonl(audit_file(base, day))
    mis = [r for r in rows if r.get("misselect") is True]
    return {
        "day": day, "total": len(rows), "to_mimo": sum(1 for r in rows if r.get("to_mimo")),
        "misselect": len(mis), "unjudged": sum(1 for r in rows if r.get("misselect") is None),
        "misselect_rows": mis, "blocked_misselect": sum(
            1 for r in mis if any(a.get("blockers") for a in r.get("open_accounts") or [])),
    }


def format_report(rep: Mapping[str, Any], read_from: Sequence[str] = (), missed: Sequence[str] = ()) -> str:
    lines = [f"兜底对账 {rep['day']}（北京）：落兜底档 {rep['total']} 次，其中落小米 {rep['to_mimo']} 次；"
             f"误选 {rep['misselect']} 次；没法判 {rep['unjudged']} 次"]
    for r in rep["misselect_rows"]:
        picked = r.get("picked") or {}
        who = r.get("ticket") or r.get("slug") or "-"
        open_text = "、".join(
            f"{a['account']} 有空 {a['running']}/{a['cap']}"
            + (f"（预占 {a['reserved']}）" if a.get("reserved") else "")
            + (f"（派工器记的拦因：{'、'.join(a['blockers'])}）" if a.get("blockers") else "")
            for a in r.get("open_accounts") or [])
        extra = "；预占撑满" if r.get("reserve_only") else ""
        extra += "；行里没有号账视图" if r.get("view_missing") else ""
        lines.append(f"  误选 {r['ts_bj'][11:]} {who} → {picked.get('name')}：{open_text}{extra}（占用记录 {r.get('occupancy_ts')}）")
    if rep.get("blocked_misselect"):
        lines.append(f"  其中 {rep['blocked_misselect']} 次派工器当时另记了别的拦因，上面括号里有")
    if rep["unjudged"]:
        lines.append(f"  没法判的是同一分钟没有占用记录（或记录超过 {int(DEFER.total_seconds() // 60)} 分钟仍没到）的行")
    if len(read_from) > 1 or missed:
        lines.append(f"（合看：{'、'.join(read_from)}）")
    lines += [f"没读到：{m}" for m in missed]
    return "\n".join(lines)


def parse_day(text: str, now: Optional[datetime] = None) -> str:
    now_bj = occ.to_beijing(now or datetime.now(timezone.utc))
    word = text.strip()
    if word in ("今天", "today", ""):
        return now_bj.strftime("%Y-%m-%d")
    if word in ("昨天", "yesterday"):
        return (now_bj - timedelta(days=1)).strftime("%Y-%m-%d")
    datetime.strptime(word, "%Y-%m-%d")
    return word


def run_cli(args: Any, base: Path) -> int:
    now = datetime.now(timezone.utc)
    read_from: list[str] = ["本机"]
    missed: list[str] = []
    if not args.report_only:
        lines, read_from, missed = gather_lines(peers=not args.local)
        audit(base, lines, now=now)
    day = parse_day(args.day, now)
    rep = report(base, day)
    if args.json:
        print(json.dumps({**rep, "read_from": read_from, "missed": missed}, ensure_ascii=False))
    else:
        print(format_report(rep, read_from, missed))
    return 0
