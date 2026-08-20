#!/usr/bin/env python3
"""把 Multica run 终态翻译成哨兵认识的 logs/grok-*.status.json。

Multica 自己从不写 status.json，派工会话一死这条线就没人知道。
这座桥只在「该票没有任何 running/queued run」时写终态；有活 run 就清掉旧文件。

观察名单分两层：手工/派工写入的 issue_ids，加上本轮 `issue list --status in_progress`
自动发现的票。两边合并，不是替换。一票进终态并且已经写出 status.json 之后从自动
发现集合退休，避免每回合把历史票再查一遍。整次同步有墙钟预算，超了必须打印
「本轮只刷了 N/M，下轮接着刷」，不许静默截断。

默认挂在每个窗口的每回合注入里刷。没窗口在跑时不会刷——不装 launchd。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from cortex_sentinel.paths import sentinel_home, status_dir
from cortex_sentinel.registry import (
    LineRegistryError,
    east_eight_timestamp,
    upsert_line_registration,
)


DEFAULT_LOGS_DIR = None
LINE_REGISTRY_NAME = "codex-line-registry.json"
WATCH_FILENAME = "multica-notify-watch.json"
STAMP_FILENAME = "multica-notify-stamp.json"
STATUS_PREFIX = "grok-"
STATUS_SUFFIX = ".status.json"
ENGINE = "cursor-grok"
DEFAULT_MODEL = "multica"
NOTE = "multica"
ACTIVE_STATUSES = frozenset({"running", "queued"})
STATUS_MAP = {
    "completed": "done",
    "failed": "dead",
    "cancelled": "killed",
}
STATE_PRIORITY = ("done", "dead", "killed")
EXIT_CODES = {"done": 0, "dead": 1, "killed": -15}
EAST_EIGHT = timezone(timedelta(hours=8))
HOOK_THROTTLE_SECONDS = 45.0
HOOK_COMMAND_TIMEOUT = 8
HOOK_WALL_CLOCK_SECONDS = 4.0
HOOK_MIN_CALL_SECONDS = 0.2
CLI_COMMAND_TIMEOUT = 30
SYNC_WALL_CLOCK_SECONDS = 20.0
LIST_PAGE_SIZE = 100
DISCOVER_STATUS = "in_progress"
LEDGER_NAME = "dispatch-ledger.jsonl"
RETIRE_ACTIONS = frozenset({"wrote", "unchanged"})
AGENT_HOST_MAP_PATH = Path(__file__).resolve().parent.parent / "data" / "agent-host-map.yaml"

JsonDict = dict[str, Any]
CommandRunner = Callable[..., Any]
Clock = Callable[[], float]


class MulticaNotifyError(RuntimeError):
    """Multica 终态桥合同不成立。"""


class HookBudgetExceeded(MulticaNotifyError):
    """本轮墙钟用完，剩下的留给下次刷新。"""


@dataclass(frozen=True)
class TerminalDecision:
    state: str
    winners: tuple[JsonDict, ...]
    model: str
    started_at: str
    updated_at: str
    exit_code: int


@dataclass(frozen=True)
class SyncResult:
    issue: str
    slug: str
    action: str
    state: str | None
    path: str | None
    reason: str


@dataclass
class WatchState:
    issue_ids: list[str]
    auto_issue_ids: list[str]
    retired: dict[str, str]
    pending_issue_ids: list[str]


def resolve_logs_dir(logs_dir: Path | None = None) -> Path:
    if logs_dir is not None:
        return Path(logs_dir)
    override = os.environ.get("CORTEX_LOGS_DIR", "").strip()
    return Path(override) if override else status_dir()


def hook_refresh_enabled() -> bool:
    flag = os.environ.get("CORTEX_MULTICA_NOTIFY_DISABLE", "").strip().lower()
    if flag in {"1", "true", "yes"}:
        return False
    if os.environ.get("PYTEST_CURRENT_TEST"):
        return False
    return True


def status_filename(slug: str) -> str:
    return f"{STATUS_PREFIX}{slug}{STATUS_SUFFIX}"


def status_path(logs_dir: Path, slug: str) -> Path:
    return logs_dir / status_filename(slug)


def slug_from_identifier(identifier: str) -> str:
    text = identifier.strip().lower()
    if not text:
        raise MulticaNotifyError("empty issue identifier")
    return text


def _as_dict(value: object) -> JsonDict:
    return dict(value) if isinstance(value, Mapping) else {}


def _as_list(value: object) -> list[Any]:
    return list(value) if isinstance(value, list) else []


def run_status(run: Mapping[str, Any]) -> str:
    return str(run.get("status") or "").strip().lower()


def to_east_eight(value: object, *, fallback: datetime | None = None) -> str:
    if isinstance(value, str) and value.strip():
        try:
            parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        except ValueError:
            parsed = None
        else:
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.astimezone(EAST_EIGHT).isoformat(timespec="seconds")
    clock = fallback or datetime.now(timezone.utc)
    return east_eight_timestamp(clock)


def _time_key(value: object) -> str:
    return to_east_eight(value)


def run_model(run: Mapping[str, Any]) -> str:
    usage = run.get("usage")
    if isinstance(usage, list):
        for item in usage:
            if not isinstance(item, Mapping):
                continue
            model = str(item.get("model") or "").strip()
            if model:
                return model
    return DEFAULT_MODEL


def decide_issue_terminal(runs: Sequence[Mapping[str, Any]]) -> TerminalDecision | None:
    """该票没有任何 running/queued 才算终态。只看最新一条会把重复排队的 cancelled 误报成终态。"""
    rows = [_as_dict(item) for item in runs]
    if not rows:
        return None
    if any(run_status(item) in ACTIVE_STATUSES for item in rows):
        return None

    mapped: list[tuple[str, JsonDict]] = []
    for item in rows:
        state = STATUS_MAP.get(run_status(item))
        if state:
            mapped.append((state, item))
    if not mapped:
        return None

    winners: list[JsonDict] = []
    chosen = ""
    for state in STATE_PRIORITY:
        group = [item for mapped_state, item in mapped if mapped_state == state]
        if group:
            chosen = state
            winners = group
            break
    if not chosen:
        return None

    started_source = min(
        (item.get("started_at") or item.get("created_at") or "" for item in winners),
        key=_time_key,
    )
    updated_source = max(
        (item.get("completed_at") or item.get("started_at") or item.get("created_at") or "" for item in winners),
        key=_time_key,
    )
    return TerminalDecision(
        state=chosen,
        winners=tuple(winners),
        model=run_model(winners[-1]),
        started_at=to_east_eight(started_source),
        updated_at=to_east_eight(updated_source),
        exit_code=EXIT_CODES[chosen],
    )


def status_payload(
    *,
    slug: str,
    decision: TerminalDecision,
) -> dict[str, object]:
    return {
        "engine": ENGINE,
        "slug": slug,
        "state": decision.state,
        "model": decision.model,
        "started_at": decision.started_at,
        "updated_at": decision.updated_at,
        "exit_code": decision.exit_code,
        "note": NOTE,
    }


def _write_json_atomic(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _read_json(path: Path) -> JsonDict | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return None
    return payload if isinstance(payload, dict) else None


def existing_status_matches(path: Path, payload: Mapping[str, object]) -> bool:
    current = _read_json(path)
    if current is None:
        return False
    for key in ("engine", "slug", "state", "model", "started_at", "updated_at", "exit_code"):
        if current.get(key) != payload.get(key):
            return False
    return True


def write_terminal_status(path: Path, payload: Mapping[str, object]) -> str:
    if existing_status_matches(path, payload):
        return "unchanged"
    _write_json_atomic(path, dict(payload))
    return "wrote"


def clear_status(path: Path) -> str:
    if not path.exists():
        return "absent"
    path.unlink()
    return "cleared"


def visible_label_zh(label_zh: str, slug: str) -> str:
    return label_zh.strip() or slug


def visible_dispatcher_zh(dispatcher_zh: str, slug: str) -> str:
    return dispatcher_zh.strip() or f"Multica / {slug}"


def _slug_registered(logs_dir: Path, slug: str) -> bool:
    from cortex_sentinel.paths import registry_path as home_registry

    candidates = (
        logs_dir / "registry.json",
        logs_dir / LINE_REGISTRY_NAME,
        logs_dir.parent / "registry.json",
        home_registry(),
    )
    for path in candidates:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeError):
            continue
        rows = payload if isinstance(payload, list) else []
        if any(isinstance(row, dict) and str(row.get("slug") or "") == slug for row in rows):
            return True
    return False



def _parse_agent_host_map_text(text: str) -> dict[str, str]:
    """只认本文件这种 agents 列表，不引入第三方 yaml 库。"""
    mapping: dict[str, str] = {}
    in_agents = False
    current_id = ""
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        stripped = line.strip()
        if stripped.startswith("agents:"):
            in_agents = True
            continue
        if not in_agents:
            continue
        if stripped.startswith("- id:"):
            current_id = stripped.split(":", 1)[1].strip().strip('"').strip("'")
            continue
        if stripped.startswith("host:") and current_id:
            host = stripped.split(":", 1)[1].strip().strip('"').strip("'")
            if host:
                mapping[current_id] = host
            continue
    return mapping


def load_agent_host_map(path: Path | None = None) -> dict[str, str]:
    """执行者 id → 机器名。读失败或查不到都返回空映射，绝不猜成本机。"""
    candidates: list[Path] = []
    if path is not None:
        candidates.append(Path(path))
    else:
        candidates.append(sentinel_home() / "agent-host-map.yaml")
        candidates.append(AGENT_HOST_MAP_PATH)
    for target in candidates:
        try:
            text = target.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        mapping = _parse_agent_host_map_text(text)
        if mapping:
            return mapping
    return {}


def host_for_agent_id(agent_id: str, *, mapping: Mapping[str, str] | None = None) -> str | None:
    table = mapping if mapping is not None else load_agent_host_map()
    key = agent_id.strip()
    if not key:
        return None
    host = table.get(key)
    if not isinstance(host, str) or not host.strip():
        return None
    return host.strip()


def host_from_runs(
    runs: Sequence[Mapping[str, Any]],
    *,
    mapping: Mapping[str, str] | None = None,
) -> str | None:
    """赢家 run 的执行者都映射到同一台机器才写 host；任一查不到就不写。"""
    table = mapping if mapping is not None else load_agent_host_map()
    resolved: list[str] = []
    for item in runs:
        agent_id = str(_as_dict(item).get("agent_id") or "").strip()
        host = host_for_agent_id(agent_id, mapping=table)
        if host is None:
            return None
        resolved.append(host)
    unique = set(resolved)
    if len(unique) != 1:
        return None
    return resolved[0]


def register_line(
    *,
    logs_dir: Path,
    slug: str,
    label_zh: str,
    dispatcher_zh: str,
    now: datetime | None = None,
    host: str | None = None,
) -> str:
    upsert_line_registration(
        logs_dir / LINE_REGISTRY_NAME,
        slug=slug,
        label_zh=visible_label_zh(label_zh, slug),
        dispatcher_zh=visible_dispatcher_zh(dispatcher_zh, slug),
        engine=ENGINE,
        now=now,
        host=host,
    )
    return "registered"


def dispatcher_from_issue(issue: Mapping[str, Any], runs: Sequence[Mapping[str, Any]]) -> str:
    for item in reversed(list(runs)):
        attribution = _as_dict(item.get("attribution"))
        initiator = _as_dict(attribution.get("initiator"))
        name = str(initiator.get("name") or "").strip()
        if name:
            return f"Multica / {name}"
    return "Multica"


def apply_decision(
    *,
    logs_dir: Path,
    issue: str,
    slug: str,
    label_zh: str,
    dispatcher_zh: str,
    decision: TerminalDecision | None,
    now: datetime | None = None,
) -> SyncResult:
    path = status_path(logs_dir, slug)
    if decision is None:
        action = clear_status(path)
        return SyncResult(
            issue=issue,
            slug=slug,
            action=action,
            state=None,
            path=None,
            reason="active-or-empty",
        )
    payload = status_payload(slug=slug, decision=decision)
    action = write_terminal_status(path, payload)
    should_register = action == "wrote" or (action == "unchanged" and not _slug_registered(logs_dir, slug))
    if should_register:
        try:
            register_line(
                logs_dir=logs_dir,
                slug=slug,
                label_zh=label_zh,
                dispatcher_zh=dispatcher_zh,
                now=now,
                host=host_from_runs(decision.winners),
            )
        except LineRegistryError as exc:
            return SyncResult(
                issue=issue,
                slug=slug,
                action=action,
                state=decision.state,
                path=str(path),
                reason=f"status-written-registry-failed:{exc}",
            )
    return SyncResult(
        issue=issue,
        slug=slug,
        action=action,
        state=decision.state,
        path=str(path),
        reason="terminal",
    )


def multica_bin() -> str | None:
    found = shutil.which("multica")
    if found:
        return found
    fallback = Path.home() / ".local" / "bin" / "multica"
    return str(fallback) if fallback.exists() else None


def remaining_call_timeout(
    timeout: float,
    *,
    deadline: float | None,
    clock: Clock,
) -> float:
    if deadline is None:
        return timeout
    left = deadline - clock()
    if left <= HOOK_MIN_CALL_SECONDS:
        raise HookBudgetExceeded("hook wall-clock budget exhausted")
    return min(float(timeout), left)


def run_multica_json(
    args: Sequence[str],
    *,
    runner: CommandRunner | None = None,
    timeout: float = CLI_COMMAND_TIMEOUT,
    deadline: float | None = None,
    clock: Clock | None = None,
    stdin: str | None = None,
) -> Any:
    execute = runner or subprocess.run
    binary = "multica" if runner is not None else multica_bin()
    if binary is None:
        raise MulticaNotifyError("multica binary not found")
    command = [binary, *args]
    bounded = remaining_call_timeout(timeout, deadline=deadline, clock=clock or time.time)
    kwargs: dict[str, Any] = {
        "capture_output": True,
        "text": True,
        "timeout": bounded,
        "check": False,
    }
    if stdin is not None:
        kwargs["input"] = stdin
    try:
        completed = execute(command, **kwargs)
    except HookBudgetExceeded:
        raise
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise MulticaNotifyError(f"multica {' '.join(args)} failed: {exc}") from exc
    stdout = getattr(completed, "stdout", "") or ""
    if getattr(completed, "returncode", 1) != 0:
        stderr = (getattr(completed, "stderr", "") or "").strip()
        raise MulticaNotifyError(f"multica {' '.join(args)} rc={completed.returncode}: {stderr}")
    if not stdout.strip():
        return None
    try:
        return json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise MulticaNotifyError(f"multica {' '.join(args)} returned invalid JSON") from exc


def load_issue(
    issue_key: str,
    *,
    runner: CommandRunner | None = None,
    timeout: float = CLI_COMMAND_TIMEOUT,
    deadline: float | None = None,
    clock: Clock | None = None,
) -> JsonDict:
    payload = run_multica_json(
        ["issue", "get", issue_key, "--output", "json"],
        runner=runner,
        timeout=timeout,
        deadline=deadline,
        clock=clock,
    )
    issue = _as_dict(payload)
    if not issue.get("id") and not issue.get("identifier"):
        raise MulticaNotifyError(f"issue not found: {issue_key}")
    return issue


def load_runs(
    issue_key: str,
    *,
    runner: CommandRunner | None = None,
    timeout: float = CLI_COMMAND_TIMEOUT,
    deadline: float | None = None,
    clock: Clock | None = None,
) -> list[JsonDict]:
    payload = run_multica_json(
        ["issue", "runs", issue_key, "--output", "json"],
        runner=runner,
        timeout=timeout,
        deadline=deadline,
        clock=clock,
    )
    return [_as_dict(item) for item in _as_list(payload)]


def sync_issue(
    issue_key: str,
    *,
    logs_dir: Path | None = None,
    runner: CommandRunner | None = None,
    timeout: float = CLI_COMMAND_TIMEOUT,
    now: datetime | None = None,
    deadline: float | None = None,
    clock: Clock | None = None,
    preloaded_issue: Mapping[str, Any] | None = None,
) -> SyncResult:
    logs = resolve_logs_dir(logs_dir)
    if preloaded_issue and (preloaded_issue.get("identifier") or preloaded_issue.get("id")):
        issue = _as_dict(preloaded_issue)
    else:
        issue = load_issue(issue_key, runner=runner, timeout=timeout, deadline=deadline, clock=clock)
    identifier = str(issue.get("identifier") or "").strip()
    slug = slug_from_identifier(identifier or issue_key)
    runs = load_runs(
        str(issue.get("id") or issue_key),
        runner=runner,
        timeout=timeout,
        deadline=deadline,
        clock=clock,
    )
    decision = decide_issue_terminal(runs)
    return apply_decision(
        logs_dir=logs,
        issue=identifier or issue_key,
        slug=slug,
        label_zh=str(issue.get("title") or "").strip() or slug,
        dispatcher_zh=dispatcher_from_issue(issue, runs),
        decision=decision,
        now=now,
    )


def canonical_issue_key(value: object) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    if text[:4].upper() == "COR-":
        rest = text.split("-", 1)[1] if "-" in text else text[4:]
        return f"COR-{rest}"
    return text


def unique_issue_keys(values: Sequence[object]) -> list[str]:
    found: list[str] = []
    seen: set[str] = set()
    for item in values:
        key = canonical_issue_key(item)
        if not key or key in seen:
            continue
        seen.add(key)
        found.append(key)
    return found


def partial_sync_message(scanned: int, total: int) -> str:
    return f"本轮只刷了 {scanned}/{total}，下轮接着刷"


def emit_partial_sync(results: Sequence[SyncResult], *, total: int) -> None:
    if not any(item.action == "deferred" for item in results):
        return
    scanned = sum(1 for item in results if item.action != "deferred")
    print(partial_sync_message(scanned, total), file=sys.stderr, flush=True)


def _list_page(payload: object) -> tuple[list[JsonDict], bool]:
    if isinstance(payload, list):
        return [_as_dict(item) for item in payload], False
    data = _as_dict(payload)
    return [_as_dict(item) for item in _as_list(data.get("issues"))], bool(data.get("has_more"))


def issue_payload_map(issues: Sequence[Mapping[str, Any]]) -> dict[str, JsonDict]:
    payloads: dict[str, JsonDict] = {}
    for item in issues:
        row = _as_dict(item)
        identifier = canonical_issue_key(row.get("identifier") or row.get("id"))
        if identifier:
            payloads[identifier] = row
        raw_id = str(row.get("id") or "").strip()
        if raw_id:
            payloads[raw_id] = row
    return payloads


def list_in_progress_issues(
    *,
    runner: CommandRunner | None = None,
    timeout: float = CLI_COMMAND_TIMEOUT,
    deadline: float | None = None,
    clock: Clock | None = None,
    limit: int = LIST_PAGE_SIZE,
) -> list[JsonDict]:
    offset = 0
    found: list[JsonDict] = []
    while True:
        payload = run_multica_json(
            [
                "issue",
                "list",
                "--status",
                DISCOVER_STATUS,
                "--output",
                "json",
                "--limit",
                str(limit),
                "--offset",
                str(offset),
            ],
            runner=runner,
            timeout=timeout,
            deadline=deadline,
            clock=clock,
        )
        page, has_more = _list_page(payload)
        found.extend(page)
        if not has_more or not page:
            return found
        offset += len(page)


def _ledger_issue_refs(path: Path) -> list[str]:
    if not path.exists():
        return []
    refs: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict):
            continue
        ref = str(entry.get("ref") or "").strip()
        if ref.upper().startswith("COR-"):
            refs.append(ref)
    return refs


def _retired_map(payload: Mapping[str, Any]) -> dict[str, str]:
    raw = payload.get("retired")
    if isinstance(raw, Mapping):
        return {
            canonical_issue_key(key): str(value or "")
            for key, value in raw.items()
            if canonical_issue_key(key)
        }
    retired: dict[str, str] = {}
    for item in _as_list(payload.get("retired_issue_ids")):
        key = canonical_issue_key(item)
        if key:
            retired[key] = ""
    return retired


def load_watch_state(logs_dir: Path) -> WatchState:
    payload = _read_json(logs_dir / WATCH_FILENAME) or {}
    return WatchState(
        issue_ids=unique_issue_keys(_as_list(payload.get("issue_ids"))),
        auto_issue_ids=unique_issue_keys(_as_list(payload.get("auto_issue_ids"))),
        retired=_retired_map(payload),
        pending_issue_ids=unique_issue_keys(_as_list(payload.get("pending_issue_ids"))),
    )


def save_watch_state(logs_dir: Path, state: WatchState) -> None:
    payload = _read_json(logs_dir / WATCH_FILENAME) or {}
    if not isinstance(payload, dict):
        payload = {}
    payload["issue_ids"] = unique_issue_keys(state.issue_ids)
    payload["auto_issue_ids"] = unique_issue_keys(state.auto_issue_ids)
    payload["retired"] = {
        canonical_issue_key(key): str(value or "")
        for key, value in state.retired.items()
        if canonical_issue_key(key)
    }
    payload["pending_issue_ids"] = unique_issue_keys(state.pending_issue_ids)
    payload.pop("retired_issue_ids", None)
    _write_json_atomic(logs_dir / WATCH_FILENAME, payload)


def load_watch(logs_dir: Path) -> list[str]:
    return list(load_watch_state(logs_dir).issue_ids)


def save_watch(logs_dir: Path, issue_ids: Sequence[str]) -> None:
    state = load_watch_state(logs_dir)
    state.issue_ids = unique_issue_keys(issue_ids)
    save_watch_state(logs_dir, state)


def add_watch_issue(logs_dir: Path, issue_id: str) -> list[str]:
    key = canonical_issue_key(issue_id)
    if not key:
        raise MulticaNotifyError("empty issue identifier")
    state = load_watch_state(logs_dir)
    if key not in set(unique_issue_keys(state.issue_ids)):
        state.issue_ids.append(key)
    state.retired = {
        retired_key: retired_at
        for retired_key, retired_at in state.retired.items()
        if canonical_issue_key(retired_key) != key
    }
    save_watch_state(logs_dir, state)
    return list(state.issue_ids)


def pending_first(keys: Sequence[str], pending: Sequence[str]) -> list[str]:
    merged = unique_issue_keys(keys)
    allowed = set(merged)
    return unique_issue_keys([item for item in unique_issue_keys(pending) if item in allowed] + merged)


def _activity_unretired(state: WatchState, listed: Sequence[Mapping[str, Any]]) -> set[str]:
    skip = {canonical_issue_key(key) for key in state.retired}
    for item in listed:
        key = canonical_issue_key(item.get("identifier") or item.get("id"))
        if key not in skip:
            continue
        retired_at = state.retired.get(key) or ""
        activity = str(item.get("last_activity_at") or item.get("updated_at") or "")
        if retired_at and activity and _time_key(activity) > _time_key(retired_at):
            skip.discard(key)
    return skip


def discover_issue_ids(
    *,
    runner: CommandRunner | None = None,
    timeout: float = CLI_COMMAND_TIMEOUT,
    extra: Sequence[str] = (),
    logs_dir: Path | None = None,
    include_ledger: bool = False,
    include_watch: bool = True,
    include_in_progress: bool = True,
    exclude_retired: bool = True,
    listed_issues: Sequence[Mapping[str, Any]] | None = None,
    deadline: float | None = None,
    clock: Clock | None = None,
) -> list[str]:
    logs = resolve_logs_dir(logs_dir)
    state = load_watch_state(logs)
    if listed_issues is not None:
        listed = [_as_dict(item) for item in listed_issues]
    elif include_in_progress:
        listed = list_in_progress_issues(
            runner=runner,
            timeout=timeout,
            deadline=deadline,
            clock=clock,
        )
    else:
        listed = []
    discovered = [
        canonical_issue_key(item.get("identifier") or item.get("id"))
        for item in listed
    ]
    watch_keys = list(state.issue_ids) if include_watch else []
    ledger_keys = _ledger_issue_refs(logs / LEDGER_NAME) if include_ledger else []
    merged = unique_issue_keys(
        [*extra, *discovered, *watch_keys, *state.auto_issue_ids, *ledger_keys]
    )
    if not exclude_retired:
        return merged
    skip = _activity_unretired(state, listed)
    return [key for key in merged if key not in skip]


def _result_issue_key(result: SyncResult) -> str:
    return canonical_issue_key(result.issue) or canonical_issue_key(result.slug)


def finalize_sync(
    logs_dir: Path,
    queued: Sequence[str],
    results: Sequence[SyncResult],
    *,
    discovered: Sequence[str] = (),
    now: datetime | None = None,
) -> WatchState:
    state = load_watch_state(logs_dir)
    explicit = set(unique_issue_keys(state.issue_ids))
    retired_at = east_eight_timestamp(now)
    done: list[str] = []
    auto = unique_issue_keys([*state.auto_issue_ids, *discovered])
    for result in results:
        if result.action == "deferred":
            break
        if result.action == "error":
            continue
        key = _result_issue_key(result)
        if key:
            done.append(key)
        if (
            key
            and result.state
            and result.action in RETIRE_ACTIONS
            and result.path
        ):
            state.retired[key] = retired_at
            auto = [item for item in auto if item != key]
        elif key and result.reason == "active-or-empty":
            state.retired.pop(key, None)
            if key not in explicit:
                auto.append(key)
    done_set = set(unique_issue_keys(done))
    state.auto_issue_ids = unique_issue_keys(
        item for item in auto if item not in state.retired
    )
    state.pending_issue_ids = [
        key for key in unique_issue_keys(queued) if key not in done_set
    ]
    save_watch_state(logs_dir, state)
    return state


def sync_issues(
    issue_keys: Sequence[str],
    *,
    logs_dir: Path | None = None,
    runner: CommandRunner | None = None,
    timeout: float = CLI_COMMAND_TIMEOUT,
    now: datetime | None = None,
    deadline: float | None = None,
    clock: Clock | None = None,
    issue_payloads: Mapping[str, Mapping[str, Any]] | None = None,
    discovered: Sequence[str] = (),
    persist: bool = True,
) -> list[SyncResult]:
    logs = resolve_logs_dir(logs_dir)
    queued = unique_issue_keys(issue_keys)
    payloads = issue_payloads or {}
    results: list[SyncResult] = []
    for key in queued:
        preloaded = payloads.get(key) or payloads.get(canonical_issue_key(key))
        try:
            result = sync_issue(
                key,
                logs_dir=logs,
                runner=runner,
                timeout=timeout,
                now=now,
                deadline=deadline,
                clock=clock,
                preloaded_issue=preloaded,
            )
        except HookBudgetExceeded:
            results.append(
                SyncResult(
                    issue=key,
                    slug=key,
                    action="deferred",
                    state=None,
                    path=None,
                    reason="hook-wall-clock",
                )
            )
            break
        except (MulticaNotifyError, LineRegistryError) as exc:
            results.append(
                SyncResult(
                    issue=key,
                    slug=key,
                    action="error",
                    state=None,
                    path=None,
                    reason=str(exc),
                )
            )
            continue
        results.append(result)
    if persist:
        finalize_sync(logs, queued, results, discovered=discovered, now=now)
    emit_partial_sync(results, total=len(queued))
    return results


def refresh_once(
    *,
    logs_dir: Path | None = None,
    runner: CommandRunner | None = None,
    extra: Sequence[str] = (),
    timeout: float = CLI_COMMAND_TIMEOUT,
    now: datetime | None = None,
    deadline: float | None = None,
    budget_seconds: float | None = SYNC_WALL_CLOCK_SECONDS,
    clock: Clock | None = None,
) -> list[SyncResult]:
    logs = resolve_logs_dir(logs_dir)
    ticker = clock or time.time
    bound = deadline
    if bound is None and budget_seconds is not None:
        bound = ticker() + float(budget_seconds)
    listed: list[JsonDict] = []
    try:
        listed = list_in_progress_issues(
            runner=runner,
            timeout=timeout,
            deadline=bound,
            clock=ticker,
        )
    except HookBudgetExceeded:
        listed = []
    discovered = unique_issue_keys(
        item.get("identifier") or item.get("id") for item in listed
    )
    keys = discover_issue_ids(
        runner=runner,
        timeout=timeout,
        extra=extra,
        logs_dir=logs,
        listed_issues=listed,
        include_in_progress=False,
        deadline=bound,
        clock=ticker,
    )
    state = load_watch_state(logs)
    ordered = pending_first(keys, state.pending_issue_ids)
    state.auto_issue_ids = unique_issue_keys(
        item
        for item in [*state.auto_issue_ids, *discovered]
        if item not in _activity_unretired(state, listed)
    )
    save_watch_state(logs, state)
    return sync_issues(
        ordered,
        logs_dir=logs,
        runner=runner,
        timeout=timeout,
        now=now,
        deadline=bound,
        clock=ticker,
        issue_payloads=issue_payload_map(listed),
        discovered=discovered,
    )


def _stamp_path(logs_dir: Path) -> Path:
    return logs_dir / STAMP_FILENAME


def _stamp_fresh(logs_dir: Path, *, now: float, window: float) -> bool:
    payload = _read_json(_stamp_path(logs_dir))
    if payload is None:
        return False
    stamped = payload.get("epoch")
    if not isinstance(stamped, (int, float)) or isinstance(stamped, bool):
        return False
    age = now - float(stamped)
    return 0 <= age < window


def _write_hook_stamp(logs_dir: Path, *, now: float) -> None:
    """尝试一开始就记账。成败都算一次，避免 Multica 慢时每回合再打一次。"""
    _write_json_atomic(
        _stamp_path(logs_dir),
        {
            "updated_at": east_eight_timestamp(datetime.now(timezone.utc)),
            "epoch": now,
        },
    )


def refresh_for_hooks(
    *,
    logs_dir: Path | None = None,
    runner: CommandRunner | None = None,
    now: float | None = None,
    throttle_seconds: float = HOOK_THROTTLE_SECONDS,
    wall_clock_seconds: float = HOOK_WALL_CLOCK_SECONDS,
    clock: Clock | None = None,
) -> list[SyncResult]:
    """给每回合注入用。失败静默；默认 45 秒最多尝试一次，成败都记账。

    整轮还有几秒墙钟预算。超了就收手，剩下的留给下一次刷新。
    """
    if not hook_refresh_enabled():
        return []
    logs = resolve_logs_dir(logs_dir)
    stamp_now = time.time() if now is None else now
    ticker = clock or time.time
    if _stamp_fresh(logs, now=stamp_now, window=throttle_seconds):
        return []
    try:
        _write_hook_stamp(logs, now=stamp_now)
    except Exception:
        return []
    try:
        return refresh_once(
            logs_dir=logs,
            runner=runner,
            timeout=HOOK_COMMAND_TIMEOUT,
            deadline=ticker() + wall_clock_seconds,
            clock=ticker,
        )
    except Exception:
        return []


def _format_result(result: SyncResult) -> str:
    state = result.state or "-"
    return f"{result.slug} {result.action} state={state} {result.reason}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Translate Multica run terminals into sentry status.json files")
    parser.add_argument("--issue", action="append", default=[], help="只刷这些票（可重复）")
    parser.add_argument("--logs-dir", type=Path, default=None, help="默认仓内 logs/，也可被 CORTEX_LOGS_DIR 覆盖")
    parser.add_argument(
        "--budget-seconds",
        type=float,
        default=SYNC_WALL_CLOCK_SECONDS,
        help=f"整次同步墙钟预算，默认 {int(SYNC_WALL_CLOCK_SECONDS)} 秒，超了打印剩余票数",
    )
    parser.add_argument("--json", action="store_true", help="打印 SyncResult JSON")
    args = parser.parse_args(argv)
    logs = resolve_logs_dir(args.logs_dir)
    if args.issue:
        results = sync_issues(
            args.issue,
            logs_dir=logs,
            deadline=time.time() + float(args.budget_seconds),
        )
    else:
        results = refresh_once(logs_dir=logs, budget_seconds=args.budget_seconds)
    if args.json:
        print(
            json.dumps(
                [
                    {
                        "issue": item.issue,
                        "slug": item.slug,
                        "action": item.action,
                        "state": item.state,
                        "path": item.path,
                        "reason": item.reason,
                    }
                    for item in results
                ],
                ensure_ascii=False,
                indent=2,
            )
        )
    else:
        if not results:
            print("没有可刷的 Multica 票")
        for item in results:
            print(_format_result(item))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
