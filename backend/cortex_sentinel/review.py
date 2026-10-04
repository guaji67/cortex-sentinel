#!/usr/bin/env python3
"""模型口碑：每张活交回来，验收的窗口顺手记一句「好 / 一般 / 差 + 一句感受」，按模型攒起来。

Falcon 10-04 01:5x：不是跑分、不是派单去测、不是从回执里自动判；是日常用的时候，不同的派工、不同的模型，
做得好、做得坏，像用户好评差评一样一条条攒。所以这里只有人写的评价，程序只负责把「这张票是哪个模型、
哪个执行者、哪台机器、哪个号做的」自动带上，省得评价人去翻。

记录：~/Library/Application Support/CortexSentinel/reviews/reviews.jsonl（一行一条评价，只追加）。
读口复用占用记录那一套：派工记录 dispatch-YYYY-MM-DD.jsonl 里找这张票最近一条 run，找不到再用
`multica issue runs` 现查；pending 读当前 run 状态也走 occupancy 的 fetch_agent_runs。

本机线（派工器在本机起的 CLI 线，看板只占票、不起 multica run）没有 multica run，模型取它自己
会话日志里实际用的那一个：读 logs/codebuddy-<票号>.status.json 和 .log，两处都找（主检出的 logs/
优先，再看闸运行时树的 logs/）。run 号记成 local:<slug>，执行者写「本机线 <引擎>」。不写死模型名单。

用法：
    sentinel-review add COR-12366 好 "6.7 分钟一次做对，回执与实物对得上" [--run 前缀] [--by 窗口名] [--model 手填]
    sentinel-review nudge [--dry-run|--force]    完工没人评的票凑一批建补评单派出去（要先在 reviews/nudge.json 里 enabled）
    sentinel-review restore [--apply]            评价记录丢了或缺了，从另外两台里本机的备份补回（先不带 --apply 看计划）
    sentinel-review list [--model 小米|spark|glm] [--grade 差|一般|好] [--days 7]   一行一条，看谁为什么打的这个档
    sentinel-review add - 差 "为什么" --task "当时干了啥" --model 模型名            没有票号的活
    sentinel-review void COR-12153 --run 01a1009f --by 窗口名 "原因"     作废那条 run 上的评价，汇总整条不算
    sentinel-review reverify-models [--apply] [--match 正则]   一次性重核评价里的模型，按 run 实际用的重算
    sentinel-review summary [--days 7] [--local]
    sentinel-review pending [--since 今天] [--local]

add 不带 --run 时取这张票最近一条真跑完的 run（完工状态、有实际用时），没开跑就撤的、被取消的、失败的跳过；
要评那些，明写 --run。multica 没有真跑完的 run，就看这张票的本机线（终态 done、退出码 0、有实际用时才取），
明写 --run local:<slug> 可以直指某条本机线。

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
import subprocess
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
ALIASES_NAME = "model-aliases.json"
DEFAULT_ALIASES = Path(__file__).resolve().parent / "data" / ALIASES_NAME
GRADES = ("好", "一般", "差")
NOTE_SHOW_CHARS = 40
RECENT_NOTES = 3
IN_FLIGHT = ("queued", "dispatched", "running", "waiting_local_directory")

KEEP_NOTE = (
    "CORTEX-KEEP\n"
    "# 不要删除 · 一定保留 · DO NOT DELETE\n\n"
    "这是三台机器互相备份的模型口碑记录：每张活交回来，验收的窗口写一句好 / 一般 / 差加感受，按模型攒着，\n"
    "留给以后挑模型、派工时看（Falcon 10-04）。删了就丢模型口碑，清理程序和任何窗口都不要动，要清理先问他：\n\n"
    "- reviews.jsonl：本机写的评价，一行一条，北京时刻、票号、run 号、模型、执行者、机器、号、评价档、感受原句、评价人。\n"
    "- mirror/：另外两台机器 reviews.jsonl 的只读备份（每分钟由哨兵拉一份，只增不减），那两台丢了从这里还原。\n"
    "- task-titles.json、model-aliases.json：任务标题缓存和 list --model 的俗名表，可重建，但俗名表是他改过的话别覆盖。\n\n"
    "丢了怎么办：sentinel-review restore（先看计划）→ sentinel-review restore --apply，会从另外两台的备份里把缺的评价补回本机。\n"
    "记：sentinel-review add COR-12345 好|一般|差 \"一句感受\"\n"
    "看：sentinel-review summary [--days 7]；sentinel-review list；sentinel-review pending\n"
    "（时刻按北京时间。）\n"
)

MIRROR_KEEP_NOTE = (
    "CORTEX-KEEP\n"
    "# 不要删除 · 一定保留 · DO NOT DELETE\n\n"
    "这是另外两台机器上模型口碑记录（reviews.jsonl）的备份，文件名是机器名（pro / mini / m1max），每分钟拉一次，只增不减。\n"
    "那台机器的记录丢了，就靠这里和它另一个备份还原。删了就少一份保险，请不要动，要清理先问他。\n"
)


# ---------------------------------------------------------------- 路径与读写

def reviews_dir() -> Path:
    raw = os.environ.get("CORTEX_SENTINEL_REVIEWS_DIR", "").strip()
    base = Path(raw).expanduser() if raw else (
        Path.home() / "Library" / "Application Support" / "CortexSentinel" / "reviews"
    )
    base.mkdir(parents=True, exist_ok=True)
    keep = base / "不要删除.md"
    if not keep.exists() or "三台机器互相备份" not in keep.read_text(encoding="utf-8", errors="replace"):
        keep.write_text(KEEP_NOTE, encoding="utf-8")
    mine = base / ALIASES_NAME
    if not mine.exists() and DEFAULT_ALIASES.exists():
        try:
            mine.write_text(DEFAULT_ALIASES.read_text(encoding="utf-8"), encoding="utf-8")
        except OSError:
            pass
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


def effective_ts(row: Mapping[str, Any]) -> str:
    """评价算在哪个时刻：更正行写在更正当时（要盖过旧行），但评价本身发生在 orig_ts_bj。"""
    return str(row.get("orig_ts_bj") or row.get("ts_bj") or "")


# ---------------------------------------------------------------- 本机线：看板只占票、不起 multica run 的那种线

LOCAL_LINE_PREFIX = "codebuddy"                 # 状态和日志文件名的前缀：codebuddy-<slug>.status.json / .log
LOCAL_RUN_PREFIX = "local:"                     # 本机线在评价记录里的 run 号前缀
LOCAL_SLUG_RE = re.compile(r"^cor-\d+$", re.IGNORECASE)
LOCAL_STATUS_RE = re.compile(rf"^{LOCAL_LINE_PREFIX}-(cor-\d+)\.status\.json$", re.IGNORECASE)


def local_slug(ticket: str) -> str:
    """票号 → 本机线的 slug（COR-12474 → cor-12474）。不是票号形状的（如 q-B51-...）返回空串，
    那种线不管、不报错。"""
    slug = str(ticket or "").strip().lower()
    return slug if LOCAL_SLUG_RE.match(slug) else ""


def default_local_logs_dirs() -> list[Path]:
    """本机线的状态和日志两处都找：Cortex 主检出的 logs/ 优先，再看闸运行时树的 logs/。"""
    dirs: list[Path] = []
    for raw in (Path(occ.checkout_base()) / "logs", occ.gate_runtime() / "logs"):
        if raw not in dirs:
            dirs.append(raw)
    return dirs


def _stream_log_models(path: Path) -> tuple[Optional[str], Optional[str]]:
    """流式逐行读 stream-json 日志（大的几十 MB，不许整读），只解析含 "model" 的行。
    返回 (assistant 消息里出现最多的模型, init 事件的模型)，都读不到给 None。"""
    assistants: dict[str, int] = {}
    init_model = ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if '"model"' not in line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                if row.get("type") == "assistant":
                    name = norm_model((row.get("message") or {}).get("model"))
                    if name and name != "<synthetic>":
                        assistants[name] = assistants.get(name, 0) + 1
                elif row.get("subtype") == "init" and not init_model:
                    name = norm_model(row.get("model"))
                    if name and name != "<synthetic>":
                        init_model = name
    except OSError:
        return None, None
    best = max(assistants, key=lambda name: assistants[name]) if assistants else ""
    return (best or None), (init_model or None)


def local_line_info(slug: str, logs_dirs: Optional[Sequence[Path]] = None, *,
                    read_log: bool = True) -> Optional[dict[str, Any]]:
    """一条本机线的底细。状态文件给引擎、配置模型、会话号、起止时刻、状态、退出码；
    日志流式读出真正用的模型，取值顺序：assistant 消息里用量最多的 → init 事件的 →
    都没有才退状态文件里的配置模型并标「模型未核」。
    slug 不是票号形状、两处都找不到状态文件、状态文件读不懂的返回 None，不报错。"""
    slug = str(slug or "").strip().lower()
    if not LOCAL_SLUG_RE.match(slug):
        return None
    dirs = list(logs_dirs) if logs_dirs is not None else default_local_logs_dirs()
    status_path = next((d / f"{LOCAL_LINE_PREFIX}-{slug}.status.json" for d in dirs
                        if (d / f"{LOCAL_LINE_PREFIX}-{slug}.status.json").is_file()), None)
    if status_path is None:
        return None
    try:
        payload = json.loads(status_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    actual: Optional[str] = None
    init: Optional[str] = None
    log_path = status_path.with_name(f"{LOCAL_LINE_PREFIX}-{slug}.log")
    if read_log and log_path.is_file():
        actual, init = _stream_log_models(log_path)
    model = actual or init
    verified = bool(model)
    if not model:
        model = norm_model(payload.get("model"))
    started = occ.parse_utc(payload.get("started_at"))
    finished = occ.parse_utc(payload.get("updated_at"))
    seconds = int((finished - started).total_seconds()) if started and finished and finished > started else None
    return {
        "slug": slug,
        "engine": str(payload.get("engine") or "").strip(),
        "model": model,
        "model_verified": verified,
        "config_model": norm_model(payload.get("model")),
        "session_id": str(payload.get("session_id") or ""),
        "started_bj": occ.fmt_bj(started) if started else None,
        "finished_bj": occ.fmt_bj(finished) if finished else None,
        "run_seconds": seconds,
        "state": str(payload.get("state") or "").strip().lower(),
        "exit_code": payload.get("exit_code"),
    }


def list_local_lines(logs_dirs: Optional[Sequence[Path]] = None, *,
                     read_log: bool = True) -> dict[str, dict[str, Any]]:
    """两处 logs 目录里所有本机线的底细，按 slug 索引，主检出优先；只认 codebuddy-<票号>.status.json，
    别的前缀、别的 slug 形状的文件不碰。read_log=False 只读状态文件（先挑候选，别一上来就流读日志）。"""
    dirs = list(logs_dirs) if logs_dirs is not None else default_local_logs_dirs()
    found: dict[str, dict[str, Any]] = {}
    for directory in dirs:
        try:
            names = os.listdir(directory)
        except OSError:
            continue
        for name in names:
            matched = LOCAL_STATUS_RE.match(name)
            if not matched:
                continue
            slug = matched.group(1).lower()
            if slug in found:
                continue
            info = local_line_info(slug, [directory], read_log=read_log)
            if info:
                found[slug] = info
    return found


def local_run_row(slug: str, logs_dirs: Optional[Sequence[Path]] = None) -> Optional[dict[str, Any]]:
    """这条本机线可不可以拿来评、评的话记哪些字段：状态终态 done、退出码 0、有实际用时
    （updated_at 晚于 started_at）才取，否则 None。run_id 记 local:<slug>，执行者写「本机线 <引擎>」，
    机器写本机，来源写「本机线日志」。"""
    info = local_line_info(slug, logs_dirs)
    if not info or info["state"] != "done" or str(info["exit_code"]).strip() != "0" or info["run_seconds"] is None:
        return None
    return {
        "run_id": LOCAL_RUN_PREFIX + info["slug"],
        "model": info["model"],
        "model_verified": info["model_verified"],
        "executor": f"本机线 {info['engine']}".strip(),
        "executor_id": None,
        "machine": local_machine(),
        "account": "-",
        "run_created_bj": info["started_bj"],
        "run_seconds": info["run_seconds"],
        "run_started_bj": info["started_bj"],
        "run_finished_bj": info["finished_bj"],
        "source": "本机线日志",
    }


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


def snapshot_model(occ_base: Optional[Path], run_id: Any) -> Optional[str]:
    """派工记录里这条 run 第一次被看到时（建出来一分钟内）执行者的模型配置——比执行者现在的配置更接近当时。"""
    if occ_base is None or not run_id:
        return None
    for row in reversed(_dispatch_rows(occ_base)):
        if row.get("run_id") == run_id and row.get("model"):
            return norm_model(row.get("model"))
    return None


def run_provider(run: Mapping[str, Any]) -> Optional[str]:
    """run 用量里用量最大那个模型走的通道（provider 字段，记着方便区分同名模型走不同通道）。"""
    best: tuple[int, Optional[str]] = (0, None)
    for item in run.get("usage") or []:
        if isinstance(item, Mapping):
            tokens = int(item.get("input_tokens") or 0) + int(item.get("output_tokens") or 0)
            if tokens > best[0] and item.get("provider"):
                best = (tokens, str(item["provider"]))
    return best[1]


def describe_run(run: Mapping[str, Any], occ_base: Optional[Path],
                 agents_fn: Callable[[], tuple[Optional[list], Optional[str]]]) -> dict[str, Any]:
    """模型取值顺序：run 用量里的实际模型 → 派工记录里当时的执行者配置 → 执行者现配置（标模型未核）。
    执行者名、机器取 agent 清单（含归档）；号先按 run 号、再按同一执行者从派工记录里借。"""
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
    snap = None if actual else snapshot_model(occ_base, run.get("id"))
    if actual:
        model, verified, src = actual, True, "multica 现查"
    elif snap:
        model, verified, src = snap, True, "multica 现查（模型取派工记录里当时的执行者配置）"
    else:
        model, verified = agent.get("model"), False
        src = "multica 现查（模型未核：run 没有用量记录，也没有派工记录，退执行者现配置）"
    return {
        "run_id": run.get("id"), "model": model, "model_verified": verified, "provider": run_provider(run),
        "executor": name or None,
        "executor_id": run.get("agent_id"), "machine": machine_word(name), "account": account,
        "run_created_bj": occ.fmt_bj(created) if created else None, "run_seconds": run_seconds(run),
        "run_started_bj": fmt_opt_bj(run.get("started_at")), "run_finished_bj": fmt_opt_bj(run.get("completed_at")),
        "source": src,
    }


def find_run(
    ticket: str, run_prefix: str, occ_base: Path, *,
    runs_fn: Callable[[str], tuple[Optional[list], Optional[str]]] = fetch_issue_runs,
    agents_fn: Callable[[], tuple[Optional[list], Optional[str]]] = fetch_agents_all,
    local_logs_dirs: Optional[Sequence[Path]] = None,
) -> Optional[dict[str, Any]]:
    """找这张票要评的 run。不带 --run：multica 现查，取最近一条真跑完的（完工状态、有实际用时）；
    现查没有真跑完的，再看这张票有没有本机线；带 --run：按前缀认那一条，不管状态（--run local:<slug>
    直指本机线）。都找不到再退到派工记录。"""
    run_prefix = (run_prefix or "").strip()
    if run_prefix.startswith(LOCAL_RUN_PREFIX):
        slug = run_prefix[len(LOCAL_RUN_PREFIX):].strip() or local_slug(ticket)
        return local_run_row(slug, local_logs_dirs) or run_from_dispatch(occ_base, ticket, run_prefix)
    runs, _err = runs_fn(ticket)
    if runs:
        if run_prefix:
            matched = [r for r in runs if str(r.get("id") or "").startswith(run_prefix)]
            chosen = max(matched, key=lambda r: str(r.get("created_at") or "")) if matched else None
        else:
            chosen = pick_finished_run(runs)
            if chosen is None:
                local = local_run_row(local_slug(ticket), local_logs_dirs)
                if local is not None:
                    return local
                states = "、".join(f"{str(r.get('id'))[:8]} {r.get('status')}" for r in runs[:6])
                raise LookupError(f"{ticket} 没有真跑完的 run（完工状态且有实际用时），现有：{states}；"
                                  f"要评别的 run 就写 --run <run 号前缀>")
        if chosen is not None:
            return describe_run(chosen, occ_base, agents_fn)
    if not run_prefix:
        local = local_run_row(local_slug(ticket), local_logs_dirs)
        if local is not None:
            return local
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
        "provider": run.get("provider"),
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
            "model": model, "unverified": sum(1 for r in items if r.get("model_verified") is False),
            "good": counts["好"], "ok": counts["一般"], "bad": counts["差"], "total": len(items),
            "recent": [{"ticket": r.get("ticket"), "grade": r.get("grade"), "note": clip(str(r.get("note") or ""))}
                       for r in items[:RECENT_NOTES]],
        })
    return sorted(result, key=lambda r: (-r["total"], r["model"]))


# ---------------------------------------------------------------- 三台互备：评价记录别丢

MIRROR_DIR = "mirror"
REVIEWS_REL = "Library/Application Support/CortexSentinel/reviews"


def alias_word(alias: str) -> str:
    for word, name in PEER_ALIASES.items():
        if name == alias:
            return word
    return alias.replace("cortex-", "")


def mirror_dir(base: Path) -> Path:
    path = base / MIRROR_DIR
    path.mkdir(parents=True, exist_ok=True)
    note = path / "不要删除.md"
    if not note.exists():
        note.write_text(MIRROR_KEEP_NOTE, encoding="utf-8")
    return path


def _count_lines(path: Path) -> int:
    try:
        return sum(1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip())
    except OSError:
        return 0


def sync_mirror(base: Path, *, aliases: Optional[Sequence[str]] = None,
                runner: Callable[..., tuple[Optional[str], Optional[str]]] = occ._run) -> dict[str, Any]:
    """把另外两台的 reviews.jsonl 只读拉一份到 reviews/mirror/<机器>.jsonl（每分钟 tick 调一次）。
    只增不减：对方文件变空或变短（被删、被截）就不覆盖备份，记一笔；大小没变就不重拉。不往对方写任何东西。"""
    status: dict[str, Any] = {"synced": [], "unchanged": [], "kept": [], "missed": []}
    mdir = mirror_dir(base)
    for alias in (list(aliases) if aliases is not None else peer_aliases()):
        word = alias_word(alias)
        target = mdir / f"{word}.jsonl"
        remote = f'"$HOME/{REVIEWS_REL}/reviews.jsonl"'
        out, err = runner(SSH_BASE + [alias, f'wc -c < {remote} 2>/dev/null || echo 0'], timeout=PEER_TIMEOUT)
        if out is None:
            status["missed"].append(f"{alias}（{str(err)[-60:]}）")
            continue
        try:
            size = int(out.strip().split()[-1])
        except (ValueError, IndexError):
            status["missed"].append(f"{alias}（读不懂大小）")
            continue
        have = target.stat().st_size if target.exists() else 0
        if size == have and size > 0:
            status["unchanged"].append(word)
            continue
        if size == 0 or size < have:
            if have:
                status["kept"].append(f"{word}（对方现在 {size} 字节、备份 {have} 字节，没覆盖）")
            continue
        text, err = runner(SSH_BASE + [alias, f'cat {remote}'], timeout=PEER_TIMEOUT * 3)
        if text is None or not text.strip():
            status["missed"].append(f"{alias}（拉文件失败）")
            continue
        if len(text.encode("utf-8")) < have:   # 拉的过程中对方被截：不换
            status["kept"].append(f"{word}（拉到的比备份短，没覆盖）")
            continue
        tmp = mdir / f"{word}.jsonl.tmp"
        tmp.write_text(text, encoding="utf-8")
        tmp.replace(target)
        status["synced"].append(f"{word}（{_count_lines(target)} 条）")
    return status


def restore_from_peers(base: Path, *, apply: bool = False, aliases: Optional[Sequence[str]] = None, me: str = "",
                       runner: Callable[..., tuple[Optional[str], Optional[str]]] = occ._run) -> dict[str, Any]:
    """本机的评价记录丢了或缺了：读另外两台里「本机的备份」（它们的 reviews/mirror/<本机>.jsonl），
    把本机没有的评价补回本机 reviews.jsonl（只追加，不改不删本机已有的行）。不 --apply 只出计划。"""
    me = me or local_machine()
    local_rows = read_reviews(base)
    have = {json.dumps(r, ensure_ascii=False, sort_keys=True) for r in local_rows}
    result: dict[str, Any] = {"local": len(local_rows), "sources": {}, "missed": [], "missing": 0, "applied": apply}
    missing: dict[str, dict[str, Any]] = {}
    for alias in (list(aliases) if aliases is not None else peer_aliases()):
        remote = f'"$HOME/{REVIEWS_REL}/{MIRROR_DIR}/{me}.jsonl"'
        out, err = runner(SSH_BASE + [alias, f'cat {remote} 2>/dev/null; true'], timeout=PEER_TIMEOUT * 3)
        if out is None:
            result["missed"].append(f"{alias}（{str(err)[-60:]}）")
            continue
        rows = parse_jsonl_text(out)
        result["sources"][alias] = len(rows)
        for row in rows:
            key = json.dumps(row, ensure_ascii=False, sort_keys=True)
            if key not in have and key not in missing:
                missing[key] = row
    ordered = sorted(missing.values(), key=lambda r: str(r.get("ts_bj") or ""))
    result["missing"] = len(ordered)
    if apply and ordered:
        for row in ordered:
            occ.append_jsonl(reviews_file(base), row)
    return result


def format_restore(res: Mapping[str, Any]) -> str:
    head = "已补回" if res["applied"] else "只是计划，没写（加 --apply 才补）"
    srcs = "、".join(f"{a} 里有 {n} 条" for a, n in res["sources"].items()) or "没读到任何备份"
    lines = [f"评价记录还原（{head}）：本机现有 {res['local']} 条；另外两台里本机的备份：{srcs}；本机缺 {res['missing']} 条"]
    lines += [f"没读到：{m}" for m in res.get("missed") or []]
    return "\n".join(lines)


# ---------------------------------------------------------------- 补评单：完工没人评的票，哨兵定时建一张单派出去

NUDGE_CONFIG = "nudge.json"
NUDGE_STATE = "nudge-state.json"
NUDGE_DEFAULTS: dict[str, Any] = {
    "enabled": False,          # 总开关：只有这台机器的 reviews/nudge.json 里写 enabled=true 才建单（三台里只开一台，不然各建各的）
    "older_than_hours": 2,     # 完工超过这么久还没人评才算
    "interval_hours": 3,       # 每隔多久建一张
    "since_hours": 48,         # 只看最近这么久完工的
    "max_tickets": 20,         # 一张单最多列几张票，多的下一批
    "dispatch_args": [],       # 追加给派工器的参数（比如钉机器时写 --machine m1max --machine-reason ...）
}
NUDGE_RETRY_AFTER = timedelta(minutes=30)
NUDGE_TITLE_PREFIX = "补评单"

NUDGE_RULES = (
    "收紧口径（他定的，评每一张都照这个）：\n"
    "- 违反工单禁令（越界改了不该碰的东西、没按工单写明的做法做）的，最多评「一般」，不给「好」。\n"
    "- 交接有错（路径、说明、回执写错），或第一发自己漏做、靠别人催或接力才做成的，不给「好」。\n"
    "- 被环境或别人误杀的（运行被撤、被改派、接口或额度报错打断、工作树被别人动了）不算模型的锅：不要评，在回执里写一行是哪几张和原因。\n"
    "- 评的是那条 run 的模型这一趟干得好不好，不是这张票最后好不好；一句话写清为什么，写具体的事，不写套话。"
)


def nudge_config(base: Path) -> dict[str, Any]:
    cfg = dict(NUDGE_DEFAULTS)
    path = base / NUDGE_CONFIG
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return cfg
    if isinstance(raw, dict):
        cfg.update({k: v for k, v in raw.items() if k in NUDGE_DEFAULTS})
    return cfg


def load_nudge_state(base: Path) -> dict[str, Any]:
    try:
        raw = json.loads((base / NUDGE_STATE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raw = {}
    raw = raw if isinstance(raw, dict) else {}
    raw.setdefault("batched", {})
    raw.setdefault("batches", [])
    return raw


def save_nudge_state(base: Path, state: Mapping[str, Any]) -> None:
    tmp = base / (NUDGE_STATE + ".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(base / NUDGE_STATE)


def nudge_due(base: Path, now: datetime) -> bool:
    """tick 每分钟问一次：开着、而且离上次尝试够久，才起一个后台进程去干。"""
    cfg = nudge_config(base)
    if not cfg.get("enabled"):
        return False
    last = occ.parse_utc(load_nudge_state(base).get("last_attempt"))
    return last is None or now - last >= timedelta(hours=float(cfg["interval_hours"]))


def build_nudge_workorder(batch_id: str, items: Sequence[Mapping[str, Any]], titles: Mapping[str, str]) -> str:
    rows = "\n".join(
        f"- {p['ticket']}  {clip(titles.get(p['ticket'], ''), 40)}  |  模型 {p.get('model')}  |  {p.get('executor') or '-'}  |  完工 {p.get('completed_bj')}"
        for p in items)
    return (
        f"# {NUDGE_TITLE_PREFIX} {batch_id}：{len(items)} 张已完工、还没人评的票\n\n"
        "哨兵自动建的单。目的：把每张票交付的口碑补上，攒成各模型的好坏账。\n\n"
        "## 怎么做\n"
        "逐张看票面（`multica issue get <票号>`、`multica issue runs <票号>`）和回执、PR 或实物，然后在本机跑：\n\n"
        "    sentinel-review add COR-12345 好|一般|差 \"一句为什么\"\n\n"
        "只写档位和一句为什么。任务标题、执行者、那条 run 实际用的模型、机器、号、起止时刻、评价人窗口名、评价者模型，程序自己填，不用写。\n"
        "一张票有多条 run 时，不带 --run 默认取最近一条真跑完的；要评别的 run 才加 `--run <run 号前缀>`。\n"
        "只读：不要改票的状态，不要改别人的代码，不要合 PR，不要开新单。\n\n"
        f"## {NUDGE_RULES}\n\n"
        f"## 票（{len(items)} 张）\n{rows}\n\n"
        "## 收工\n"
        "全部评完（或写明跳过原因）就在本票回一条回执：评了几张、好 / 一般 / 差各几张、跳过了哪几张和原因。\n")


def dispatch_nudge(argv: Sequence[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(list(argv), env=occ._env(), capture_output=True, text=True, timeout=300)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return 1, f"派工器没跑成：{exc}"
    return proc.returncode, ((proc.stdout or "") + (proc.stderr or ""))[-1500:]


def nudge_command(cfg: Mapping[str, Any], batch_id: str, workorder: Path, count: int, *, dry_run: bool) -> list[str]:
    runtime = occ.gate_runtime()
    venv_python = runtime / ".venv" / "bin" / "python3"
    python = str(venv_python) if venv_python.exists() else occ.gate_python()
    argv = [python, str(runtime / "scripts" / "multica_dispatch.py"),
            "--title", f"{NUDGE_TITLE_PREFIX} {batch_id}：{count} 张已完工票的口碑",
            "--lane", "backend", "--score", "20", "--status", "todo",
            "--description-file", str(workorder),
            "--claim", f"哨兵自动补评单 {batch_id} / 只读票面与回执，逐张 sentinel-review add / 授权：他 10-04 定补评不靠窗口"]
    argv += [str(x) for x in cfg.get("dispatch_args") or []]
    if dry_run:
        argv.append("--dry-run")
    return argv


def run_nudge(
    base: Path, occ_base: Path, *, now: Optional[datetime] = None, force: bool = False, dry_run: bool = False,
    pending_fn: Optional[Callable[..., Any]] = None,
    dispatch_fn: Callable[[Sequence[str]], tuple[int, str]] = dispatch_nudge,
    title_fn: Optional[Callable[[str], Optional[str]]] = None,
) -> dict[str, Any]:
    """完工超过 older_than_hours 还没人评的票，凑一批（同一张票只进一批），建一张补评单照派工器派出去。
    派工器失败不标记已批，30 分钟后重试；--dry-run 只打计划并让派工器 dry-run，不标记。"""
    now = now or datetime.now(timezone.utc)
    cfg = nudge_config(base)
    if not cfg.get("enabled") and not force:
        return {"skipped": f"没开：这台机器的 reviews/{NUDGE_CONFIG} 里没有 enabled=true"}
    state = load_nudge_state(base)
    last = occ.parse_utc(state.get("last_attempt"))
    interval = timedelta(hours=float(cfg["interval_hours"]))
    if not force and not dry_run and last is not None and now - last < interval:
        return {"skipped": f"离上次尝试（{occ.fmt_bj(last)}）不到 {cfg['interval_hours']} 小时"}
    if not dry_run:
        state["last_attempt"] = now.strftime("%Y-%m-%dT%H:%M:%SZ")
        save_nudge_state(base, state)
    since = now - timedelta(hours=float(cfg["since_hours"]))
    fetch = pending_fn or collect_pending
    items, _in_flight, _read_from, missed = fetch(base, occ_base, since, now)
    cutoff = occ.fmt_bj(now - timedelta(hours=float(cfg["older_than_hours"])))
    fresh = [p for p in items if str(p["completed_bj"]) <= cutoff and p["ticket"] not in state["batched"]]
    titles = resolve_titles(base, [p["ticket"] for p in fresh], title_fn=title_fn)
    candidates = [p for p in fresh if not titles.get(p["ticket"], "").startswith(NUDGE_TITLE_PREFIX)]
    result: dict[str, Any] = {"candidates": len(candidates), "missed": missed, "dry_run": dry_run}
    if not candidates:
        result["batched"] = 0
        return result
    chosen = candidates[: int(cfg["max_tickets"])]
    batch_id = "B" + occ.to_beijing(now).strftime("%m%d-%H%M")
    nudge_dir = base / "nudge"
    nudge_dir.mkdir(parents=True, exist_ok=True)
    workorder = nudge_dir / f"{batch_id}.md"
    workorder.write_text(build_nudge_workorder(batch_id, chosen, titles), encoding="utf-8")
    code, tail = dispatch_fn(nudge_command(cfg, batch_id, workorder, len(chosen), dry_run=dry_run))
    result.update({"batch": batch_id, "tickets": [p["ticket"] for p in chosen], "workorder": str(workorder),
                   "dispatch_exit": code, "dispatch_tail": tail[-400:]})
    if dry_run:
        return result
    if code != 0:
        state["last_attempt"] = (now - interval + NUDGE_RETRY_AFTER).strftime("%Y-%m-%dT%H:%M:%SZ")
        state["last_error"] = {"at": occ.fmt_bj(now), "batch": batch_id, "exit": code, "tail": tail[-400:]}
        save_nudge_state(base, state)
        result["error"] = "派工器没派出去，30 分钟后重试"
        return result
    for p in chosen:
        state["batched"][p["ticket"]] = batch_id
    state["batches"].append({"id": batch_id, "at": occ.fmt_bj(now), "tickets": [p["ticket"] for p in chosen],
                             "dispatch_tail": tail[-300:]})
    state.pop("last_error", None)
    save_nudge_state(base, state)
    result["batched"] = len(chosen)
    return result


# ---------------------------------------------------------------- 一次性重核：评价里的模型按 run 实际用的重算

# 默认核全部评价：每条拿 run 实际用的模型比，不符才更正。--match 可以收窄到执行者名匹配某个正则的那几条。
REVERIFY_MATCH = ""


def reverify_models(
    base: Path, occ_base: Path, *, match: str = REVERIFY_MATCH, apply: bool = False,
    now: Optional[datetime] = None, peers: bool = True,
    issue_runs_fn: Callable[[str], tuple[Optional[list], Optional[str]]] = fetch_issue_runs,
    reviews: Optional[Sequence[Mapping[str, Any]]] = None,
    local_logs_dirs: Optional[Sequence[Path]] = None,
) -> dict[str, Any]:
    """算数的评价里执行者名字匹配 match 的，逐条拿 run 实际用的模型（multica 现查 usage）比；
    run 号以 local: 开头的按本机线日志重算（只有日志里读到实际模型才算数，退配置的不改）。
    模型不对就追加一条更正（同票同 run 的新行覆盖旧行，旧行留着）。更正行的 ts_bj 是现在，
    评价发生时刻另存 orig_ts_bj，不改 7 天窗口和「最近三句」的顺序。apply=False 只出计划，不写。"""
    now = now or datetime.now(timezone.utc)
    read_from: list[str] = []
    missed: list[str] = []
    if reviews is None:
        reviews, _rows, read_from, missed = gather(base, occ_base, peers=peers)
    live = live_reviews(reviews)
    targets = [r for r in live if re.search(match, str(r.get("executor") or "")) and r.get("run_id")]
    is_local = lambda row: str(row.get("run_id")).startswith(LOCAL_RUN_PREFIX)
    remote = [r for r in targets if not is_local(r)]
    tickets = sorted({str(r.get("ticket") or "").upper() for r in remote} - {""})
    runs_by_id: dict[str, Mapping[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=8) as pool:
        for runs, _err in pool.map(issue_runs_fn, tickets):
            for run in runs or []:
                runs_by_id[str(run.get("id"))] = run
    corrections: list[dict[str, Any]] = []
    unchanged = no_usage = no_run = 0

    def correct(row: Mapping[str, Any], actual: str, how: str) -> None:
        nonlocal unchanged
        if norm_model(actual) == norm_model(row.get("model")):
            unchanged += 1
            return
        fixed = dict(row)
        fixed.update({
            "kind": "review", "ts_bj": occ.fmt_bj(now), "orig_ts_bj": effective_ts(row),
            "model": actual, "model_verified": True,
            "correction": f"模型更正：{norm_model(row.get('model'))} → {actual}（{how}）",
            "corrected_by": default_reviewer(),
        })
        corrections.append(fixed)

    for row in remote:
        run = runs_by_id.get(str(row.get("run_id")))
        if run is None:
            no_run += 1
            continue
        actual = actual_model(run)
        if actual is None:
            no_usage += 1
            continue
        correct(row, actual, "按 run 实际用的模型重核")
    for row in [r for r in targets if is_local(r)]:
        info = local_line_info(str(row.get("run_id"))[len(LOCAL_RUN_PREFIX):], local_logs_dirs)
        if info is None:
            no_run += 1
            continue
        if not info["model_verified"] or not info["model"]:
            no_usage += 1
            continue
        correct(row, info["model"], "按本机线日志重核")
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
        lines.append(f"  {name}：{fmt(b)} → {fmt(a)}")
    return "\n".join(lines + format_sources(result.get("read_from") or [], result.get("missed") or []))


# ---------------------------------------------------------------- list：一行一条，谁在什么任务上为什么打了这个档

def load_aliases(base: Optional[Path] = None) -> dict[str, list[str]]:
    """俗名表：评价记录目录里的 model-aliases.json（可改，重装不覆盖）；没有就用随代码带的那份；都没有就空表。
    右边写一个或几个正则。"""
    for path in ([base / ALIASES_NAME] if base else []) + [DEFAULT_ALIASES]:
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(raw, dict):
            table: dict[str, list[str]] = {}
            for key, value in raw.items():
                if str(key).startswith("_"):
                    continue
                table[str(key).strip().lower().replace(" ", "")] = [value] if isinstance(value, str) else [str(v) for v in value]
            return table
    return {}


def model_matches(model: Any, query: str, aliases: Optional[Mapping[str, Sequence[str]]] = None) -> bool:
    """--model：先查俗名表（右边是正则），查不到就按子串匹配模型串，不报错。大小写不分。"""
    q = (query or "").strip().lower().replace(" ", "")
    if not q:
        return True
    name = norm_model(model).lower()
    patterns = (aliases or {}).get(q)
    if not patterns:
        return q in name
    for pattern in patterns:
        try:
            if re.search(pattern, name, re.I):
                return True
        except re.error:
            if pattern.lower() in name:
                return True
    return False


def list_reviews(rows: Sequence[Mapping[str, Any]], *, now: datetime, days: int = 7, model: str = "",
                 grade: str = "", aliases: Optional[Mapping[str, Sequence[str]]] = None) -> list[dict[str, Any]]:
    start = occ.fmt_bj(now - timedelta(days=days))
    kept = [r for r in live_reviews(rows) if effective_ts(r) >= start and model_matches(r.get("model"), model, aliases)
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


def local_pending_items(logs_dirs: Optional[Sequence[Path]] = None, *, reviewed: Optional[set] = None,
                        since: Optional[datetime] = None, known: Sequence[str] = (),
                        ) -> list[dict[str, Any]]:
    """本机线里已完工（state=done、退出码 0）、过了 since、没人评、也不在 known（派工记录或看板已记的票）
    里的票。模型取日志里的实际模型。先只读状态文件挑候选，挑中了才流式读日志。"""
    want = {str(t).upper() for t in known} | {str(t).upper() for t in (reviewed or set())}
    since_bj = occ.fmt_bj(since) if since else ""
    picked = [slug for slug, info in list_local_lines(logs_dirs, read_log=False).items()
              if slug.upper() not in want
              and info["state"] == "done" and str(info["exit_code"]).strip() == "0"
              and info["finished_bj"] and info["finished_bj"] >= since_bj]
    items: list[dict[str, Any]] = []
    for slug in picked:
        info = local_line_info(slug, logs_dirs)
        if not info:
            continue
        items.append({
            "ticket": slug.upper(), "model": info["model"] or "未知",
            "executor": f"本机线 {info['engine']}".strip(), "machine": local_machine(),
            "completed_bj": info["finished_bj"], "run_id": LOCAL_RUN_PREFIX + slug,
        })
    return sorted(items, key=lambda p: str(p["completed_bj"]))


# ---------------------------------------------------------------- 命令行

def collect_pending(base: Path, occ_base: Path, since: datetime, now: datetime, *, peers: bool = True,
                    local_logs_dirs: Optional[Sequence[Path]] = None,
                    ) -> tuple[list[dict[str, Any]], int, list[str], list[str]]:
    """三台派工记录 + 看板各执行者最近的 run + 本机线，合起来判：已完工、没评价的票。"""
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
    # 派工记录和看板都没有的（本机线看板只占票、不起 multica run），从本机线日志补上
    local = local_pending_items(local_logs_dirs, reviewed=reviewed, since=since,
                                known=[str(r.get("ticket") or "") for r in rows])
    have = {p["ticket"] for p in items}
    items += [p for p in local if p["ticket"] not in have]
    return sorted(items, key=lambda p: str(p["completed_bj"])), in_flight, read_from, missed


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
    p_list.add_argument("--model", default="", help="认俗名（俗名表 reviews/model-aliases.json 可改，如 小米、spark、glm），查不到俗名就按模型名子串")
    p_list.add_argument("--grade", default="", choices=("",) + GRADES)
    p_list.add_argument("--days", type=int, default=7)
    p_list.add_argument("--local", action="store_true", help="只看本机")
    p_list.add_argument("--json", action="store_true")
    p_nud = sub.add_parser("nudge", help="完工没人评的票凑一批建补评单派出去（tick 每 3 小时调一次，要在 reviews/nudge.json 里开）")
    p_nud.add_argument("--dry-run", action="store_true", help="只出计划，让派工器 dry-run，不标记已批")
    p_nud.add_argument("--force", action="store_true", help="不管开关和间隔，现在就建一张")
    p_res = sub.add_parser("restore", help="本机评价记录丢了或缺了：从另外两台里本机的备份补回")
    p_res.add_argument("--apply", action="store_true", help="真补回；不带只出计划")
    p_mir = sub.add_parser("mirror-sync", help="立刻拉一次另外两台的评价记录备份（tick 每分钟也会拉）")
    p_back = sub.add_parser("backfill-tasks", help="已有评价补任务标题（写旁表，原行不改）")
    p_back.add_argument("--local", action="store_true", help="只看本机")
    p_void = sub.add_parser("void", help="作废一条 run 上的评价（旧行不删，汇总整条不算）")
    p_void.add_argument("ticket")
    p_void.add_argument("note", help="作废原因")
    p_void.add_argument("--run", required=True, help="要作废的 run 号前缀")
    p_void.add_argument("--by", default="", help="谁作废的；缺省读环境里的会话名")
    p_rev = sub.add_parser("reverify-models", help="一次性重核：评价里的模型按 run 实际用的重算，不对的追加更正")
    p_rev.add_argument("--apply", action="store_true", help="真写更正行；不带只出计划")
    p_rev.add_argument("--match", default=REVERIFY_MATCH, help="只核执行者名字匹配这个正则的评价；缺省核全部")
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
            picked = list_reviews(reviews, now=now, days=args.days, model=args.model, grade=args.grade,
                                  aliases=load_aliases(base))
            titles = resolve_titles(base, [str(r.get("ticket") or "") for r in picked if not r.get("task")])
            if args.json:
                for r in picked:
                    r.setdefault("task", None)
                    r["task"] = r.get("task") or titles.get(str(r.get("ticket") or ""))
                print(json.dumps({"reviews": picked, "read_from": read_from, "missed": missed}, ensure_ascii=False))
            else:
                print(format_list(picked, titles, read_from, missed))
            return 0
        if args.cmd == "nudge":
            result = run_nudge(base, occ_base, now=now, force=args.force, dry_run=args.dry_run)
            print(json.dumps(result, ensure_ascii=False))
            return 1 if result.get("error") else 0
        if args.cmd == "restore":
            print(format_restore(restore_from_peers(base, apply=args.apply)))
            return 0
        if args.cmd == "mirror-sync":
            print(json.dumps(sync_mirror(base), ensure_ascii=False))
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
