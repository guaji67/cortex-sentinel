#!/usr/bin/env python3
"""跨会话轮询哨兵：先能看见，再让新起的自己会退。

窗口里那些 `while true; sleep; 读 logs/*.status.json` 循环不进 launchd、
不进 crontab、不进登记表。盯的线收工了它还挂着，跟还在干活的哨兵在 ps
里长得一样。本工具只做两件事，不杀任何进程：

1. list   列出当前存活的这类哨兵，按它盯的对象（不是 ppid）分成有主 / 无主
2. watch  新哨兵入口：对象进终态、文件消失、或超过兜底小时数，自己退

阳性对照：报「找到 N 个」或「一个都没有」之前，必须证明 ps 真能列出进程。
空表和「命令产不出结果」长得一样，所以空 ps 直接报错，不许打印 0。

排除自己：统计命令的源码里带着 while true / status.json 时，不能把自己
算进去。cursor-agent / codex 的 argv 里整篇工单也常有这两个词，那是干活
的线，不是哨兵。

用法：
    python3 scripts/health/line_watch.py list
    python3 scripts/health/line_watch.py list --json
    python3 scripts/health/line_watch.py watch --status-file /tmp/x.status.json --sleep 0.05
    python3 scripts/health/line_watch.py watch --watch-active --sleep 60 --max-hours 12
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path

from cortex_sentinel.paths import status_dir


TERMINAL_STATES = frozenset({"done", "help", "dead", "killed"})
# 12 小时：单线工单要 1 小时内能交，一张网却可能连盯当天陆续派出的几条线，
# 1 小时会误伤还在值班的网。实测残留活过两天；12 小时收掉隔夜忘关的，
# 又不误伤当天还在派线的窗口。与 air_babysitter_monitor.py 默认值对齐。
DEFAULT_MAX_HOURS = 12.0
DEFAULT_SLEEP_SECONDS = 60.0
CHANNEL_STATUS_NAME = "channel-status.json"
PS_COLUMNS = ["pid=", "ppid=", "lstart=", "command="]
PS_LINE_RE = re.compile(
    r"^\s*(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d+:\d+:\d+\s+\d+)\s+(.*)$"
)
SHELL_NAMES = frozenset({"zsh", "bash", "sh"})
_LINE_STATUS_DIR = "(?:logs|status)"
SLUGS_ASSIGN_RE = re.compile(r"""\bSLUGS=(['"])([^'"]+)\1""")
STATUS_LITERAL_RE = re.compile(
    r"(?P<path>(?:/(?:[^\s;'\"\\]+/)+)?"
    + _LINE_STATUS_DIR
    + r"/(?:grok-|codex-babysitter-|codex-)"
    r"(?P<slug>[A-Za-z0-9_-]+)\.status\.json)"
)
STATUS_VAR_RE = re.compile(
    _LINE_STATUS_DIR + r"/(?P<prefix>grok-|codex-babysitter-|codex-)\$\{?s\}?\.status\.json"
)
STATUS_FILE_ARG_RE = re.compile(r"--status-file(?:\s+|=)(\S+)")
CD_RE = re.compile(r"\bcd\s+(/[^\s;&|\\]+)")
SUPERVISOR_RE = re.compile(r"(?:^|\s)(?:\S+/)?(?:grok_dispatch|codex_babysitter)\.py\b")
SCANNER_PS_RE = re.compile(r"\bps\s+-")
SCANNER_GREP_RE = re.compile(r"\b(?:pgrep|grep|egrep|fgrep|rg)\b")


class LineWatchListingError(RuntimeError):
    """ps 没产出可用结果。这时不许把「0 个哨兵」当成答案。"""


@dataclass(frozen=True)
class ProcessRow:
    pid: int
    ppid: int
    started_at: str
    command: str
    cwd: str | None = None


@dataclass(frozen=True)
class WatchTarget:
    path: str
    slug: str
    state: str
    source: str


@dataclass
class SentinelRecord:
    pid: int
    ppid: int
    started_at: str
    command: str
    verdict: str
    criterion: str
    watched: list[WatchTarget] = field(default_factory=list)

    def as_dict(self) -> dict[str, object]:
        payload = asdict(self)
        payload["watched"] = [asdict(item) for item in self.watched]
        return payload


@dataclass(frozen=True)
class ListResult:
    positive_control: str
    sentinels: tuple[SentinelRecord, ...]

    @property
    def owned(self) -> tuple[SentinelRecord, ...]:
        return tuple(item for item in self.sentinels if item.verdict == "owned")

    @property
    def orphan(self) -> tuple[SentinelRecord, ...]:
        return tuple(item for item in self.sentinels if item.verdict == "orphan")


def repo_root_from_git(cwd: Path | None = None) -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        cwd=str(cwd or Path.cwd()),
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise LineWatchListingError("git rev-parse --show-toplevel 失败，无法定仓根")
    return Path(result.stdout.strip())


def default_logs_dir(cwd: Path | None = None) -> Path:
    override = os.environ.get("CORTEX_LOGS_DIR", "").strip()
    if override:
        return Path(override)
    return status_dir()


def normalize_command(command: str) -> str:
    return command.replace("\\012", "\n")


def command_head(command: str) -> str:
    parts = command.split()
    return parts[0] if parts else ""


def is_shell_command(command: str) -> bool:
    return Path(command_head(command)).name in SHELL_NAMES


def is_process_scanner(command: str) -> bool:
    if "line_watch.py list" in command:
        return True
    if SCANNER_PS_RE.search(command):
        return True
    if SCANNER_GREP_RE.search(command) and "while true" in command:
        return True
    return False


def is_work_supervisor(command: str) -> bool:
    return SUPERVISOR_RE.search(command) is not None and not is_shell_command(command)


def is_python_watch_runner(command: str) -> bool:
    if "line_watch.py" not in command:
        return False
    if "line_watch.py list" in command:
        return False
    return bool(re.search(r"\bwatch\b", command))


def has_poll_loop(command: str) -> bool:
    return bool(re.search(r"\bwhile\s+(?:true|:)\b", command) or re.search(r"\buntil\s+", command))


def watches_line_status(command: str) -> bool:
    return bool(
        ".status.json" in command
        or "channel_status.py" in command
        or "list-unclaimed" in command
        or "line_watch.py" in command
        or (_LINE_STATUS_DIR + "/grok-") in command
        or "codex-babysitter-" in command
    )


def is_line_watch_sentinel(command: str) -> bool:
    """判的是「它在干什么」，不是命令行里有没有 while true 这四个字。

    Claude 窗口起的循环常把换行写成字面量 ``\\012``，于是源码变成
    ``...r9\\012while true``。末尾那个 2 是单词字符，``\\bwhile`` 会匹配失败。
    先把 ``\\012`` 还原成换行再判。
    """
    command = normalize_command(command)
    if is_process_scanner(command) or is_work_supervisor(command):
        return False
    if is_python_watch_runner(command):
        return True
    return is_shell_command(command) and has_poll_loop(command) and watches_line_status(command)


def command_cd(command: str) -> Path | None:
    match = CD_RE.search(normalize_command(command))
    if match is None:
        return None
    return Path(match.group(1))


def extract_watch_paths(command: str, *, logs_dir: Path) -> list[tuple[str, str, str]]:
    """返回 (slug, path, source)。source 标明这条是怎么解析出来的。"""
    text = normalize_command(command)
    found: list[tuple[str, str, str]] = []
    seen: set[str] = set()

    def add(slug: str, path: str, source: str) -> None:
        if path in seen:
            return
        seen.add(path)
        found.append((slug, path, source))

    slugs_match = SLUGS_ASSIGN_RE.search(text)
    var_match = STATUS_VAR_RE.search(text)
    if slugs_match and var_match:
        prefix = var_match.group("prefix")
        for slug in slugs_match.group(2).split():
            add(slug, str(logs_dir / f"{prefix}{slug}.status.json"), "slugs_loop")

    for match in STATUS_FILE_ARG_RE.finditer(text):
        raw = match.group(1).strip("'\"")
        path = Path(raw)
        if not path.is_absolute():
            path = logs_dir / path.name
        add(path.stem.replace("grok-", "").replace("codex-babysitter-", ""), str(path), "status_file_arg")

    # SLUGS 循环才是它在盯的网；字面量里常夹着一次性阳性对照文件，不能算进盯的对象。
    if not any(source == "slugs_loop" for _slug, _path, source in found):
        for match in STATUS_LITERAL_RE.finditer(text):
            raw = match.group("path")
            slug = match.group("slug")
            path = Path(raw)
            if not path.is_absolute():
                path = logs_dir / path.name
            add(slug, str(path), "literal_status")

    if not found and ("--watch-active" in text or "list-unclaimed" in text or "channel_status.py" in text):
        add("*", str(logs_dir), "active_net")

    return found


def iter_line_status_files(logs_dir: Path) -> list[Path]:
    if not logs_dir.is_dir():
        return []
    files: list[Path] = []
    for path in sorted(logs_dir.glob("*.status.json")):
        if path.name == CHANNEL_STATUS_NAME:
            continue
        if path.name.startswith("grok-") or path.name.startswith("codex-"):
            files.append(path)
    return files


def read_status_state(path: Path) -> str | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        return None
    state = data.get("state") if isinstance(data, dict) else None
    if isinstance(state, str) and state.strip():
        return state.strip()
    return None


def resolve_targets(
    command: str,
    *,
    logs_dir: Path,
    path_exists: Callable[[Path], bool],
    read_state: Callable[[Path], str | None],
) -> list[WatchTarget]:
    extracted = extract_watch_paths(command, logs_dir=logs_dir)
    targets: list[WatchTarget] = []
    for slug, raw_path, source in extracted:
        if source == "active_net":
            files = iter_line_status_files(Path(raw_path))
            if not files:
                targets.append(WatchTarget(path=raw_path, slug="*", state="missing", source=source))
                continue
            for path in files:
                state = read_state(path)
                targets.append(
                    WatchTarget(
                        path=str(path),
                        slug=_slug_from_status_name(path.name),
                        state=state or "unreadable",
                        source=source,
                    )
                )
            continue
        path = Path(raw_path)
        if not path_exists(path):
            targets.append(WatchTarget(path=str(path), slug=slug, state="missing", source=source))
            continue
        state = read_state(path)
        targets.append(
            WatchTarget(
                path=str(path),
                slug=slug,
                state=state or "unreadable",
                source=source,
            )
        )
    return targets


def _slug_from_status_name(name: str) -> str:
    stem = name[: -len(".status.json")] if name.endswith(".status.json") else name
    for prefix in ("grok-", "codex-babysitter-", "codex-"):
        if stem.startswith(prefix):
            return stem[len(prefix) :]
    return stem


def classify_ownership(targets: Sequence[WatchTarget]) -> tuple[str, str]:
    """有主 / 无主只看盯的对象。ppid 还在不代表那条线还在跑。"""
    if not targets:
        return (
            "owned",
            "没有解析到盯的对象，fail-closed 判有主（避免把还在干活的哨兵判死）",
        )

    unread = [item for item in targets if item.state == "unreadable"]
    if unread:
        names = ", ".join(item.slug for item in unread)
        return "owned", f"状态文件读不出，fail-closed 判有主：{names}"

    active = [item for item in targets if item.state not in TERMINAL_STATES and item.state != "missing"]
    if active:
        detail = ", ".join(f"{item.slug}={item.state}" for item in active)
        return "owned", f"盯的对象仍有非终态：{detail}"

    missing = [item for item in targets if item.state == "missing"]
    terminal = [item for item in targets if item.state in TERMINAL_STATES]
    bits: list[str] = []
    if terminal:
        bits.append(
            "已进终态 "
            + ", ".join(f"{item.slug}={item.state}" for item in terminal)
        )
    if missing:
        bits.append("文件不在了 " + ", ".join(item.slug for item in missing))
    return "orphan", "；".join(bits) if bits else "盯的对象都已终态或消失"


def parse_ps_output(text: str) -> list[ProcessRow]:
    rows: list[ProcessRow] = []
    for line in text.splitlines():
        match = PS_LINE_RE.match(line)
        if match is None:
            continue
        rows.append(
            ProcessRow(
                pid=int(match.group(1)),
                ppid=int(match.group(2)),
                started_at=match.group(3),
                command=match.group(4),
            )
        )
    return rows


def read_process_table(
    runner: Callable[..., subprocess.CompletedProcess[str]] | None = None,
) -> list[ProcessRow]:
    run = runner or subprocess.run
    result = run(
        ["ps", "-axww", "-o", ",".join(PS_COLUMNS)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise LineWatchListingError(f"ps 退出码 {result.returncode}")
    return parse_ps_output(result.stdout)


def ensure_process_listing_ok(
    rows: Sequence[ProcessRow],
    *,
    self_pid: int,
    canary_pid: int = 1,
) -> str:
    if not rows:
        raise LineWatchListingError("ps 返回 0 行；命令没产出结果，不能写成「一个哨兵都没有」")
    pids = {row.pid for row in rows}
    if self_pid not in pids and canary_pid not in pids:
        raise LineWatchListingError(
            f"ps 既没有当前进程 pid={self_pid} 也没有阳性对照 pid={canary_pid}；命令没产出结果"
        )
    if canary_pid in pids:
        canary = next(row for row in rows if row.pid == canary_pid)
        return (
            f"ps listed {len(rows)} rows; "
            f"pid={canary_pid} {command_head(canary.command)} present"
        )
    return f"ps listed {len(rows)} rows; self pid={self_pid} present"


def list_sentinels(
    rows: Sequence[ProcessRow],
    *,
    self_pids: set[int],
    logs_dir: Path,
    path_exists: Callable[[Path], bool] | None = None,
    read_state: Callable[[Path], str | None] | None = None,
    cwd_of: Callable[[int], Path | None] | None = None,
    self_pid: int | None = None,
    canary_pid: int = 1,
) -> ListResult:
    control = ensure_process_listing_ok(
        rows,
        self_pid=self_pid if self_pid is not None else next(iter(self_pids)),
        canary_pid=canary_pid,
    )
    exists = path_exists or (lambda path: path.exists())
    reader = read_state or read_status_state
    records: list[SentinelRecord] = []
    for row in rows:
        if row.pid in self_pids:
            continue
        if not is_line_watch_sentinel(row.command):
            continue
        base = command_cd(row.command)
        if base is None and cwd_of is not None:
            base = cwd_of(row.pid)
        row_logs = (base / "logs") if base is not None else logs_dir
        targets = resolve_targets(
            row.command,
            logs_dir=row_logs,
            path_exists=exists,
            read_state=reader,
        )
        verdict, criterion = classify_ownership(targets)
        records.append(
            SentinelRecord(
                pid=row.pid,
                ppid=row.ppid,
                started_at=row.started_at,
                command=row.command,
                verdict=verdict,
                criterion=criterion,
                watched=targets,
            )
        )
    records.sort(key=lambda item: (item.started_at, item.pid))
    return ListResult(positive_control=control, sentinels=tuple(records))


def format_list_result(result: ListResult) -> str:
    lines = [
        result.positive_control,
        (
            f"sentinels: {len(result.sentinels)}  "
            f"owned: {len(result.owned)}  orphan: {len(result.orphan)}"
        ),
    ]
    for item in result.sentinels:
        watch = "; ".join(f"{w.slug}={w.state} ({w.path})" for w in item.watched) or "(none)"
        lines.extend(
            [
                "---",
                (
                    f"pid={item.pid} ppid={item.ppid} started={item.started_at} "
                    f"verdict={item.verdict}"
                ),
                f"watch: {watch}",
                f"criterion: {item.criterion}",
                f"command: {item.command}",
            ]
        )
    return "\n".join(lines)


def _inspect_status_files(
    paths: Sequence[Path],
    *,
    path_exists: Callable[[Path], bool],
    read_state: Callable[[Path], str | None],
) -> dict[str, str]:
    snapshot: dict[str, str] = {}
    for path in paths:
        key = str(path)
        if not path_exists(path):
            snapshot[key] = "missing"
            continue
        snapshot[key] = read_state(path) or "unreadable"
    return snapshot


def _watch_exit_reason(states: dict[str, str]) -> str | None:
    if not states:
        return "missing"
    if any(state == "unreadable" for state in states.values()):
        return None
    if any(state not in TERMINAL_STATES and state != "missing" for state in states.values()):
        return None
    if all(state == "missing" for state in states.values()):
        return "missing"
    return "terminal"


def watch_until_exit(
    paths: Sequence[Path],
    *,
    sleep_seconds: float = DEFAULT_SLEEP_SECONDS,
    max_hours: float = DEFAULT_MAX_HOURS,
    now: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    path_exists: Callable[[Path], bool] | None = None,
    read_state: Callable[[Path], str | None] | None = None,
    emit: Callable[[str], None] | None = None,
) -> str:
    exists = path_exists or (lambda path: path.exists())
    reader = read_state or read_status_state
    talk = emit or (lambda line: print(line, flush=True))
    started = now()
    max_seconds = max_hours * 3600.0
    previous: dict[str, str] = {}
    while True:
        elapsed = now() - started
        remaining = max_seconds - elapsed
        if remaining <= 0:
            talk("LINE_WATCH exit reason=max_hours")
            return "max_hours"
        snapshot = _inspect_status_files(paths, path_exists=exists, read_state=reader)
        for key, state in snapshot.items():
            if previous.get(key) != state and state in TERMINAL_STATES | {"missing"}:
                talk(f"LINE_WATCH {state} {key}")
        previous = snapshot
        reason = _watch_exit_reason(snapshot)
        if reason is not None:
            talk(f"LINE_WATCH exit reason={reason}")
            return reason
        sleep(min(sleep_seconds, remaining))


def watch_active_until_exit(
    logs_dir: Path,
    *,
    sleep_seconds: float = DEFAULT_SLEEP_SECONDS,
    max_hours: float = DEFAULT_MAX_HOURS,
    now: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    list_files: Callable[[Path], list[Path]] | None = None,
    path_exists: Callable[[Path], bool] | None = None,
    read_state: Callable[[Path], str | None] | None = None,
    emit: Callable[[str], None] | None = None,
) -> str:
    files_of = list_files or iter_line_status_files
    return watch_until_exit(
        files_of(logs_dir),
        sleep_seconds=sleep_seconds,
        max_hours=max_hours,
        now=now,
        sleep=sleep,
        path_exists=path_exists,
        read_state=read_state,
        emit=emit,
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="跨会话轮询哨兵：列出有主/无主，或带着自终止条件去盯")
    sub = parser.add_subparsers(dest="cmd", required=True)

    listed = sub.add_parser("list", help="列出存活的跨会话轮询哨兵（只看，不杀）")
    listed.add_argument("--json", action="store_true", help="机器可读")
    listed.add_argument("--logs-dir", type=Path, help="默认 git 仓根下的 logs/")

    watch = sub.add_parser("watch", help="盯状态文件；终态 / 消失 / 超时后自己退")
    watch.add_argument("--status-file", action="append", type=Path, dest="status_files")
    watch.add_argument("--watch-active", action="store_true", help="盯 logs 里当前所有非终态线")
    watch.add_argument("--logs-dir", type=Path)
    watch.add_argument("--sleep", type=float, default=DEFAULT_SLEEP_SECONDS)
    watch.add_argument("--max-hours", type=float, default=DEFAULT_MAX_HOURS)
    return parser


def _cmd_list(args: argparse.Namespace) -> int:
    logs_dir = args.logs_dir or default_logs_dir()
    rows = read_process_table()
    result = list_sentinels(
        rows,
        self_pids={os.getpid(), os.getppid()},
        logs_dir=logs_dir,
        self_pid=os.getpid(),
    )
    if args.json:
        print(
            json.dumps(
                {
                    "positive_control": result.positive_control,
                    "sentinels": len(result.sentinels),
                    "owned": len(result.owned),
                    "orphan": len(result.orphan),
                    "rows": [item.as_dict() for item in result.sentinels],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0
    print(format_list_result(result))
    return 0


def _cmd_watch(args: argparse.Namespace) -> int:
    if args.sleep <= 0:
        raise SystemExit("--sleep 必须大于 0")
    if args.max_hours <= 0:
        raise SystemExit("--max-hours 必须大于 0")
    if not args.status_files and not args.watch_active:
        raise SystemExit("watch 需要 --status-file 或 --watch-active")
    if args.watch_active:
        logs_dir = args.logs_dir or default_logs_dir()
        reason = watch_active_until_exit(
            logs_dir,
            sleep_seconds=args.sleep,
            max_hours=args.max_hours,
        )
    else:
        reason = watch_until_exit(
            args.status_files,
            sleep_seconds=args.sleep,
            max_hours=args.max_hours,
        )
    if reason == "max_hours":
        return 2
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.cmd == "list":
        return _cmd_list(args)
    if args.cmd == "watch":
        return _cmd_watch(args)
    raise SystemExit(f"unknown command: {args.cmd}")


if __name__ == "__main__":
    raise SystemExit(main())
