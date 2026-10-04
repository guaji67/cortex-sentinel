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
    sentinel-review list [--model 小米|spark|glm] [--grade 差|一般|好] [--days 7]   一行一条，看谁为什么打的这个档
    sentinel-review add - 差 "为什么" --task "当时干了啥" --model 模型名            没有票号的活
    sentinel-review void COR-12153 --run 01a1009f --by 窗口名 "原因"     作废那条 run 上的评价，汇总整条不算
    sentinel-review reverify-models [--apply] [--match 正则]   一次性重核评价里的模型，按 run 实际用的重算
    sentinel-review summary [--days 7] [--local]
    sentinel-review pending [--since 今天] [--local]

add 不带 --run 时取这张票最近一条真跑完的 run（完工状态、有实际用时），没开跑就撤的、被取消的、失败的跳过；
要评那些，明写 --run。

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


SESSION_TAIL_BYTES = 2_000_000


def _tail_text(path: Path, nbytes: int = SESSION_TAIL_BYTES) -> str:
    try:
        with open(path, "rb") as handle:
            handle.seek(0, 2)
            size = handle.tell()
            handle.seek(max(0, size - nbytes))
            return handle.read().decode("utf-8", "replace")
    except OSError:
        return ""


def claude_session_info(env: Mapping[str, str], home: Optional[Path] = None) -> dict[str, str]:
    """Claude Code 窗口：凭环境里的会话号找 ~/.claude/projects/*/<会话号>.jsonl，读最后一条助手消息的 model
    和窗口标题（agent-name / custom-title）。找不到或读不到返回空串，不报错。"""
    sid = (env.get("CLAUDE_CODE_SESSION_ID") or "").strip()
    info = {"model": "", "title": ""}
    if not sid or "/" in sid:
        return info
    root = (home or Path.home()) / ".claude" / "projects"
    for path in sorted(root.glob(f"*/{sid}.jsonl")):
        for line in _tail_text(path).splitlines():
            if '"assistant"' not in line and '"agent-name"' not in line and '"custom-title"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            kind = row.get("type")
            if kind == "assistant":
                model = norm_model((row.get("message") or {}).get("model"))
                if model and model != "<synthetic>":
                    info["model"] = model
            elif kind in ("agent-name", "custom-title"):
                title = str(row.get("agentName") or row.get("customTitle") or "").strip()
                if title:
                    info["title"] = title
        break
    return info


def codex_session_model(env: Mapping[str, str], home: Optional[Path] = None) -> str:
    """Codex 窗口：凭线程号找 ~/.codex/sessions/*/*/*/rollout-*-<线程号>.jsonl，读最后一条 turn_context 的 model。"""
    sid = (env.get("CODEX_THREAD_ID") or env.get("CODEX_SESSION_ID") or "").strip()
    if not sid or "/" in sid:
        return ""
    root = (home or Path.home()) / ".codex" / "sessions"
    for path in sorted(root.glob(f"*/*/*/rollout-*-{sid}.jsonl")):
        model = ""
        for line in _tail_text(path).splitlines():
            if '"turn_context"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            model = str((row.get("payload") or {}).get("model") or model)
        return model
    return ""


def default_reviewer(env: Optional[Mapping[str, str]] = None, home: Optional[Path] = None) -> str:
    """评价人缺省：环境里的窗口名；没有就读 Claude Code 会话记录里的窗口标题（带 @机器）；
    再退到会话号前 8 位；都读不到写 unknown。"""
    env = os.environ if env is None else env
    for key in ("CORTEX_REVIEWER", "CLAUDE_WINDOW_NAME", "CLAUDE_CODE_WINDOW_NAME",
                "CLAUDE_SESSION_NAME", "CORTEX_WINDOW_NAME"):
        value = (env.get(key) or "").strip()
        if value:
            return value
    title = claude_session_info(env, home)["title"]
    if title:
        return f"{title}@{local_machine()}"
    sid = (env.get("CLAUDE_CODE_SESSION_ID") or "").strip()
    return f"会话 {sid[:8]}" if sid else "unknown"


