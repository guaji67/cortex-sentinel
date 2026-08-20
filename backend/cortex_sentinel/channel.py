#!/usr/bin/env python3
"""从一手 status / stderr 推导 Grok / Codex 通道能不能用。零 LLM，单次 < 1 秒。"""

from __future__ import annotations

import argparse
import json
import os
import sys
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cortex_sentinel.paths import channel_status_path, logs_dir as sentinel_logs_dir, registry_path, status_dir
from cortex_sentinel.registry import east_eight_timestamp, sentinel_timestamp_seconds



DEFAULT_LOGS_DIR = None  # 运行时改走 status_dir()；保留名字给旧调用方比对
DEFAULT_STDERR_DIR: Path | None = None
OUTPUT_NAME = "channel-status.json"
FRESH_SECONDS = 60
STATUS_FILE_MAX_AGE_SECONDS = 24 * 3600
# 「不通」判决保质期。跟盯线「30 分钟零进展才算卡死」同一把尺。
# 管的是判决新不新鲜，不管 status 文件还算不算数（那是上面 24 小时那条）。
DOWN_VERDICT_SHELF_SECONDS = 30 * 60
CHANNELS = ("grok", "codex")
# JSON 闭集仍是 alive / degraded / unknown，展示语才是 通 / 不通 / 无数据。
STATUS_UP = "alive"
STATUS_DOWN = "degraded"
STATUS_NODATA = "unknown"
DISPLAY_LABELS = {
    STATUS_UP: "通",
    STATUS_DOWN: "不通",
    STATUS_NODATA: "无数据",
}
TERMINAL_STATES = frozenset(
    {
        "done",
        "help",
        "dead",
        "killed",
        "stopped",
        "stopped_by_operator",
        "stopped_by_dispatcher",
        "killed_by_dispatcher",
    }
)
# 叫醒窗口用的终态闭集：比通道推导那份窄，只含会让人漏报的四种。
UNCLAIMED_TERMINAL_STATES = frozenset({"done", "help", "dead", "killed"})
ACK_FILENAME = "line-terminal-ack.json"
REGISTRY_FILENAME = "codex-line-registry.json"
UNCLAIMED_WINDOW_HOURS = 12
UNCLAIMED_FORMAT_LIMIT = 5
UNCLAIMED_FORMAT_MAX_LINES = 4
SESSION_START_WAKE_POLICY = (
    "派工不算做完：直到本会话挂上一条 persistent Monitor 或后台盯线，"
    "盯着状态文件从非终态翻到终态。\n"
    "盯线一律起这条，一张网盯全部：\n"
    "python3 scripts/health/line_watch.py watch --watch-active --sleep 60 --max-hours 12\n"
    "（对象进终态、状态文件消失、或满 12 小时，它自己退，不留残留循环）\n"
    "别自己写 while true，也别自己写 Monitor 去 glob logs/*.status.json："
    "那个目录躺着上百个历史状态文件，自播种基线只要没生效就会把历史终态整批刷成通知，"
    "刷太快还会被自动掐掉，等于一条都没盯上。\n"
    "终态只有 done / help / dead / killed；running 与 waiting_relay 都不是终态。"
    "终态通知的收件人是 Falcon 和所有窗口，不是派工那个会话。"
    "正本 docs/reference/codex-parallel-worktree-runbook.md「终态通知的收件人是 Falcon，不是你」。\n"
    "可抄：python3 scripts/channel_status.py --ack-all  # seed 基线\n"
    "命中后先一句话报 Falcon，再 python3 scripts/channel_status.py --ack <slug>"
)
HEALTHY_TERMINAL_STATES = frozenset({"done", "help"})
WAITING_RELAY = "waiting_relay"
DEFAULT_STDERR_ROOT = Path("/tmp")
GROK_PREFIX = "grok-"
CODEX_PREFIX = "codex-babysitter-"
STATUS_SUFFIX = ".status.json"
FALLBACK_HINTS = {
    "grok": "回落走 Codex 合同：scripts/codex_babysitter.py（gpt-5.6-sol + xhigh）",
    "codex": "回落走 Grok 合同：scripts/grok_dispatch.py（cursor-grok-4.6-xhigh-fast）",
}


PidAlive = Callable[[int], bool]


@dataclass(frozen=True)
class DispatchChannelDecision:
    allowed: bool
    line: str
    warning: str | None = None
    refusal: str | None = None


