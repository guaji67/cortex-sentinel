#!/usr/bin/env python3
"""Cursor Grok 派工器：detached 发射、看板登记、状态刷新和终态通知。"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

from cortex_sentinel.channel import DEFAULT_STDERR_ROOT, apply_dispatch_channel_gate
from cortex_sentinel.disk import apply_dispatch_disk_gate
from cortex_sentinel.paths import logs_dir, registry_path, status_dir
from cortex_sentinel.registry import (
    LineRegistryError,
    east_eight_timestamp,
    local_host_name,
    upsert_line_registration,
)


LINE_REGISTRY_PATH = registry_path()
CURSOR_AGENT = Path.home() / ".local" / "bin" / "cursor-agent"
DEFAULT_MODEL = "cursor-grok-4.6-xhigh-fast"
POLL_SECONDS = 10.0
ENGINE = "cursor-grok"
TERMINAL_STATES = frozenset({"done", "dead", "killed"})
ALLOWED_STATES = frozenset({"running", *TERMINAL_STATES})
STATUS_FIELDS = (
    "engine",
    "slug",
    "state",
    "model",
    "workdir",
    "branch",
    "agent_pid",
    "supervisor_pid",
    "started_at",
    "updated_at",
    "log_path",
    "log_bytes",
    "exit_code",
    "note",
)
FORBIDDEN_STATUS_FIELDS = frozenset(
    {"relay", "relay_probe", "balance", "restarts", "rollout_age_s"}
)
_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class GrokDispatchError(RuntimeError):
    """Grok 发射或状态合同不成立。"""


def _validate_status(payload: dict[str, object]) -> None:
    keys = set(payload)
    missing = set(STATUS_FIELDS) - keys
    unexpected = keys - set(STATUS_FIELDS)
    forbidden = keys & FORBIDDEN_STATUS_FIELDS
    if missing:
        raise GrokDispatchError(f"status missing fields: {', '.join(sorted(missing))}")
    if unexpected:
        raise GrokDispatchError(f"status has unexpected fields: {', '.join(sorted(unexpected))}")
    if forbidden:
        raise GrokDispatchError(f"status has forbidden fields: {', '.join(sorted(forbidden))}")
    if payload["state"] not in ALLOWED_STATES:
        raise GrokDispatchError(f"invalid Grok state: {payload['state']!r}")
    if payload["engine"] != ENGINE:
        raise GrokDispatchError(f"invalid Grok engine: {payload['engine']!r}")
    for field in ("started_at", "updated_at"):
        value = payload[field]
        if not isinstance(value, str) or not value.endswith("+08:00"):
            raise GrokDispatchError(f"{field} must use +08:00")


def _write_status(path: Path, payload: dict[str, object]) -> None:
    _validate_status(payload)
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


def _log_size(path: Path) -> int:
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return 0


def _status_payload(
    *,
    slug: str,
    state: str,
    model: str,
    workdir: Path,
    branch: str,
    agent_pid: int,
    supervisor_pid: int,
    started_at: str,
    log_path: Path,
    exit_code: int | None,
    note: str = "",
    now: Callable[[], str] = east_eight_timestamp,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "engine": ENGINE,
        "slug": slug,
        "state": state,
        "model": model,
        "workdir": str(workdir),
        "branch": branch,
        "agent_pid": agent_pid,
        "supervisor_pid": supervisor_pid,
        "started_at": started_at,
        "updated_at": now(),
        "log_path": str(log_path),
        "log_bytes": _log_size(log_path),
        "exit_code": exit_code,
        "note": note,
    }
    _validate_status(payload)
    return payload


def _terminal_state(exit_code: int) -> str:
    if exit_code == 0:
        return "done"
    if exit_code < 0:
        return "killed"
    return "dead"


def notify_terminal_state(
    slug: str,
    state: str,
    exit_code: int,
    *,
    runner: Callable[..., subprocess.CompletedProcess[Any]] = subprocess.run,
) -> bool:
    title = {
        "done": "Grok 收工",
        "dead": "Grok 死亡",
        "killed": "Grok 已停止",
    }.get(state, state)
    body = slug if state == "done" else f"{slug}: exit_code={exit_code}"
    try:
        result = runner(
            [
                "osascript",
                "-e",
                f'display notification "{body}" with title "{title}" sound name "Glass"',
            ],
            timeout=10,
            capture_output=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def _ensure_detached() -> bool:
    """复用 babysitter 的自保分支；返回是否应当等待 reparent 到 PID 1。"""
    try:
        if os.getsid(0) == os.getpid():
            return True
    except OSError:
        return False
    try:
        if os.isatty(0) or os.isatty(1):
            return False
    except OSError:
        pass
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    try:
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        if devnull > 2:
            os.close(devnull)
    except OSError:
        pass
    return True


def _wait_for_ppid_one(
    *,
    timeout_seconds: float = 5.0,
    getppid: Callable[[], int] = os.getppid,
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
) -> bool:
    deadline = monotonic() + timeout_seconds
    while getppid() != 1:
        if monotonic() >= deadline:
            return False
        sleep(0.05)
    return True


def _current_branch(workdir: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(workdir), "branch", "--show-current"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    branch = result.stdout.strip()
    if result.returncode != 0 or not branch:
        raise GrokDispatchError(f"cannot determine git branch for {workdir}")
    return branch


def _register_line(
    *,
    slug: str,
    label_zh: str | None,
    dispatcher_zh: str | None,
    registry_path: Path = LINE_REGISTRY_PATH,
) -> object | None:
    if not label_zh or not label_zh.strip() or not dispatcher_zh or not dispatcher_zh.strip():
        print(
            "WARNING 未同时传入非空 --label-zh/--dispatcher-zh，跳过 Grok 看板登记",
            file=sys.stderr,
        )
        return None
    return upsert_line_registration(
        registry_path,
        slug=slug,
        label_zh=label_zh,
        dispatcher_zh=dispatcher_zh,
        engine=ENGINE,
        host=local_host_name(),
    )


def _spawn_agent(
    *,
    cursor_agent: Path,
    model: str,
    prompt: str,
    workdir: Path,
    log_path: Path,
    stderr_path: Path | None = None,
    popen: Callable[..., subprocess.Popen[Any]] = subprocess.Popen,
) -> subprocess.Popen[Any]:
    command = [
        str(cursor_agent),
        "-p",
        "--force",
        "--model",
        model,
        "--output-format",
        "text",
        prompt,
    ]
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_handle = log_path.open("ab", buffering=0)
    err_handle = None
    try:
        if stderr_path is not None:
            stderr_path.parent.mkdir(parents=True, exist_ok=True)
            err_handle = stderr_path.open("ab", buffering=0)
            stderr_dest: Any = err_handle
        else:
            stderr_dest = subprocess.STDOUT
        return popen(
            command,
            cwd=workdir,
            stdin=subprocess.DEVNULL,
            stdout=log_handle,
            stderr=stderr_dest,
            start_new_session=True,
        )
    finally:
        log_handle.close()
        if err_handle is not None:
            err_handle.close()


def _terminate_owned_agent(process: subprocess.Popen[Any], signum: int) -> int:
    if process.poll() is None:
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass
    try:
        return process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return process.wait(timeout=5)


def _supervise_agent(
    process: subprocess.Popen[Any],
    *,
    status_path: Path,
    status_meta: dict[str, object],
    requested_signal: Callable[[], int | None] = lambda: None,
    poll_seconds: float = POLL_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
    writer: Callable[[Path, dict[str, object]], None] = _write_status,
    notifier: Callable[[str, str, int], bool] = notify_terminal_state,
) -> str:
    def write(state: str, exit_code: int | None) -> None:
        writer(
            status_path,
            _status_payload(
                **status_meta,
                state=state,
                exit_code=exit_code,
            ),
        )

    write("running", None)
    exit_code = process.poll()
    stopped_by_signal = False
    while exit_code is None:
        signum = requested_signal()
        if signum is not None:
            stopped_by_signal = True
            exit_code = _terminate_owned_agent(process, signum)
            break
        sleep(poll_seconds)
        exit_code = process.poll()
        if exit_code is None:
            write("running", None)

    assert exit_code is not None
    state = "killed" if stopped_by_signal else _terminal_state(exit_code)
    write(state, exit_code)
    notification_sent = notifier(str(status_meta["slug"]), state, exit_code)
    print(
        f"GROK_TERMINAL state={state} exit_code={exit_code} "
        f"notification={'sent' if notification_sent else 'failed'}",
        file=sys.stderr,
        flush=True,
    )
    return state


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Dispatch and supervise one Cursor Grok worktree line")
    parser.add_argument("--slug", required=True, help="线名，也用于日志和状态文件名")
    parser.add_argument("--label-zh", help="看板中文任务名；缺失时 WARNING 并跳过登记")
    parser.add_argument("--dispatcher-zh", help="看板来源对话描述；缺失时 WARNING 并跳过登记")
    parser.add_argument("--cd", required=True, help="Grok 唯一工作目录")
    parser.add_argument("--prompt-file", required=True, help="Grok 工单文件")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"Cursor 模型（默认 {DEFAULT_MODEL}）")
    parser.add_argument("--branch", help="分支名；默认从 --cd 的 Git worktree 读取")
    parser.add_argument("--log", help="输出日志；默认 logs/grok-<slug>.log")
    parser.add_argument(
        "--ignore-channel-status",
        action="store_true",
        help="目标通道不通时仍发射；默认不通则拒绝",
    )
    args = parser.parse_args(argv)
    if _SLUG_RE.fullmatch(args.slug) is None:
        parser.error("--slug 只能包含小写字母、数字和连字符")
    return args


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    workdir = Path(args.cd).expanduser().resolve()
    prompt_path = Path(args.prompt_file).expanduser().resolve()
    log_path = (
        Path(args.log).expanduser().resolve()
        if args.log
        else logs_dir() / f"grok-{args.slug}.log"
    )
    status_path = status_dir() / f"grok-{args.slug}.status.json"
    if not workdir.is_dir():
        raise GrokDispatchError(f"workdir does not exist: {workdir}")
    if not prompt_path.is_file():
        raise GrokDispatchError(f"prompt file does not exist: {prompt_path}")
    if not CURSOR_AGENT.is_file() or not os.access(CURSOR_AGENT, os.X_OK):
        raise GrokDispatchError(f"cursor-agent is not executable: {CURSOR_AGENT}")

    gate = apply_dispatch_channel_gate("grok", ignore=bool(args.ignore_channel_status))
    if not gate.allowed:
        return 1
    disk_gate = apply_dispatch_disk_gate()
    if not disk_gate.allowed:
        return 1

    prompt = prompt_path.read_text(encoding="utf-8")
    branch = args.branch or _current_branch(workdir)
    try:
        _register_line(
            slug=args.slug,
            label_zh=args.label_zh,
            dispatcher_zh=args.dispatcher_zh,
        )
    except (LineRegistryError, OSError) as exc:
        raise GrokDispatchError(f"Grok line registration failed: {exc}") from exc

    # 派工方唯一一定会读到的出口就是这里的 stdout（其余握手信息走 stderr，而派工命令
    # 通常把 stderr 重定向进文件）。2026-08-19 实踩：四条线全部跑完，派工方一条都不知道，
    # 还在对外说「还在跑」——Falcon 从菜单栏哨兵先看到终态，当场判「流程有问题」。
    # 根因是终态通知的收件人是他不是派工方，而派工方以为通知这件事已经有人管了。
    # 所以这段提醒必须走 stdout、必须在 detach 之前打，让它落在派工那一次的工具输出里。
    print(
        "\n".join(
            [
                f"GROK_DISPATCHED slug={args.slug} status={status_path}",
                "提醒：终态的 macOS 通知只弹给 Falcon，不会叫醒派工方。",
                "派工不算做完，直到有一个 persistent Monitor 在盯状态文件的终态变化。",
                "盯线请起：python3 scripts/health/line_watch.py watch --watch-active --sleep 60 --max-hours 12",
                "一张网盯全部，别一条线一个 Monitor，也不要再写 while true。",
                "终态只有 done / help / dead / killed；running 与 waiting_relay 都不是终态。",
                "报线的状态前先读一次状态文件，别拿几分钟前的印象说「还在跑」。",
            ]
        ),
        flush=True,
    )

    should_reparent = _ensure_detached()
    if should_reparent and not _wait_for_ppid_one():
        raise GrokDispatchError(f"supervisor did not detach: ppid={os.getppid()}")
    print(
        f"GROK_SUPERVISOR_READY pid={os.getpid()} ppid={os.getppid()}",
        file=sys.stderr,
        flush=True,
    )

    process = _spawn_agent(
        cursor_agent=CURSOR_AGENT,
        model=args.model,
        prompt=prompt,
        workdir=workdir,
        log_path=log_path,
        stderr_path=DEFAULT_STDERR_ROOT / f"grok-{args.slug}.err",
    )
    print(
        f"GROK_AGENT_STARTED pid={process.pid} supervisor_pid={os.getpid()}",
        file=sys.stderr,
        flush=True,
    )
    requested: dict[str, int | None] = {"signal": None}

    def request_stop(signum: int, _frame: object) -> None:
        requested["signal"] = signum

    handled_signals = (signal.SIGTERM, signal.SIGINT)
    previous_handlers = {signum: signal.getsignal(signum) for signum in handled_signals}
    for signum in handled_signals:
        signal.signal(signum, request_stop)
    try:
        state = _supervise_agent(
            process,
            status_path=status_path,
            status_meta={
                "slug": args.slug,
                "model": args.model,
                "workdir": workdir,
                "branch": branch,
                "agent_pid": process.pid,
                "supervisor_pid": os.getpid(),
                "started_at": east_eight_timestamp(),
                "log_path": log_path,
                "note": gate.line,
            },
            requested_signal=lambda: requested["signal"],
        )
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    return 0 if state == "done" else 1


if __name__ == "__main__":
    raise SystemExit(main())