def default_reviewer_model(env: Optional[Mapping[str, str]] = None, home: Optional[Path] = None) -> str:
    """评价者自己是哪个模型：环境变量显式给的优先；Claude Code 读会话记录最后一条助手消息，Codex 读 turn_context；
    都读不到返回空串，不报错、不强求。"""
    env = os.environ if env is None else env
    for key in ("CORTEX_REVIEWER_MODEL", "ANTHROPIC_MODEL", "CLAUDE_CODE_MODEL", "CLAUDE_MODEL",
                "CODEX_MODEL", "OPENAI_MODEL"):
        value = (env.get(key) or "").strip()
        if value:
            return value
    return claude_session_info(env, home)["model"] or codex_session_model(env, home)


NO_TICKET_WORDS = ("-", "无", "无票", "none")
TITLES_NAME = "task-titles.json"


def fetch_issue_title(ticket: str) -> Optional[str]:
    """票面标题：multica issue get 现查，只读。"""
    out, _err = occ._run([occ.multica_bin(), "issue", "get", ticket, "--output", "json"], env=occ._env(), timeout=20)
    data = occ._json_from(out)
    if isinstance(data, dict) and data.get("title"):
        return str(data["title"]).strip()
    return None


def load_titles(base: Path) -> dict[str, str]:
    path = base / TITLES_NAME
    try:
        value = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    except ValueError:
        value = {}
    return {str(k): str(v) for k, v in value.items()} if isinstance(value, dict) else {}


def save_titles(base: Path, titles: Mapping[str, str]) -> None:
    tmp = base / (TITLES_NAME + ".tmp")
    tmp.write_text(json.dumps(titles, ensure_ascii=False, indent=0), encoding="utf-8")
    tmp.replace(base / TITLES_NAME)


def resolve_titles(base: Path, tickets: Sequence[str], *,
                   title_fn: Optional[Callable[[str], Optional[str]]] = None) -> dict[str, str]:
    """票号 → 标题：先翻本地缓存，缺的并发现查并写回缓存。查不到的不进结果。"""
    titles = load_titles(base)
    missing = sorted({t for t in tickets if t and t not in titles})
    if missing:
        fetch = title_fn or fetch_issue_title
        with ThreadPoolExecutor(max_workers=8) as pool:
            for ticket, found in zip(missing, pool.map(fetch, missing)):
                if found:
                    titles[ticket] = found
        save_titles(base, titles)
    return {t: titles[t] for t in tickets if t in titles}


def machine_word(name: str) -> str:
    word = occ.machine_word_of_name(name)
    if word == "-" and "ryan" in (name or "").lower():
        return "ryan"
    return word


# ---------------------------------------------------------------- 模型：以那条 run 实际用的为准

def norm_model(name: Any) -> str:
    """去掉 Claude Code 带的上下文档后缀（如 mimo-v2.6-flash[1m]），同一个模型只留一个写法。"""
    return re.sub(r"\[[^\]]*\]$", "", str(name or "").strip())


def actual_model(run: Mapping[str, Any]) -> Optional[str]:
    """run 实际用的模型：取 run.usage 里有用量的模型，多个就取用量最大的；没有 usage 返回 None。
    执行者的配置会被改回改去（同一个执行者先配 Spark 后改回小米），只有 run 自己的用量记录是当时真用的。"""
    totals: dict[str, int] = {}
    for item in run.get("usage") or []:
        if not isinstance(item, Mapping):
            continue
        name = norm_model(item.get("model"))
        tokens = int(item.get("input_tokens") or 0) + int(item.get("output_tokens") or 0)
        if name and tokens > 0:
            totals[name] = totals.get(name, 0) + tokens
    return max(totals, key=lambda k: totals[k]) if totals else None


def model_label(model: Any) -> str:
    """汇总里显示用：免费 Spark 和付费 Spark（Go 钥匙）分开叫；其余原样。"""
    name = norm_model(model)
    low = name.lower()
    if "muse-spark" in low:
        return "Spark 免费" if "free" in low else "Spark 付费(Go)"
    return name


def effective_ts(row: Mapping[str, Any]) -> str:
    """评价算在哪个时刻：更正行写在更正当时（要盖过旧行），但评价本身发生在 orig_ts_bj。"""
    return str(row.get("orig_ts_bj") or row.get("ts_bj") or "")


# ---------------------------------------------------------------- 找这张票的 run

def _dispatch_rows(occ_base: Path, ticket: Optional[str] = None) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(occ_base.glob("dispatch-*.jsonl")):
        for row in occ.read_jsonl(path):
            if ticket is None or str(row.get("ticket") or "").upper() == ticket:
                rows.append(row)
    return rows