def resolve_logs_dir(logs_dir: Path | None = None) -> Path:
    """显式参数优先；否则认 CORTEX_LOGS_DIR（给 hook 测试隔离用）；再退回仓内 logs/。"""
    if logs_dir is not None:
        return Path(logs_dir)
    override = os.environ.get("CORTEX_LOGS_DIR", "").strip()
    return Path(override) if override else status_dir()


def pid_is_alive(pid: int) -> bool:
    """os.kill(pid, 0) 通过才算进程还在；PermissionError 也算还在。"""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def _as_int(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def _parse_time(value: object) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    text = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _line_pid(payload: dict[str, Any], channel: str) -> int | None:
    if channel == "grok":
        return _as_int(payload.get("agent_pid"))
    return _as_int(payload.get("babysitter_pid")) or _as_int(payload.get("codex_pid"))


def _stderr_path(stderr_dir: Path, channel: str, slug: str) -> Path:
    prefix = "grok" if channel == "grok" else "bs"
    return stderr_dir / f"{prefix}-{slug}.err"


def _stdout_log_path(
    logs_dir: Path,
    channel: str,
    slug: str,
    payload: dict[str, Any],
) -> Path:
    raw_log_path = payload.get("log_path")
    if isinstance(raw_log_path, str) and raw_log_path.strip():
        log_path = Path(raw_log_path.strip()).expanduser()
        if log_path.is_absolute():
            return log_path
        return logs_dir / log_path
    prefix = "grok" if channel == "grok" else "codex"
    local = logs_dir / f"{prefix}-{slug}.log"
    try:
        using_home = logs_dir.resolve() == status_dir().resolve()
    except OSError:
        using_home = False
    if using_home:
        return sentinel_logs_dir() / f"{prefix}-{slug}.log"
    return local


def _stderr_sidecar_path(stderr_dir: Path | None, channel: str, slug: str) -> Path:
    root = stderr_dir if stderr_dir is not None else DEFAULT_STDERR_ROOT
    return _stderr_path(root, channel, slug)


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _file_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


def _stderr_excerpt(text: str, limit: int = 80) -> str:
    for line in text.splitlines():
        compact = line.strip()
        if not compact:
            continue
        if len(compact) <= limit:
            return compact
        return compact[: limit - 1] + "…"
    return ""


def _stdout_empty(item: dict[str, Any]) -> bool:
    size = item.get("stdout_bytes")
    if isinstance(size, int):
        return size <= 0
    return True


def _channel_failure_reason(item: dict[str, Any]) -> str | None:
    """通只认返回码和 stderr。stdout 空不能当健康；不靠关键词清单。"""
    state = str(item.get("state") or "")
    exit_code = item.get("exit_code")
    stderr = str(item.get("stderr_text") or "").strip()
    excerpt = _stderr_excerpt(stderr) if stderr else ""
    failed_exit = isinstance(exit_code, int) and exit_code != 0

    if state == "done":
        if failed_exit:
            return excerpt or f"exit_code={exit_code}"
        if _stdout_empty(item) and excerpt:
            return excerpt
        return None
    if state in {"dead", "killed"}:
        if failed_exit:
            return excerpt or f"exit_code={exit_code}"
        if excerpt:
            return excerpt
        return None
    return None


def display_label(status: str) -> str:
    return DISPLAY_LABELS.get(status, DISPLAY_LABELS[STATUS_NODATA])


def _status_file_fresh(path: Path, now: datetime, max_age: float = STATUS_FILE_MAX_AGE_SECONDS) -> bool:
    try:
        mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    except OSError:
        return False
    clock = now if now.tzinfo is not None else now.replace(tzinfo=timezone.utc)
    age = (clock.astimezone(timezone.utc) - mtime).total_seconds()
    return age <= max_age


def _collect_lines(
    logs_dir: Path,
    channel: str,
    *,
    pid_alive: PidAlive,
    stderr_dir: Path | None,
    now: datetime,
) -> list[dict[str, Any]]:
    prefix = GROK_PREFIX if channel == "grok" else CODEX_PREFIX
    lines: list[dict[str, Any]] = []
    try:
        names = sorted(os.listdir(logs_dir))
    except OSError:
        return lines

    for name in names:
        if not name.startswith(prefix) or not name.endswith(STATUS_SUFFIX):
            continue
        path = logs_dir / name
        if not _status_file_fresh(path, now):
            continue
        payload = _read_json(path)
        if payload is None:
            continue
        slug = str(payload.get("slug") or name[len(prefix) : -len(STATUS_SUFFIX)])
        state = str(payload.get("state") or "").strip().lower()
        pid = _line_pid(payload, channel)
        started_at = _parse_time(payload.get("started_at"))
        updated_at = _parse_time(payload.get("updated_at"))
        alive = bool(pid is not None and pid_alive(pid))
        stdout_path = _stdout_log_path(logs_dir, channel, slug, payload)
        stderr_path = _stderr_sidecar_path(stderr_dir, channel, slug)
        stdout_bytes = _as_int(payload.get("log_bytes"))
        if stdout_bytes is None:
            stdout_bytes = _file_size(stdout_path)
        stderr_text = _read_text(stderr_path)
        anomaly = state == "running" and pid is not None and not alive
        running = state == "running" and alive
        lines.append(
            {
                "slug": slug,
                "state": state,
                "pid": pid,
                "alive": alive,
                "running": running,
                "anomaly": anomaly,
                "started_at": started_at,
                "updated_at": updated_at,
                "exit_code": _as_int(payload.get("exit_code")),
                "stdout_bytes": stdout_bytes,
                "stderr_path": stderr_path,
                "stderr_text": stderr_text,
                "source": path.name,
            }
        )
    return lines


def _sort_recent(lines: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return sorted(
        lines,
        key=lambda item: (
            item["started_at"] is not None,
            item["started_at"] or datetime.min.replace(tzinfo=timezone.utc),
            item["slug"],
        ),
        reverse=True,
    )


def _count_evidence(running: int, terminal: int) -> str:
    parts: list[str] = []
    if running:
        parts.append(f"{running} 条在跑")
    if terminal:
        parts.append(f"{terminal} 条终态")
    return "，".join(parts)


def _is_channel_down(item: dict[str, Any]) -> str | None:
    return _channel_failure_reason(item)


def _aware_datetime(value: object) -> datetime | None:
    if isinstance(value, datetime):
        return value if value.tzinfo is not None else None
    return _parse_time(value)


def _failure_age_seconds(item: dict[str, Any], now: datetime) -> float | None:
    """失败记录年龄只认 last.updated_at，不认快照 generated_at。"""
    moment = _aware_datetime(item.get("updated_at"))
    if moment is None:
        return None
    clock = now if now.tzinfo is not None else now.replace(tzinfo=timezone.utc)
    return (clock.astimezone(timezone.utc) - moment.astimezone(timezone.utc)).total_seconds()


def _format_duration_zh(seconds: float) -> str:
    total = max(0, int(round(seconds)))
    minutes, remainder = divmod(total, 60)
    if minutes and remainder:
        return f"{minutes} 分 {remainder} 秒"
    if minutes:
        return f"{minutes} 分钟"
    return f"{remainder} 秒"


def derive_channel(
    lines: list[dict[str, Any]],
    now: datetime | None = None,
) -> dict[str, Any]:
    running = [item for item in lines if item["running"]]
    anomalies = [item for item in lines if item["anomaly"]]
    recent = _sort_recent(lines)
    last = recent[0] if recent else None
    n_terminal = sum(
        1 for item in lines if item["state"] in UNCLAIMED_TERMINAL_STATES
    )
    down_meta: dict[str, int] = {}

    if not lines:
        status = STATUS_NODATA
        evidence = "无数据"
    elif running:
        status = STATUS_UP
        evidence = _count_evidence(len(running), n_terminal)
    else:
        down_reason = _is_channel_down(last) if last is not None else None
        if down_reason:
            clock = now if now is not None else datetime.now(timezone.utc)
            age = _failure_age_seconds(last, clock)
            if age is not None and age < 0:
                age = 0.0
            # 保质期内含边界：age <= 30min 仍拦；严格超过才放行。
            if age is None or age > DOWN_VERDICT_SHELF_SECONDS:
                status = STATUS_NODATA
                if age is None:
                    evidence = "上次失败时间无法判定，已超过保质期，通道状态待一次真派工确认"
                else:
                    evidence = (
                        f"上次失败在 {_format_duration_zh(age)}前，已超过保质期，"
                        "通道状态待一次真派工确认"
                    )
            else:
                status = STATUS_DOWN
                evidence = down_reason
                down_meta = {
                    "down_age_seconds": int(age),
                    "down_shelf_remaining_seconds": int(DOWN_VERDICT_SHELF_SECONDS - age),
                }
        elif last is not None and last["state"] == WAITING_RELAY:
            status = STATUS_UP
            evidence = _count_evidence(0, n_terminal)
        elif last is not None and last["state"] == "help":
            status = STATUS_UP
            evidence = _count_evidence(0, n_terminal)
        elif last is not None and last["state"] == "done":
            exit_ok = last.get("exit_code") in (0, None)
            if exit_ok and not _stdout_empty(last):
                status = STATUS_UP
                evidence = _count_evidence(0, n_terminal)
            else:
                status = STATUS_NODATA
                evidence = "stdout 空，不能当成通"
        elif last is not None and last["state"] in TERMINAL_STATES - HEALTHY_TERMINAL_STATES:
            status = STATUS_NODATA
            if str(last.get("stderr_text") or "").strip():
                evidence_detail = "现有失败证据未含通道返回码"
            else:
                evidence_detail = "拿不到失败原因"
            evidence = f"最近一次派工终态 {last['state']}，{evidence_detail}，通道状态未知"
        else:
            status = STATUS_NODATA
            evidence = "最近无在跑线"

    payload: dict[str, Any] = {
        "status": status,
        "evidence": evidence,
        "running": len(running),
        "terminal": n_terminal,
        "anomalies": [
            {
                "slug": item["slug"],
                "state": item["state"],
                "pid": item["pid"],
            }
            for item in anomalies
        ],
    }
    payload.update(down_meta)
    return payload


def derive_snapshot(
    *,
    logs_dir: Path | None = None,
    stderr_dir: Path | None = None,
    pid_alive: PidAlive | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    logs = resolve_logs_dir(logs_dir)
    stderr = stderr_dir if stderr_dir is not None else DEFAULT_STDERR_DIR
    checker = pid_alive or pid_is_alive
    clock = now or datetime.now(timezone.utc)
    generated_at = east_eight_timestamp(clock)
    channels = {
        channel: derive_channel(
            _collect_lines(logs, channel, pid_alive=checker, stderr_dir=stderr, now=clock),
            now=clock,
        )
        for channel in CHANNELS
    }
    return {
        "generated_at": generated_at,
        "channels": channels,
    }


def write_snapshot(snapshot: dict[str, Any], path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(snapshot, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def _generated_at_age_seconds(payload: dict[str, Any], now: datetime) -> float | None:
    generated = _parse_time(payload.get("generated_at"))
    if generated is None:
        return None
    current = now if now.tzinfo is not None else now.replace(tzinfo=timezone.utc)
    return (current.astimezone(generated.tzinfo) - generated).total_seconds()


def load_fresh_snapshot(
    path: Path,
    *,
    now: datetime | None = None,
    max_age_seconds: int = FRESH_SECONDS,
) -> dict[str, Any] | None:
    payload = _read_json(path)
    if payload is None:
        return None
    clock = now or datetime.now(timezone.utc)
    age = _generated_at_age_seconds(payload, clock)
    if age is None or age < 0 or age > max_age_seconds:
        return None
    channels = payload.get("channels")
    if not isinstance(channels, dict):
        return None
    return payload


def load_or_refresh(
    *,
    logs_dir: Path | None = None,
    output_path: Path | None = None,
    stderr_dir: Path | None = None,
    pid_alive: PidAlive | None = None,
    now: datetime | None = None,
    max_age_seconds: int = FRESH_SECONDS,
) -> dict[str, Any]:
    logs = resolve_logs_dir(logs_dir)
    if output_path is not None:
        target = output_path
    else:
        try:
            using_home = logs.resolve() == status_dir().resolve()
        except OSError:
            using_home = False
        target = channel_status_path() if using_home else (logs / OUTPUT_NAME)
    fresh = load_fresh_snapshot(target, now=now, max_age_seconds=max_age_seconds)
    if fresh is not None:
        return fresh
    snapshot = derive_snapshot(
        logs_dir=logs,
        stderr_dir=stderr_dir,
        pid_alive=pid_alive,
        now=now,
    )
    write_snapshot(snapshot, target)
    return snapshot


def _format_up_counts(item: dict[str, Any]) -> str:
    running = item.get("running")
    terminal = item.get("terminal")
    n_running = running if isinstance(running, int) else 0
    n_terminal = terminal if isinstance(terminal, int) else 0
    return _count_evidence(n_running, n_terminal)


def _format_one(name: str, item: dict[str, Any]) -> str:
    status = str(item.get("status") or "").strip()
    if not status:
        raise ValueError(f"{name} status empty")
    label = display_label(status)
    if status == STATUS_UP:
        counts = _format_up_counts(item)
        if counts:
            return f"{name}={label}（{counts}）"
        return f"{name}={label}"
    if status == STATUS_DOWN:
        evidence = str(item.get("evidence") or "").strip()
        if evidence and evidence != label:
            return f"{name}={label}（{evidence}）"
        return f"{name}={label}"
    return f"{name}={label}"


def format_hook_line(snapshot: dict[str, Any]) -> str:
    channels = snapshot.get("channels")
    if not isinstance(channels, dict):
        raise ValueError("channel snapshot missing channels")
    parts: list[str] = []
    for name in CHANNELS:
        item = channels.get(name)
        if not isinstance(item, dict):
            raise ValueError(f"channel snapshot missing {name}")
        parts.append(_format_one(name, item))
    return "通道现状: " + " ".join(parts)


HOOK_LINE_UNAVAILABLE = "通道现状取不到，取不到本身不构成通道不可用的理由"


def format_hook_line_safe(
    snapshot: dict[str, Any] | None = None,
    *,
    path: Path | None = None,
    refresh: Callable[..., dict[str, Any]] | None = None,
    now: datetime | None = None,
    max_age_seconds: int = FRESH_SECONDS,
) -> str:
    """给 hook 提示用的通道现状行。取不到时返回固定降级句，绝不抛。

    判定语义仍走 ``load_or_refresh`` / ``load_fresh_snapshot`` / ``format_hook_line``，
    这里只包一层失败降级，不另写探测。
    """
    try:
        if snapshot is not None:
            return format_hook_line(snapshot)
        if path is not None:
            loaded = load_fresh_snapshot(
                path, now=now, max_age_seconds=max_age_seconds
            )
            if loaded is None:
                return HOOK_LINE_UNAVAILABLE
            return format_hook_line(loaded)
        current = (refresh or load_or_refresh)()
        return format_hook_line(current)
    except Exception:
        return HOOK_LINE_UNAVAILABLE


def format_channel_line(snapshot: dict[str, Any], channel: str) -> str:
    channels = snapshot.get("channels")
    if not isinstance(channels, dict):
        raise ValueError("channel snapshot missing channels")
    item = channels.get(channel)
    if not isinstance(item, dict):
        raise ValueError(f"channel snapshot missing {channel}")
    return "通道现状: " + _format_one(channel, item)


def _format_down_refusal(channel: str, item: dict[str, Any], evidence: str) -> str:
    hint = FALLBACK_HINTS.get(channel, "")
    age = item.get("down_age_seconds")
    remaining = item.get("down_shelf_remaining_seconds")
    parts = [f"{channel} 不通: {evidence or '有 stderr 证据'}。"]
    if isinstance(age, (int, float)):
        parts.append(f"失败发生在 {_format_duration_zh(float(age))}前")
        if isinstance(remaining, (int, float)):
            parts.append(f"，保质期还剩 {_format_duration_zh(float(remaining))}")
        parts.append("。")
    parts.append("可用 --ignore-channel-status 强制发射。")
    if hint:
        parts.append(hint)
    return "".join(parts).strip()


def evaluate_dispatch_channel(
    channel: str,
    *,
    ignore: bool = False,
    snapshot: dict[str, Any] | None = None,
    refresh: Callable[..., dict[str, Any]] | None = None,
) -> DispatchChannelDecision:
    try:
        current = snapshot if snapshot is not None else (refresh or load_or_refresh)()
        line = format_channel_line(current, channel)
        item = current.get("channels", {}).get(channel) if isinstance(current.get("channels"), dict) else None
        status = str(item.get("status") or "") if isinstance(item, dict) else STATUS_NODATA
        evidence = str(item.get("evidence") or "").strip() if isinstance(item, dict) else ""
        if status == STATUS_DOWN and not ignore:
            refusal = _format_down_refusal(
                channel,
                item if isinstance(item, dict) else {},
                evidence,
            )
            return DispatchChannelDecision(False, line, refusal=refusal)
        warning = None
        if ignore and status == STATUS_DOWN:
            warning = f"WARNING 已用 --ignore-channel-status，忽略 {channel} 不通继续发射"
        return DispatchChannelDecision(True, line, warning=warning)
    except Exception as exc:
        return DispatchChannelDecision(
            True,
            "",
            warning=f"WARNING 通道现状推导失败，静默放行: {exc}",
        )


def apply_dispatch_channel_gate(
    channel: str,
    *,
    ignore: bool = False,
    snapshot: dict[str, Any] | None = None,
    refresh: Callable[..., dict[str, Any]] | None = None,
) -> DispatchChannelDecision:
    decision = evaluate_dispatch_channel(
        channel,
        ignore=ignore,
        snapshot=snapshot,
        refresh=refresh,
    )
    if decision.line:
        print(decision.line, flush=True)
    if decision.warning:
        print(decision.warning, file=sys.stderr, flush=True)
    if not decision.allowed and decision.refusal:
        print(decision.refusal, file=sys.stderr, flush=True)
    return decision


def _within_hours(moment: datetime, now: datetime, window_hours: float) -> bool:
    current = now if now.tzinfo is not None else now.replace(tzinfo=timezone.utc)
    age = (current.astimezone(timezone.utc) - moment.astimezone(timezone.utc)).total_seconds()
    return 0 <= age <= window_hours * 3600


def _optional_text(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    return text or None


def _short_text(value: str, limit: int = 24) -> str:
    compact = " ".join(value.split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1] + "…"


def _load_registry_by_slug(logs_dir: Path) -> dict[str, dict[str, str]]:
    payload: Any
    path = logs_dir / "registry.json"
    if not path.exists():
        legacy = logs_dir / REGISTRY_FILENAME
        if legacy.exists():
            path = legacy
        elif (logs_dir.parent / "registry.json").exists():
            path = logs_dir.parent / "registry.json"
        else:
            path = registry_path()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return {}
    rows: list[Any]
    if isinstance(payload, list):
        rows = payload
    elif isinstance(payload, dict) and isinstance(payload.get("lines"), list):
        rows = payload["lines"]
    else:
        return {}
    lookup: dict[str, dict[str, str]] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        slug = _optional_text(row.get("slug"))
        if not slug:
            continue
        lookup[slug] = {
            "label_zh": _optional_text(row.get("label_zh")) or "",
            "dispatcher_zh": _optional_text(row.get("dispatcher_zh")) or "",
        }
    return lookup


def load_ack_ledger(path: Path) -> dict[str, dict[str, Any]]:
    payload = _read_json(path)
    if payload is None:
        return {}
    raw = payload.get("acks") if isinstance(payload.get("acks"), dict) else payload
    if not isinstance(raw, dict):
        return {}
    ledger: dict[str, dict[str, Any]] = {}
    for key, row in raw.items():
        if key == "acks" or not isinstance(row, dict):
            continue
        state = _optional_text(row.get("state"))
        updated_at = _optional_text(row.get("updated_at"))
        if not state or not updated_at:
            continue
        channel = _optional_text(row.get("channel"))
        slug = _optional_text(row.get("slug"))
        ledger_key = _ack_key(channel, slug) if channel and slug else str(key)
        ledger[ledger_key] = {
            "state": state,
            "updated_at": updated_at,
            "acked_at": _optional_text(row.get("acked_at")) or "",
            "channel": channel or "",
            "slug": slug or "",
        }
    return ledger


def write_ack_ledger(path: Path, acks: dict[str, dict[str, Any]]) -> Path:
    return write_snapshot({"acks": acks}, path)


def ack_ledger_path(logs_dir: Path | None = None) -> Path:
    return resolve_logs_dir(logs_dir) / ACK_FILENAME


def _status_prefix_for_name(name: str) -> str | None:
    if name.startswith(GROK_PREFIX) and name.endswith(STATUS_SUFFIX):
        return GROK_PREFIX
    if name.startswith(CODEX_PREFIX) and name.endswith(STATUS_SUFFIX):
        return CODEX_PREFIX
    return None


def _ack_key(channel: str, slug: str) -> str:
    return f"{channel}:{slug}"


def _instant_seconds(value: object) -> float | None:
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return None
        return value.timestamp()
    return sentinel_timestamp_seconds(value)


def _timestamps_match(left: object, right: object) -> bool:
    """同一瞬间即算同一终态签名，不要求 +08:00 / +00:00 / 微秒写法一致。"""
    if left == right:
        return True
    left_s = _instant_seconds(left)
    right_s = _instant_seconds(right)
    if left_s is None or right_s is None:
        return False
    return int(left_s) == int(right_s)


def _item_requested(item: dict[str, Any], wanted: set[str]) -> bool:
    slug = str(item.get("slug") or "")
    channel = str(item.get("channel") or "")
    if slug in wanted:
        return True
    identity = _ack_key(channel, slug) if channel else slug
    return identity in wanted


def _collect_terminal_candidates(
    logs_dir: Path,
    *,
    now: datetime,
    window_hours: float,
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    try:
        names = os.listdir(logs_dir)
    except OSError:
        return results
    for name in names:
        prefix = _status_prefix_for_name(name)
        if prefix is None:
            continue
        payload = _read_json(logs_dir / name)
        if payload is None:
            continue
        state = str(payload.get("state") or "").strip().lower()
        if state not in UNCLAIMED_TERMINAL_STATES:
            continue
        updated_raw = _optional_text(payload.get("updated_at"))
        if updated_raw is None:
            continue
        parsed = _parse_time(updated_raw)
        if parsed is None or not _within_hours(parsed, now, window_hours):
            continue
        slug = str(payload.get("slug") or name[len(prefix) : -len(STATUS_SUFFIX)]).strip()
        if not slug:
            continue
        channel = "grok" if prefix == GROK_PREFIX else "codex"
        results.append(
            {
                "channel": channel,
                "slug": slug,
                "state": state,
                "updated_at": updated_raw,
                "exit_code": _as_int(payload.get("exit_code")),
                "branch": _optional_text(payload.get("branch")),
                "workdir": _optional_text(payload.get("workdir")),
                "label_zh": "",
                "dispatcher_zh": "",
                "source": name,
            }
        )
    results.sort(
        key=lambda item: (
            _instant_seconds(item["updated_at"]) or 0.0,
            item["channel"],
            item["slug"],
        ),
        reverse=True,
    )
    return results


def _with_registry(entries: list[dict[str, Any]], logs_dir: Path) -> list[dict[str, Any]]:
    registry = _load_registry_by_slug(logs_dir)
    enriched: list[dict[str, Any]] = []
    for item in entries:
        extra = registry.get(item["slug"], {})
        row = dict(item)
        row["label_zh"] = extra.get("label_zh") or ""
        row["dispatcher_zh"] = extra.get("dispatcher_zh") or ""
        enriched.append(row)
    return enriched


def _is_acked(entry: dict[str, Any], ledger: dict[str, dict[str, Any]]) -> bool:
    channel = str(entry.get("channel") or "")
    slug = str(entry.get("slug") or "")
    rows = (ledger.get(_ack_key(channel, slug)), ledger.get(slug))
    return any(
        row
        and row.get("state") == entry.get("state")
        and _timestamps_match(row.get("updated_at"), entry.get("updated_at"))
        for row in rows
    )


def _ledger_rows_from_entries(
    entries: list[dict[str, Any]],
    *,
    now: datetime,
) -> dict[str, dict[str, Any]]:
    stamped = east_eight_timestamp(now)
    rows: dict[str, dict[str, Any]] = {}
    for item in entries:
        channel = str(item.get("channel") or "").strip()
        slug = str(item.get("slug") or "").strip()
        if not channel or not slug:
            continue
        rows[_ack_key(channel, slug)] = {
            "channel": channel,
            "slug": slug,
            "state": item["state"],
            "updated_at": item["updated_at"],
            "acked_at": stamped,
        }
    return rows


def _seed_ack_ledger_if_absent(
    path: Path,
    candidates: list[dict[str, Any]],
    *,
    now: datetime,
) -> bool:
    """台账文件不存在时把当前窗口终态写成基线。

    返回 True = 这一次按冷启动处理（成功或失败都不显示）。
    文件存在（哪怕内容是坏 JSON）返回 False，走原 fail-open 读路径。
    """
    try:
        if path.exists():
            return False
    except OSError:
        return True
    try:
        write_ack_ledger(path, _ledger_rows_from_entries(candidates, now=now))
    except Exception:
        pass
    return True


def unclaimed_terminal_lines(
    now: datetime | None = None,
    window_hours: float = UNCLAIMED_WINDOW_HOURS,
    logs_dir: Path | None = None,
) -> list[dict[str, Any]]:
    """扫 status.json，返回窗口内未认领终态。任何 IO/JSON 异常都返回空列表。"""
    try:
        logs = resolve_logs_dir(logs_dir)
        clock = now or datetime.now(timezone.utc)
        candidates = _with_registry(
            _collect_terminal_candidates(logs, now=clock, window_hours=window_hours),
            logs,
        )
        ledger_path = ack_ledger_path(logs)
        if _seed_ack_ledger_if_absent(ledger_path, candidates, now=clock):
            return []
        ledger = load_ack_ledger(ledger_path)
        return [item for item in candidates if not _is_acked(item, ledger)]
    except Exception:
        return []


def format_unclaimed_line(
    entries: list[dict[str, Any]],
    limit: int = UNCLAIMED_FORMAT_LIMIT,
) -> str:
    """一到两行紧凑文本；空列表返回空字符串；整块最多 4 行。"""
    if not entries:
        return ""
    shown = entries[: max(0, limit)]
    rest = len(entries) - len(shown)
    items: list[str] = []
    for item in shown:
        channel = str(item.get("channel") or "").strip()
        slug = str(item.get("slug") or "").strip() or "?"
        state = str(item.get("state") or "").strip() or "?"
        dispatcher = _short_text(str(item.get("dispatcher_zh") or "").strip() or "未登记")
        identity = _ack_key(channel, slug) if channel else slug
        items.append(f"{identity}={state}（{dispatcher}）")
    head = f"未认领终态 {len(entries)} 条: " + " ".join(items)
    if rest > 0:
        head += f"；还有 {rest} 条"
    ack = "认领: python3 scripts/channel_status.py --ack <slug>"
    if len(entries) > 1:
        ack += "  或 --ack-all"
    text = f"{head}\n{ack}"
    lines = text.splitlines()
    if len(lines) > UNCLAIMED_FORMAT_MAX_LINES:
        text = "\n".join(lines[:UNCLAIMED_FORMAT_MAX_LINES])
    return text


def format_session_start_wake_block(
    now: datetime | None = None,
    logs_dir: Path | None = None,
) -> str:
    """开工注入：未认领清单（可空）+ 强制口径。未认领为空时仍返回口径。"""
    try:
        unclaimed = format_unclaimed_line(unclaimed_terminal_lines(now=now, logs_dir=logs_dir))
    except Exception:
        unclaimed = ""
    if unclaimed:
        return unclaimed + "\n" + SESSION_START_WAKE_POLICY
    return SESSION_START_WAKE_POLICY


def ack_terminal_lines(
    slugs: list[str] | None = None,
    *,
    ack_all: bool = False,
    logs_dir: Path | None = None,
    now: datetime | None = None,
    window_hours: float = UNCLAIMED_WINDOW_HOURS,
) -> list[dict[str, Any]]:
    """按通道和当前终态签名认领；同一 slug 的不同通道互不覆盖。"""
    logs = resolve_logs_dir(logs_dir)
    clock = now or datetime.now(timezone.utc)
    candidates = _with_registry(
        _collect_terminal_candidates(logs, now=clock, window_hours=window_hours),
        logs,
    )
    ledger = load_ack_ledger(ack_ledger_path(logs))
    if ack_all:
        targets = [item for item in candidates if not _is_acked(item, ledger)]
    else:
        wanted = {slug.strip() for slug in (slugs or []) if slug.strip()}
        targets = [
            item
            for item in candidates
            if _item_requested(item, wanted) and not _is_acked(item, ledger)
        ]
    ledger.update(_ledger_rows_from_entries(targets, now=clock))
    write_ack_ledger(ack_ledger_path(logs), ledger)
    return targets


def _run_unclaimed_cli(args: argparse.Namespace) -> int:
    logs = args.logs_dir if args.logs_dir is not None else resolve_logs_dir()
    if args.list_unclaimed and not args.ack and not args.ack_all:
        text = format_unclaimed_line(unclaimed_terminal_lines(logs_dir=logs))
        if text:
            print(text)
        return 0
    acked = ack_terminal_lines(
        list(args.ack or []),
        ack_all=bool(args.ack_all),
        logs_dir=logs,
    )
    if not acked:
        print("没有可认领的终态", file=sys.stderr)
        return 0
    for item in acked:
        print(
            f"acked {_ack_key(item['channel'], item['slug'])} "
            f"{item['state']}|{item['updated_at']}"
        )
    remaining = format_unclaimed_line(unclaimed_terminal_lines(logs_dir=logs))
    if remaining:
        print(remaining)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Derive Grok/Codex channel status from first-hand files")
    parser.add_argument("--logs-dir", type=Path, default=None)
    parser.add_argument("--stderr-dir", type=Path, default=DEFAULT_STDERR_DIR)
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--ack", nargs="+", metavar="SLUG", help="认领一个或多个终态 slug")
    parser.add_argument("--ack-all", action="store_true", help="认领当前窗口内全部未认领终态")
    parser.add_argument("--list-unclaimed", action="store_true", help="打印当前未认领终态清单")
    args = parser.parse_args(argv)
    if args.ack or args.ack_all or args.list_unclaimed:
        if args.logs_dir is None:
            args.logs_dir = resolve_logs_dir()
        return _run_unclaimed_cli(args)
    logs = args.logs_dir if args.logs_dir is not None else resolve_logs_dir()
    snapshot = derive_snapshot(logs_dir=logs, stderr_dir=args.stderr_dir)
    try:
        using_home = logs.resolve() == status_dir().resolve()
    except OSError:
        using_home = False
    output = args.output or (channel_status_path() if using_home else logs / OUTPUT_NAME)
    write_snapshot(snapshot, output)
    print(json.dumps(snapshot, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
