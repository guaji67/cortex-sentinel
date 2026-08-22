#!/usr/bin/env python3
"""Report macOS memory headroom and expose the system pressure level as an exit code."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Callable, Sequence
from typing import Any


GIB = 1024**3
PRESSURE_NAMES = {1: "正常", 2: "警告", 4: "危急"}
PRESSURE_EXIT_CODES = {1: 0, 2: 1, 4: 2}
Runner = Callable[[Sequence[str]], str]


class ProbeError(RuntimeError):
    """A required macOS probe did not produce a trustworthy value."""


def run_command(args: Sequence[str]) -> str:
    try:
        result = subprocess.run(
            list(args),
            capture_output=True,
            text=True,
            timeout=90,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ProbeError(f"命令执行失败: {' '.join(args)}: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise ProbeError(f"命令执行失败: {' '.join(args)}: {detail}")
    return result.stdout


def parse_vm_stat(text: str) -> dict[str, int]:
    page_match = re.search(r"page size of\s+(\d+)\s+bytes", text or "", re.IGNORECASE)
    if page_match is None:
        raise ProbeError("vm_stat 没有给出页大小")

    values: dict[str, int] = {"page_size": int(page_match.group(1))}
    for line in (text or "").splitlines():
        for label, key in (("Pages free", "free_pages"), ("Pages inactive", "inactive_pages")):
            if line.startswith(label):
                count = re.search(r"(\d[\d,]*)\.?\s*$", line)
                if count is not None:
                    values[key] = int(count.group(1).replace(",", ""))
                break

    missing = [key for key in ("free_pages", "inactive_pages") if key not in values]
    if missing:
        raise ProbeError(f"vm_stat 缺少字段: {', '.join(missing)}")
    return values


def parse_pressure_level(text: str) -> int:
    match = re.search(r"\b(\d+)\b", text or "")
    level = int(match.group(1)) if match else 0
    if level not in PRESSURE_NAMES:
        raise ProbeError(f"未知内存压力等级: {text.strip() or '空'}")
    return level


def _size_bytes(value: str, unit: str) -> int:
    scale = {"B": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
    return round(float(value) * scale[unit.upper()])


def parse_swapusage(text: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for label in ("total", "used", "free"):
        match = re.search(
            rf"{label}\s*=\s*([0-9]+(?:\.[0-9]+)?)([KMGT])",
            text or "",
            re.IGNORECASE,
        )
        if match is not None:
            values[f"{label}_bytes"] = _size_bytes(match.group(1), match.group(2))
    missing = [f"{label}_bytes" for label in ("total", "used", "free") if f"{label}_bytes" not in values]
    if missing:
        raise ProbeError(f"vm.swapusage 缺少字段: {', '.join(missing)}")
    return values


def parse_top(text: str, limit: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    pattern = re.compile(
        r"^\s*(\d+)\s+(\S+)\s+([0-9.]+)([BKMGT])\+?\s+([0-9.]+)([BKMGT])\+?\s*$",
        re.IGNORECASE,
    )
    for line in (text or "").splitlines():
        match = pattern.match(line)
        if match is None:
            continue
        rows.append(
            {
                "pid": int(match.group(1)),
                "command": match.group(2),
                "memory_bytes": _size_bytes(match.group(3), match.group(4)),
                "compressed_bytes": _size_bytes(match.group(5), match.group(6)),
            }
        )
    rows.sort(key=lambda row: int(row["memory_bytes"]), reverse=True)
    return rows[:limit]


def collect_snapshot(*, top_n: int = 5, runner: Runner = run_command) -> dict[str, Any]:
    vm = parse_vm_stat(runner(["vm_stat"]))
    pressure_level = parse_pressure_level(
        runner(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"])
    )
    swap = parse_swapusage(runner(["sysctl", "-n", "vm.swapusage"]))
    processes: list[dict[str, Any]] = []
    if top_n:
        top_text = runner(
            [
                "top",
                "-l",
                "1",
                "-o",
                "mem",
                "-stats",
                "pid,command,mem,cmprs",
                "-n",
                str(top_n),
            ]
        )
        processes = parse_top(top_text, top_n)
        if not processes:
            raise ProbeError("top 没有给出可解析的进程内存行")

    free_bytes = vm["free_pages"] * vm["page_size"]
    inactive_bytes = vm["inactive_pages"] * vm["page_size"]
    return {
        "available_bytes": free_bytes + inactive_bytes,
        "free_bytes": free_bytes,
        "inactive_bytes": inactive_bytes,
        "page_size": vm["page_size"],
        "pressure_level": pressure_level,
        "pressure_name": PRESSURE_NAMES[pressure_level],
        "swap": swap,
        "processes": processes,
    }


def _gb(value: int) -> str:
    return f"{value / GIB:.1f} GB"


def format_snapshot(snapshot: dict[str, Any]) -> str:
    swap = snapshot["swap"]
    lines = [
        (
            f"可用内存: {_gb(snapshot['available_bytes'])} "
            f"(free {_gb(snapshot['free_bytes'])} + inactive {_gb(snapshot['inactive_bytes'])}; "
            f"page {snapshot['page_size']} bytes)"
        ),
        f"内存压力: {snapshot['pressure_name']} (level={snapshot['pressure_level']})",
        (
            f"Swap: 已用 {_gb(swap['used_bytes'])} / {_gb(swap['total_bytes'])} "
            f"(剩余 {_gb(swap['free_bytes'])})"
        ),
    ]
    processes = snapshot["processes"]
    if processes:
        lines.append(f"内存进程前 {len(processes)} 名:")
        for row in processes:
            lines.append(
                f"  {row['pid']:>6}  {_gb(row['memory_bytes']):>8}  "
                f"压缩 {_gb(row['compressed_bytes']):>8}  {row['command']}"
            )
    else:
        lines.append("内存进程: 本次未采样")
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None, *, runner: Runner = run_command) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    parser.add_argument("--top", type=int, default=5, metavar="N", help="显示内存前 N 名进程")
    args = parser.parse_args(argv)
    if args.top < 0:
        parser.error("--top 必须大于等于 0")

    try:
        snapshot = collect_snapshot(top_n=args.top, runner=runner)
    except ProbeError as exc:
        print(f"内存余量采样失败: {exc}", file=sys.stderr)
        return 3

    if args.json:
        print(json.dumps(snapshot, ensure_ascii=False, sort_keys=True))
    else:
        print(format_snapshot(snapshot))
    return PRESSURE_EXIT_CODES[int(snapshot["pressure_level"])]


if __name__ == "__main__":
    sys.exit(main())
