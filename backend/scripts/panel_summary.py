#!/usr/bin/env python3
"""从内存探针 JSON 中提取 memory_monitor.sh 需要的标量和摘要。

为什么要单独一个文件（2026-08-18）：这两段解析原来是内嵌在 `memory_monitor.sh` 里的
`python3 -c '...'`。因为外层是 bash 单引号，有人给内层 f-string 的引号加了反斜杠转义，
于是那段代码变成：

    bits.append(f"{a.get(\\"gb\\",0):.1f}GB {a.get(\\"label\\")}")

Python 拿到的是字面的 `\\"`，直接 `SyntaxError: unexpected character after line
continuation character`。**SyntaxError 是编译期的，外面那个 `try/except Exception: pass`
根本抓不到**；而调用处写的是 `2>/dev/null`，于是唯一的线索也被丢掉。净效果：
大头名单这一栏从写下来那天起一次都没成功过，报告里只留一句「面板采样失败，旧 RSS
大头仅作兜底」，看起来像个小毛病。

抽成文件解决三件事：不再有引号地狱、失败有真实退出码和 stderr、可以单独跑单独测。

用法：

    panel_summary.py --json-file <mem_watch --json 的输出> --field used_gb
    panel_summary.py --json-file <同上> --field top_eaters
    panel_summary.py --json-file <memory_pressure_gate --json 的输出> --field available_gb
    panel_summary.py --json-file <同上> --field pressure_level

取不到就退非 0 并把原因写 stderr，调用方据此判「口径退化」。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def used_gb(data: dict) -> str:
    panel = data.get("panel") or {}
    missing = [k for k in ("app_gb", "wired_gb", "compressed_gb") if panel.get(k) is None]
    if missing:
        raise KeyError(f"panel 缺字段 {missing}（拿到的键: {sorted(panel)}）")
    total = float(panel["app_gb"]) + float(panel["wired_gb"]) + float(panel["compressed_gb"])
    return f"{total:.1f}"


def top_eaters(data: dict, limit: int = 8) -> str:
    apps = data.get("apps") or []
    if not apps:
        raise KeyError("apps 是空的")
    bits = []
    for a in apps[:limit]:
        gb = a.get("gb")
        label = a.get("label")
        if gb is None or label is None:
            continue
        bits.append(f"{float(gb):.1f}GB {label}")
    if not bits:
        raise KeyError(f"apps 有 {len(apps)} 条但没有一条同时带 gb 和 label")
    return "; ".join(bits)


def available_gb(data: dict) -> str:
    value = data.get("available_bytes")
    if value is None:
        raise KeyError("缺字段 available_bytes")
    return f"{float(value) / 1073741824:.1f}"


def pressure_level(data: dict) -> str:
    value = data.get("pressure_level")
    if value not in (1, 2, 4):
        raise ValueError(f"pressure_level 不是 1/2/4: {value!r}")
    return str(value)


def pressure_name(data: dict) -> str:
    value = data.get("pressure_name")
    if value not in ("正常", "警告", "危急"):
        raise ValueError(f"pressure_name 未知: {value!r}")
    return str(value)


FIELDS = {
    "available_gb": available_gb,
    "pressure_level": pressure_level,
    "pressure_name": pressure_name,
    "top_eaters": top_eaters,
    "used_gb": used_gb,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json-file", required=True, help="mem_watch.py --json 的输出文件")
    ap.add_argument("--field", required=True, choices=sorted(FIELDS))
    args = ap.parse_args()

    p = Path(args.json_file)
    try:
        raw = p.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"读不到 {p.name}: {exc}", file=sys.stderr)
        return 2
    if not raw.strip():
        print(f"{p.name} 是空的（mem_watch 大概没出东西）", file=sys.stderr)
        return 2
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        print(f"{p.name} 不是合法 JSON: {exc}", file=sys.stderr)
        return 2

    try:
        print(FIELDS[args.field](data))
    except Exception as exc:  # noqa: BLE001 - 调用方只需要「取不到 + 为什么」
        print(f"取 {args.field} 失败: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
