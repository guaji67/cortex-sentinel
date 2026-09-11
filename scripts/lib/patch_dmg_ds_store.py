#!/usr/bin/env python3
"""把 DMG 里 Finder 写下的图标坐标改回两图标拖拽版式。

AppleScript `set position {180, 170}` 在开了标签栏的 Finder 上会落成
(180, 206)，两个图标同一 +36。打开安装盘时按 .DS_Store 显示，必须是
脚本里的坐标，不能把这台机的 Finder 标签栏写进发给别人的盘。
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


DMG_ICON_POSITIONS = {
    "Applications": (480, 170),
}


def parse_iloc_positions(data: bytes) -> dict[str, tuple[int, int]]:
    positions: dict[str, tuple[int, int]] = {}
    index = 0
    while index < len(data) - 8:
        if data[index : index + 4] != b"Iloc":
            index += 1
            continue
        name = _name_before(data, index)
        data_type = data[index + 4 : index + 8]
        if data_type == b"blob" and name:
            x, y = struct.unpack(">II", data[index + 12 : index + 20])
            positions[name] = (x, y)
        index += 1
    return positions


def patch_iloc_positions(data: bytearray, expected: dict[str, tuple[int, int]]) -> list[str]:
    missing = list(expected)
    index = 0
    while index < len(data) - 8:
        if data[index : index + 4] != b"Iloc":
            index += 1
            continue
        name = _name_before(data, index)
        data_type = data[index + 4 : index + 8]
        if data_type == b"blob" and name in expected:
            x, y = expected[name]
            data[index + 12 : index + 20] = struct.pack(">II", x, y)
            if name in missing:
                missing.remove(name)
        index += 1
    return missing


def _name_before(data: bytes, index: int) -> str | None:
    for back in range(2, 300, 2):
        start = index - back - 4
        if start < 0:
            break
        (length,) = struct.unpack(">I", data[start : start + 4])
        if length * 2 != back or not 0 < length < 150:
            continue
        try:
            candidate = data[start + 4 : start + 4 + length * 2].decode("utf-16-be")
        except UnicodeDecodeError:
            continue
        if all(char.isprintable() for char in candidate):
            return candidate
    return None


def dmg_positions_for_app(app_name: str) -> dict[str, tuple[int, int]]:
    positions = dict(DMG_ICON_POSITIONS)
    positions[app_name] = (180, 170)
    return positions


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="把 DMG .DS_Store 图标坐标改回两图标拖拽版式")
    parser.add_argument("--ds-store", required=True, type=Path)
    parser.add_argument("--app-name", required=True)
    args = parser.parse_args(argv)

    path = args.ds_store
    if not path.is_file():
        print(f"找不到 .DS_Store：{path}", file=sys.stderr)
        return 1

    expected = dmg_positions_for_app(args.app_name)
    data = bytearray(path.read_bytes())
    missing = patch_iloc_positions(data, expected)
    if missing:
        print("Finder 没写下这些图标的坐标：" + "、".join(missing), file=sys.stderr)
        return 1
    path.write_bytes(data)
    got = parse_iloc_positions(bytes(data))
    for name, want in expected.items():
        if got.get(name) != want:
            print(f"{name} 改完仍是 {got.get(name)}，应为 {want}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