def run_from_dispatch(occ_base: Path, ticket: str, run_prefix: str = "") -> Optional[dict[str, Any]]:
    """现查不通时的退路：派工记录里这张票的 run。指定 --run 就只认那一条；不指定只认记录里已完工的最近一条
    （派工记录只在第一次看见时记状态，没核过用时，来源里写明）。"""
    rows = _dispatch_rows(occ_base, ticket)
    if run_prefix:
        rows = [r for r in rows if str(r.get("run_id") or "").startswith(run_prefix)]
    else:
        rows = [r for r in rows if r.get("status_at_seen") == "completed"]
    if not rows:
        return None
    row = max(rows, key=lambda r: str(r.get("created_bj") or r.get("ts_bj") or ""))
    return {
        "run_id": row.get("run_id"), "model": row.get("model"), "executor": row.get("executor"),
        "executor_id": row.get("executor_id"), "machine": row.get("machine") or machine_word(str(row.get("executor") or "")),
        "account": row.get("account") or "-", "run_created_bj": row.get("created_bj"), "run_seconds": None,
        "model_verified": False,
        "source": "派工记录（现查不通，用时未核，模型未核：执行者配置）",
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


def fmt_opt_bj(text: Any) -> Optional[str]:
    moment = occ.parse_utc(text)
    return occ.fmt_bj(moment) if moment else None


def run_seconds(run: Mapping[str, Any]) -> Optional[int]:
    """实际用时：开跑和完工时刻都有且完工晚于开跑；排队没开跑就被撤的没有。"""
    started, finished = occ.parse_utc(run.get("started_at")), occ.parse_utc(run.get("completed_at"))
    if started is None or finished is None or finished <= started:
        return None
    return int((finished - started).total_seconds())


def pick_finished_run(runs: Sequence[Mapping[str, Any]]) -> Optional[Mapping[str, Any]]:
    """最近一条真跑完的 run：状态是 completed 且有实际用时，按完工时刻取最新。
    没开跑就撤的、被取消的（哪怕跑了很久）、失败的都跳过，要评它们明写 --run。"""
    done = [r for r in runs if str(r.get("status")) == "completed" and run_seconds(r) is not None]
    return max(done, key=lambda r: str(r.get("completed_at"))) if done else None


def describe_run(run: Mapping[str, Any], occ_base: Optional[Path],
                 agents_fn: Callable[[], tuple[Optional[list], Optional[str]]]) -> dict[str, Any]:
    """模型和执行者名从 agent 清单取（含归档），号先按 run 号、再按同一执行者从派工记录里借。"""
    agents, _err = agents_fn()
    agent = next((a for a in agents or [] if a.get("id") == run.get("agent_id")), {})
    name = str(agent.get("name") or "")
    account = "-"
    if occ_base is not None:
        rows = list(reversed(_dispatch_rows(occ_base)))
        for row in rows:
            if row.get("run_id") == run.get("id") and row.get("account") not in (None, "-"):
                account = str(row["account"])
                break
        else:
            for row in rows:
                if row.get("executor_id") == run.get("agent_id") and row.get("account") not in (None, "-"):
                    account = str(row["account"])
                    break
    created = occ.parse_utc(run.get("created_at"))
    actual = actual_model(run)
    return {
        "run_id": run.get("id"), "model": actual or agent.get("model"), "model_verified": actual is not None,
        "executor": name or None,
        "executor_id": run.get("agent_id"), "machine": machine_word(name), "account": account,
        "run_created_bj": occ.fmt_bj(created) if created else None, "run_seconds": run_seconds(run),
        "run_started_bj": fmt_opt_bj(run.get("started_at")), "run_finished_bj": fmt_opt_bj(run.get("completed_at")),
        "source": "multica 现查" if actual else "multica 现查（模型未核：run 没有用量记录，退执行者配置）",
    }


def find_run(
    ticket: str, run_prefix: str, occ_base: Path, *,
    runs_fn: Callable[[str], tuple[Optional[list], Optional[str]]] = fetch_issue_runs,
    agents_fn: Callable[[], tuple[Optional[list], Optional[str]]] = fetch_agents_all,
) -> Optional[dict[str, Any]]:
    """找这张票要评的 run。不带 --run：multica 现查，取最近一条真跑完的（完工状态、有实际用时）；
    带 --run：按前缀认那一条，不管状态。现查不通或没有，再退到派工记录。"""
    runs, _err = runs_fn(ticket)
    if runs:
        if run_prefix:
            matched = [r for r in runs if str(r.get("id") or "").startswith(run_prefix)]
            chosen = max(matched, key=lambda r: str(r.get("created_at") or "")) if matched else None
        else:
            chosen = pick_finished_run(runs)
            if chosen is None:
                states = "、".join(f"{str(r.get('id'))[:8]} {r.get('status')}" for r in runs[:6])
                raise LookupError(f"{ticket} 没有真跑完的 run（完工状态且有实际用时），现有：{states}；"
                                  f"要评别的 run 就写 --run <run 号前缀>")
        if chosen is not None:
            return describe_run(chosen, occ_base, agents_fn)
    return run_from_dispatch(occ_base, ticket, run_prefix)


# ---------------------------------------------------------------- 记一条

def build_review(*, now: datetime, ticket: str, grade: str, note: str, by: str,
                 run: Optional[Mapping[str, Any]], model_override: str = "",
                 task: str = "", task_src: str = "", reviewer_model: str = "") -> dict[str, Any]:
    run = run or {}
    run_id = run.get("run_id")
    if not ticket and not run_id:
        # 没票号的活：给一个不会撞的 run 键，不然几条没票号的评价会按（空票号, 空 run）互相覆盖
        stamp = occ.fmt_bj(now).replace("-", "").replace(":", "").replace(" ", "")
        run_id = f"manual-{stamp}-{abs(hash(task + note)) % 10**6:06d}"
    return {
        "schema": SCHEMA,
        "kind": "review",
        "ts_bj": occ.fmt_bj(now),
        "ticket": ticket,
        "task": task or None,
        "task_src": task_src or None,
        "run_id": run_id,
        "model": norm_model(model_override or run.get("model")) or "未知",
        "executor": run.get("executor") or "-",
        "machine": run.get("machine") or "-",
        "account": run.get("account") or "-",
        "grade": grade,
        "note": note.strip(),
        "by": by,
        "reviewer_model": reviewer_model,
        "run_created_bj": run.get("run_created_bj"),
        "run_secs": run.get("run_seconds"),
        "run_started_bj": run.get("run_started_bj"),
        "run_finished_bj": run.get("run_finished_bj"),
        "model_verified": True if model_override else run.get("model_verified"),
        "source": run.get("source") or ("手填模型" if model_override else "未找到 run"),
    }


def add_review(
    base: Path, occ_base: Path, *, ticket: str, grade: str, note: str, by: str = "",
    run_prefix: str = "", model_override: str = "", task: str = "", reviewer_model: Optional[str] = None,
    now: Optional[datetime] = None, title_fn: Optional[Callable[[str], Optional[str]]] = None,
    env: Optional[Mapping[str, str]] = None, **live: Any,
) -> dict[str, Any]:
    """记一条评价。ticket 写 - 表示没有票号的活：必须带 --task 说明干了啥，也必须手填 --model。
    有票号时任务标题从票面现查（--task 另写了就用手写的）。评价者模型缺省读环境，读不到留空。"""
    if grade not in GRADES:
        raise ValueError(f"评价档只能写 {' / '.join(GRADES)}，收到：{grade}")
    if not note.strip():
        raise ValueError("感受不能空：写一句做得好在哪、坏在哪")
    ticket = "" if ticket.strip().lower() in NO_TICKET_WORDS else normalize_ticket(ticket)
    task = task.strip()
    if not ticket:
        if not task:
            raise ValueError("没有票号的活要用 --task 写清当时干了啥（让人看得出这条评价评的是什么）")
        if not model_override:
            raise LookupError("没有票号找不到 run，要用 --model 手填被评的模型")
        run = None
    else:
        try:
            run = find_run(ticket, run_prefix, occ_base, **live)
        except LookupError:
            if not model_override:
                raise
            run = None
        if run is None and not model_override:
            raise LookupError(f"{ticket} 派工记录和 multica issue runs 都没找到 run；"
                              f"确实是本机线或别的做法，就加 --model 手填模型")
    title = ""
    if ticket:
        title = (resolve_titles(base, [ticket], title_fn=title_fn).get(ticket) or "")
    row = build_review(
        now=now or datetime.now(timezone.utc), ticket=ticket, grade=grade, note=note,
        by=by or default_reviewer(), run=run, model_override=model_override,
        task=task or title, task_src="手写" if task else ("票面标题" if title else ""),
        reviewer_model=(default_reviewer_model(env) if reviewer_model is None else reviewer_model.strip()))
    occ.append_jsonl(reviews_file(base), row)
    return row


def void_review(
    base: Path, occ_base: Path, *, ticket: str, run_prefix: str, note: str, by: str = "",
    now: Optional[datetime] = None, **live: Any,
) -> dict[str, Any]:
    """作废：追加一行 void 记录，汇总按同票同 run 取最新时遇到它整条不算；原评价行留在文件里不删。
    之后对同一条 run 再 add 一条，又按最新算（作废可以被新评价盖掉）。"""
    if not run_prefix.strip():
        raise ValueError("作废要写 --run <run 号前缀>：作废的是哪一条 run 上的评价")
    if not note.strip():
        raise ValueError("作废要写一句原因")
    ticket = normalize_ticket(ticket)
    run_prefix = run_prefix.strip()
    mine = [r for r in read_reviews(base) if str(r.get("ticket") or "").upper() == ticket
            and str(r.get("run_id") or "").startswith(run_prefix)]
    ids = sorted({str(r.get("run_id")) for r in mine})
    if len(ids) > 1:
        raise ValueError(f"--run {run_prefix} 在 {ticket} 上对到 {len(ids)} 条 run：{'、'.join(i[:12] for i in ids)}，前缀写长一点")
    if ids:
        run_id = ids[0]
    else:
        found = find_run(ticket, run_prefix, occ_base, **live)
        if not found or not found.get("run_id"):
            raise LookupError(f"{ticket} 上找不到 run 前缀 {run_prefix}")
        run_id = str(found["run_id"])
    current = [r for r in latest_per_run(mine) if str(r.get("run_id")) == run_id]
    target = current[0] if current else {}
    row = {
        "schema": SCHEMA, "kind": "void", "ts_bj": occ.fmt_bj(now or datetime.now(timezone.utc)),
        "ticket": ticket, "run_id": run_id, "note": note.strip(), "by": by or default_reviewer(),
        "voided_grade": None if is_void(target) else target.get("grade"),
        "voided_model": None if is_void(target) else target.get("model"),
    }
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
    return (row.get("ts_bj"), row.get("kind"), row.get("ticket"), row.get("run_id"), row.get("by"), row.get("note"))


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


def is_void(row: Mapping[str, Any]) -> bool:
    return row.get("kind") == "void"


def latest_per_run(rows: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """同一张票同一条 run 只留最新一条记录（后评覆盖前评，旧行留在文件里不删）。
    补评、翻案都靠再 add 一条；汇总只认最新，不让同一次活算两回。作废记录也在这里参与排序。"""
    latest: dict[tuple[str, str], Mapping[str, Any]] = {}
    for row in sorted(rows, key=lambda r: str(r.get("ts_bj") or "")):
        latest[(str(row.get("ticket") or "").upper(), str(row.get("run_id") or ""))] = row
    return list(latest.values())


def live_reviews(rows: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """算数的评价：每条 run 取最新，最新是作废的整条不算。"""
    return [r for r in latest_per_run(rows) if not is_void(r)]


def summarize(rows: Sequence[Mapping[str, Any]], *, now: datetime, days: int = 7) -> list[dict[str, Any]]:
    start = occ.fmt_bj(now - timedelta(days=days))
    by_model: dict[str, list[Mapping[str, Any]]] = {}
    for row in live_reviews(rows):
        if effective_ts(row) >= start:
            by_model.setdefault(norm_model(row.get("model")) or "未知", []).append(row)
    result = []
    for model, items in by_model.items():
        items = sorted(items, key=effective_ts, reverse=True)
        counts = {g: sum(1 for r in items if r.get("grade") == g) for g in GRADES}
        result.append({
            "model": model, "label": model_label(model), "unverified": sum(1 for r in items if r.get("model_verified") is False),
            "good": counts["好"], "ok": counts["一般"], "bad": counts["差"], "total": len(items),
            "recent": [{"ticket": r.get("ticket"), "grade": r.get("grade"), "note": clip(str(r.get("note") or ""))}
                       for r in items[:RECENT_NOTES]],
        })
    return sorted(result, key=lambda r: (-r["total"], r["model"]))


# ---------------------------------------------------------------- 一次性重核：评价里的模型按 run 实际用的重算

# 默认只核名字里带 Go 的执行者（付费 Go 钥匙那几个，配置会在小米和 Spark 之间改来改去）和 Spark 执行者。
REVERIFY_MATCH = r"\bGo\b|Spark"


def reverify_models(
    base: Path, occ_base: Path, *, match: str = REVERIFY_MATCH, apply: bool = False,
    now: Optional[datetime] = None, peers: bool = True,
    issue_runs_fn: Callable[[str], tuple[Optional[list], Optional[str]]] = fetch_issue_runs,
    reviews: Optional[Sequence[Mapping[str, Any]]] = None,
) -> dict[str, Any]:
    """算数的评价里执行者名字匹配 match 的，逐条拿 run 实际用的模型（multica 现查 usage）比；
    模型不对就追加一条更正（同票同 run 的新行覆盖旧行，旧行留着）。更正行的 ts_bj 是现在，
    评价发生时刻另存 orig_ts_bj，不改 7 天窗口和「最近三句」的顺序。apply=False 只出计划，不写。"""
    now = now or datetime.now(timezone.utc)
    read_from: list[str] = []
    missed: list[str] = []
    if reviews is None:
        reviews, _rows, read_from, missed = gather(base, occ_base, peers=peers)
    live = live_reviews(reviews)
    targets = [r for r in live if re.search(match, str(r.get("executor") or "")) and r.get("run_id")]
    tickets = sorted({str(r.get("ticket") or "").upper() for r in targets} - {""})
    runs_by_id: dict[str, Mapping[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        for runs, _err in pool.map(issue_runs_fn, tickets):
            for run in runs or []:
                runs_by_id[str(run.get("id"))] = run
    corrections: list[dict[str, Any]] = []
    unchanged = no_usage = no_run = 0
    for row in targets:
        run = runs_by_id.get(str(row.get("run_id")))
        if run is None:
            no_run += 1
            continue
        actual = actual_model(run)
        if actual is None:
            no_usage += 1
            continue
        if norm_model(actual) == norm_model(row.get("model")):
            unchanged += 1
            continue
        fixed = dict(row)
        fixed.update({
            "kind": "review", "ts_bj": occ.fmt_bj(now), "orig_ts_bj": effective_ts(row),
            "model": actual, "model_verified": True,
            "correction": f"模型更正：{norm_model(row.get('model'))} → {actual}（按 run 实际用的模型重核）",
            "corrected_by": default_reviewer(),
        })
        corrections.append(fixed)
    if apply:
        for fixed in corrections:
            occ.append_jsonl(reviews_file(base), fixed)
    before = summarize(reviews, now=now, days=3650)
    after = summarize(list(reviews) + corrections, now=now, days=3650)
    return {"checked": len(targets), "corrected": len(corrections), "unchanged": unchanged,
            "no_usage": no_usage, "no_run": no_run, "applied": apply, "corrections": corrections,
            "before": before, "after": after, "read_from": read_from, "missed": missed}


def format_reverify(result: Mapping[str, Any]) -> str:
    head = "已追加更正" if result["applied"] else "只是计划，没写（加 --apply 才写）"
    lines = [f"模型重核（{head}）：核了 {result['checked']} 条，改 {result['corrected']} 条，"
             f"本来就对 {result['unchanged']} 条，run 没用量记录 {result['no_usage']} 条，找不到 run {result['no_run']} 条"]
    moves: dict[tuple[str, str], int] = {}
    for fixed in result["corrections"]:
        old = str(fixed["correction"]).split("：", 1)[1].split(" → ")[0]
        key = (old, str(fixed["model"]))
        moves[key] = moves.get(key, 0) + 1
    for (old, new), n in sorted(moves.items(), key=lambda kv: -kv[1]):
        lines.append(f"  {n} 条 {old} → {new}")
    names = sorted({e["model"] for e in result["before"]} | {e["model"] for e in result["after"]})
    lines.append("改前 → 改后（好 / 一般 / 差）：")
    for name in names:
        b = next((e for e in result["before"] if e["model"] == name), None)
        a = next((e for e in result["after"] if e["model"] == name), None)
        if (b and (b["good"], b["ok"], b["bad"])) == (a and (a["good"], a["ok"], a["bad"])):
            continue
        fmt = lambda e: f"{e['good']} / {e['ok']} / {e['bad']}" if e else "无"
        lines.append(f"  {model_label(name)} [{name}]：{fmt(b)} → {fmt(a)}")
    return "\n".join(lines + format_sources(result.get("read_from") or [], result.get("missed") or []))


# ---------------------------------------------------------------- list：一行一条，谁在什么任务上为什么打了这个档

MODEL_ALIASES = {"小米": "mimo", "mimo": "mimo", "spark": "muse-spark", "glm": "glm", "zcode": "glm",
                 "kimi": "kimi", "gpt": "gpt", "sol": "gpt-6.1-sol", "astra": "gpt-6-astra"}


def model_matches(model: Any, query: str) -> bool:
    """--model 认俗名：小米=mimo，spark 含免费和付费，glm=ZCode；写免费spark / 付费spark 只取那一种；其余按子串。"""
    q = (query or "").strip().lower().replace(" ", "")
    if not q:
        return True
    name = norm_model(model).lower()
    if q in ("免费spark", "spark免费"):
        return "muse-spark" in name and "free" in name
    if q in ("付费spark", "spark付费"):
        return "muse-spark" in name and "free" not in name
    needle = MODEL_ALIASES.get(q, q)
    return needle in name or needle in model_label(model).lower()


def list_reviews(rows: Sequence[Mapping[str, Any]], *, now: datetime, days: int = 7, model: str = "",
                 grade: str = "") -> list[dict[str, Any]]:
    start = occ.fmt_bj(now - timedelta(days=days))
    kept = [r for r in live_reviews(rows) if effective_ts(r) >= start and model_matches(r.get("model"), model)
            and (not grade or r.get("grade") == grade)]
    return [dict(r) for r in sorted(kept, key=effective_ts, reverse=True)]


def format_list_line(row: Mapping[str, Any], title: str = "") -> str:
    task = clip(str(row.get("task") or title or ""), 40)
    ticket = row.get("ticket") or "无票"
    return (f"{effective_ts(row)} | {ticket} | {task} | {row.get('grade')} | 为什么：{row.get('note')} | "
            f"评价人 {row.get('by') or ''} | 评价者模型 {row.get('reviewer_model') or ''} | "
            f"模型 {norm_model(row.get('model'))} | 执行者 {row.get('executor') or '-'} | 机器 {row.get('machine') or '-'}")


def format_list(rows: Sequence[Mapping[str, Any]], titles: Mapping[str, str],
                read_from: Sequence[str] = (), missed: Sequence[str] = ()) -> str:
    if not rows:
        return "\n".join(["没有符合条件的评价"] + format_sources(read_from, missed))
    lines = [format_list_line(r, titles.get(str(r.get("ticket") or ""), "")) for r in rows]
    return "\n".join(lines + format_sources(read_from, missed))


def backfill_titles(base: Path, rows: Sequence[Mapping[str, Any]], *,
                    title_fn: Optional[Callable[[str], Optional[str]]] = None) -> dict[str, int]:
    """已有评价补任务标题：只写旁表 task-titles.json，评价原行不改。"""
    tickets = sorted({str(r.get("ticket") or "") for r in live_reviews(rows) if r.get("ticket") and not r.get("task")})
    before = load_titles(base)
    found = resolve_titles(base, tickets, title_fn=title_fn)
    return {"tickets": len(tickets), "had": sum(1 for t in tickets if t in before),
            "filled": sum(1 for t in tickets if t in found and t not in before),
            "missing": sum(1 for t in tickets if t not in found)}


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
        name = e.get("label") or e["model"]
        if name != e["model"]:
            name = f"{name} [{e['model']}]"
        lines.append(f"{name}  好 {e['good']} / 一般 {e['ok']} / 差 {e['bad']}  最近：{recent}")
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
            "ticket": ticket, "model": actual_model(run) or norm_model(row.get("model")) or "未知", "executor": row.get("executor"),
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
    reviewed = {str(r.get("ticket") or "").upper() for r in live_reviews(reviews)}
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
    p_add.add_argument("--task", default="", help="当时干了啥；没有票号的活必填（票号写 -），有票号时缺省取票面标题")
    p_add.add_argument("--reviewer-model", default=None, dest="reviewer_model",
                       help="评价者自己是哪个模型（如 'Claude Opus 5.5'）；缺省读环境，读不到留空")
    p_add.add_argument("--run", default="", help="run 号前缀；缺省取这张票最近一条")
    p_add.add_argument("--by", default="", help="评价人窗口名；缺省读环境里的会话名")
    p_add.add_argument("--model", default="", help="找不到 run 时手填模型")
    p_list = sub.add_parser("list", help="一行一条：时刻、票号、任务标题、评价档、为什么、评价人、评价者模型、模型、机器")
    p_list.add_argument("--model", default="", help="认俗名：小米=mimo、spark（含免费付费）、glm=ZCode，或模型名片段")
    p_list.add_argument("--grade", default="", choices=("",) + GRADES)
    p_list.add_argument("--days", type=int, default=7)
    p_list.add_argument("--local", action="store_true", help="只看本机")
    p_list.add_argument("--json", action="store_true")
    p_back = sub.add_parser("backfill-tasks", help="已有评价补任务标题（写旁表，原行不改）")
    p_back.add_argument("--local", action="store_true", help="只看本机")
    p_void = sub.add_parser("void", help="作废一条 run 上的评价（旧行不删，汇总整条不算）")
    p_void.add_argument("ticket")
    p_void.add_argument("note", help="作废原因")
    p_void.add_argument("--run", required=True, help="要作废的 run 号前缀")
    p_void.add_argument("--by", default="", help="谁作废的；缺省读环境里的会话名")
    p_rev = sub.add_parser("reverify-models", help="一次性重核：评价里的模型按 run 实际用的重算，不对的追加更正")
    p_rev.add_argument("--apply", action="store_true", help="真写更正行；不带只出计划")
    p_rev.add_argument("--match", default=REVERIFY_MATCH, help="只核执行者名字匹配这个正则的评价")
    p_rev.add_argument("--local", action="store_true", help="只看本机评价记录")
    p_rev.add_argument("--json", action="store_true")
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
                             by=args.by, run_prefix=args.run, model_override=args.model, task=args.task,
                             reviewer_model=args.reviewer_model, now=now)
            run_short = str(row.get("run_id") or "-")[:8]
            unchecked = "（模型未核）" if row.get("model_verified") is False else ""
            print(f"已记 {row['ticket']} {row['grade']}  模型 {row['model']}{unchecked}  {row['executor']}@{row['machine']}"
                  f"  号 {row['account']}  run {run_short}（{row['source']}）  评价人 {row['by']}"
                  f"  评价者模型 {row.get('reviewer_model') or '（空）'}  任务：{clip(str(row.get('task') or '（没取到标题）'), 40)}")
            return 0
        if args.cmd == "list":
            reviews, _rows, read_from, missed = gather(base, occ_base, peers=not args.local)
            picked = list_reviews(reviews, now=now, days=args.days, model=args.model, grade=args.grade)
            titles = resolve_titles(base, [str(r.get("ticket") or "") for r in picked if not r.get("task")])
            if args.json:
                for r in picked:
                    r.setdefault("task", None)
                    r["task"] = r.get("task") or titles.get(str(r.get("ticket") or ""))
                print(json.dumps({"reviews": picked, "read_from": read_from, "missed": missed}, ensure_ascii=False))
            else:
                print(format_list(picked, titles, read_from, missed))
            return 0
        if args.cmd == "backfill-tasks":
            reviews, _rows, read_from, missed = gather(base, occ_base, peers=not args.local)
            res = backfill_titles(base, reviews)
            print(f"任务标题回填：要补 {res['tickets']} 张票，本来缓存里就有 {res['had']}，这次补上 {res['filled']}，"
                  f"查不到 {res['missing']}（旁表 {base / TITLES_NAME}，评价原行没动）")
            return 0
        if args.cmd == "void":
            row = void_review(base, occ_base, ticket=args.ticket, run_prefix=args.run, note=args.note,
                              by=args.by, now=now)
            was = f"原评 {row['voided_grade']} / {row['voided_model']}" if row.get("voided_grade") else "本机没有这条评价，作废记在本机，合看时生效"
            print(f"已作废 {row['ticket']} run {str(row['run_id'])[:8]}（{was}）  原因：{row['note']}  经手 {row['by']}")
            return 0
        if args.cmd == "reverify-models":
            result = reverify_models(base, occ_base, match=args.match, apply=args.apply, now=now, peers=not args.local)
            print(json.dumps({k: v for k, v in result.items() if k not in ("before", "after")}, ensure_ascii=False)
                  if args.json else format_reverify(result))
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
