#!/usr/bin/env python3
"""Report volume headroom and expose disk pressure as an exit code.

照 scripts/health/memory_pressure_gate.py 的形状：JSON 合同、压力 1/2/4、
退出码 0/1/2。量的是磁盘可用，不是内存。

阈值（GiB，1024^3）：可用 >= 20 正常；< 20 警告；< 10 危急（拦住新的并行派工）。
可用认 `df -kP` 的 Available 列（1024-blocks），不认 Capacity 百分比——同一块
228G 的盘 81% 和 3.5G 可用是两件事，派工该不该停只看还能放下下一份 1–2.5G 副本。

多路径落在不同卷时取最紧的那一卷。默认探 $HOME；派工/回收方会再探工作树根
和 Multica 工作区。Probe 失败退出 3，调用方 fail-open，不许猜一个可用数字。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any


GIB = 1024**3
DEFAULT_WARN_BYTES = 20 * GIB
DEFAULT_BLOCK_BYTES = 10 * GIB
PRESSURE_NAMES = {1: "正常", 2: "警告", 4: "危急"}
PRESSURE_EXIT_CODES = {1: 0, 2: 1, 4: 2}
SKIP_ENV = "CORTEX_SKIP_DISK_GATE"
Runner = Callable[[Sequence[str]], str]


class ProbeError(RuntimeError):
    """A required disk probe did not produce a trustworthy value."""


@dataclass(frozen=True)
class DiskGateDecision:
    allowed: bool
    snapshot: dict[str, Any] | None = None
    line: str = ""
    warning: str = ""
    refusal: str = ""


def run_command(args: Sequence[str]) -> str:
    try:
        result = subprocess.run(
            list(args),
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProbeError(f"命令执行失败: {' '.join(args)}: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise ProbeError(f"命令执行失败: {' '.join(args)}: {detail}")
    return result.stdout


def parse_df_kp(text: str) -> dict[str, Any]:
    """Parse POSIX `df -kP` output. Available is in 1024-byte blocks."""
    lines = [line for line in (text or "").splitlines() if line.strip()]
    if len(lines) < 2:
        raise ProbeError("df 没有给出容量行")
    parts = lines[-1].split()
    if len(parts) < 6:
        raise ProbeError(f"df 行无法解析: {lines[-1]!r}")
    try:
        total_blocks = int(parts[1])
        used_blocks = int(parts[2])
        avail_blocks = int(parts[3])
    except ValueError as exc:
        raise ProbeError(f"df 数字无法解析: {lines[-1]!r}") from exc
    if avail_blocks < 0 or total_blocks <= 0:
        raise ProbeError(f"df 给出无意义容量: {lines[-1]!r}")
    mount = " ".join(parts[5:])
    if not mount:
        raise ProbeError("df 没有挂载点")
    return {
        "filesystem": parts[0],
        "total_bytes": total_blocks * 1024,
        "used_bytes": used_blocks * 1024,
        "available_bytes": avail_blocks * 1024,
        "capacity": parts[4],
        "mount": mount,
    }


def pressure_for_available(available_bytes: int, *, warn_bytes: int, block_bytes: int) -> int:
    if available_bytes < block_bytes:
        return 4
    if available_bytes < warn_bytes:
        return 2
    return 1


def default_probe_paths(home: Path | None = None) -> list[Path]:
    root = Path(home) if home is not None else Path.home()
    paths = [root]
    extra = os.environ.get("CORTEX_DISK_GATE_PATHS", "").strip()
    if extra:
        for raw in extra.split(":"):
            raw = raw.strip()
            if raw:
                paths.append(Path(raw).expanduser())
    seen: set[str] = set()
    unique: list[Path] = []
    for path in paths:
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        unique.append(path)
    return unique


def collect_snapshot(
    *,
    paths: Sequence[Path] | None = None,
    warn_bytes: int = DEFAULT_WARN_BYTES,
    block_bytes: int = DEFAULT_BLOCK_BYTES,
    runner: Runner = run_command,
) -> dict[str, Any]:
    probe_paths = list(paths) if paths is not None else default_probe_paths()
    if not probe_paths:
        raise ProbeError("没有可探的路径")
    volumes: list[dict[str, Any]] = []
    by_mount: dict[str, dict[str, Any]] = {}
    for path in probe_paths:
        target = str(path)
        if not path.exists():
            continue
        parsed = parse_df_kp(runner(["df", "-kP", target]))
        parsed["path"] = target
        volumes.append(parsed)
        previous = by_mount.get(parsed["mount"])
        if previous is None or int(parsed["available_bytes"]) < int(previous["available_bytes"]):
            by_mount[parsed["mount"]] = parsed
    if not volumes:
        raise ProbeError("所有探路径都不存在，无法读 df")
    tightest = min(by_mount.values(), key=lambda row: int(row["available_bytes"]))
    available = int(tightest["available_bytes"])
    level = pressure_for_available(available, warn_bytes=warn_bytes, block_bytes=block_bytes)
    return {
        "available_bytes": available,
        "free_bytes": available,
        "total_bytes": int(tightest["total_bytes"]),
        "used_bytes": int(tightest["used_bytes"]),
        "mount": tightest["mount"],
        "filesystem": tightest["filesystem"],
        "path": tightest["path"],
        "capacity": tightest["capacity"],
        "warn_bytes": warn_bytes,
        "block_bytes": block_bytes,
        "pressure_level": level,
        "pressure_name": PRESSURE_NAMES[level],
        "volumes": list(by_mount.values()),
    }


def _gb(value: int) -> str:
    return f"{value / GIB:.1f} GB"


def format_snapshot(snapshot: dict[str, Any]) -> str:
    lines = [
        (
            f"可用磁盘: {_gb(int(snapshot['available_bytes']))} "
            f"(volume {snapshot['mount']}; used {_gb(int(snapshot['used_bytes']))} / "
            f"{_gb(int(snapshot['total_bytes']))}; df {snapshot['capacity']})"
        ),
        f"磁盘压力: {snapshot['pressure_name']} (level={snapshot['pressure_level']})",
        (
            f"闸: 低于 {_gb(int(snapshot['warn_bytes']))} 警告，"
            f"低于 {_gb(int(snapshot['block_bytes']))} 拦住新并行派工"
        ),
    ]
    volumes = snapshot.get("volumes") or []
    if len(volumes) > 1:
        lines.append(f"探到 {len(volumes)} 个卷（按可用从紧到松）:")
        ordered = sorted(volumes, key=lambda row: int(row["available_bytes"]))
        for row in ordered:
            lines.append(
                f"  {_gb(int(row['available_bytes'])):>8}  {row['mount']}  via {row['path']}"
            )
    return "\n".join(lines)


def apply_dispatch_disk_gate(
    *,
    ignore: bool = False,
    snapshot: dict[str, Any] | None = None,
    runner: Runner = run_command,
    warn_bytes: int | None = None,
    block_bytes: int | None = None,
) -> DiskGateDecision:
    """Block new parallel dispatch when disk pressure is critical.

    Warning (level 2) prints and still allows. Probe failure fail-open.
    ``CORTEX_SKIP_DISK_GATE=1`` skips（测试和 resume 用）。
    """
    if ignore or os.environ.get(SKIP_ENV, "").strip() == "1":
        return DiskGateDecision(allowed=True, line="磁盘闸: 已跳过")
    try:
        current = snapshot if snapshot is not None else collect_snapshot(
            warn_bytes=warn_bytes or DEFAULT_WARN_BYTES,
            block_bytes=block_bytes or DEFAULT_BLOCK_BYTES,
            runner=runner,
        )
    except ProbeError as exc:
        warning = f"WARNING 磁盘余量闸采样失败，静默放行: {exc}"
        print(warning, file=sys.stderr, flush=True)
        return DiskGateDecision(allowed=True, warning=warning)

    line = (
        f"磁盘现状: 可用 {_gb(int(current['available_bytes']))} "
        f"({current['pressure_name']}, {current['mount']})"
    )
    print(line, flush=True)
    level = int(current["pressure_level"])
    if level == 4:
        refusal = (
            f"磁盘可用 {_gb(int(current['available_bytes']))}，低于 "
            f"{_gb(int(current['block_bytes']))}。拦住新的并行派工，"
            "等自动回收或清盘后再开线。"
        )
        print(refusal, file=sys.stderr, flush=True)
        return DiskGateDecision(
            allowed=False, snapshot=current, line=line, refusal=refusal
        )
    if level == 2:
        warning = (
            f"WARNING 磁盘可用 {_gb(int(current['available_bytes']))}，已低于 "
            f"{_gb(int(current['warn_bytes']))}。还可以派，但先让回收跑起来。"
        )
        print(warning, file=sys.stderr, flush=True)
        return DiskGateDecision(
            allowed=True, snapshot=current, line=line, warning=warning
        )
    return DiskGateDecision(allowed=True, snapshot=current, line=line)


def main(argv: Sequence[str] | None = None, *, runner: Runner = run_command) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    parser.add_argument(
        "--path",
        action="append",
        default=[],
        metavar="PATH",
        help="要探的路径，可重复；默认 $HOME",
    )
    parser.add_argument(
        "--warn-gb",
        type=float,
        default=DEFAULT_WARN_BYTES / GIB,
        help="警告阈值（GiB），默认 20",
    )
    parser.add_argument(
        "--block-gb",
        type=float,
        default=DEFAULT_BLOCK_BYTES / GIB,
        help="拦派工阈值（GiB），默认 10",
    )
    args = parser.parse_args(argv)
    if args.warn_gb <= args.block_gb:
        parser.error("--warn-gb 必须大于 --block-gb")
    paths = [Path(item).expanduser() for item in args.path] or None
    try:
        snapshot = collect_snapshot(
            paths=paths,
            warn_bytes=int(args.warn_gb * GIB),
            block_bytes=int(args.block_gb * GIB),
            runner=runner,
        )
    except ProbeError as exc:
        print(f"磁盘余量采样失败: {exc}", file=sys.stderr)
        return 3

    if args.json:
        print(json.dumps(snapshot, ensure_ascii=False, sort_keys=True))
    else:
        print(format_snapshot(snapshot))
    return PRESSURE_EXIT_CODES[int(snapshot["pressure_level"])]


if __name__ == "__main__":
    sys.exit(main())
