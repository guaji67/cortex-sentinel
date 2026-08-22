#!/usr/bin/env python3
"""统一入口：status / watch / lines / reap / doctor / dispatch。"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def _cmd_status(argv: list[str]) -> int:
    from cortex_sentinel.channel import main as channel_main

    return channel_main(argv)


def _cmd_watch(argv: list[str]) -> int:
    from cortex_sentinel.watch import main as watch_main

    return watch_main(argv)


def _cmd_lines(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="cortex-sentinel lines", description="列出登记表和各线状态文件")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    from cortex_sentinel.paths import registry_path, status_dir

    registry_file = registry_path()
    rows: list[object] = []
    if registry_file.exists():
        try:
            payload = json.loads(registry_file.read_text(encoding="utf-8"))
            if isinstance(payload, list):
                rows = payload
        except (OSError, json.JSONDecodeError, UnicodeError):
            rows = []
    statuses = sorted(status_dir().glob("*.status.json"))
    if args.json:
        print(
            json.dumps(
                {
                    "registry": str(registry_file),
                    "lines": rows,
                    "status_files": [str(path) for path in statuses],
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0
    print(f"registry: {registry_file} ({len(rows)} 条)")
    if not rows:
        print("  (空)")
    else:
        for row in rows:
            if not isinstance(row, dict):
                continue
            print(
                f"  {row.get('slug')}  engine={row.get('engine')}  "
                f"{row.get('label_zh')}  {row.get('registered_at')}"
            )
    print(f"status files: {len(statuses)}")
    for path in statuses:
        print(f"  {path.name}")
    return 0


def _cmd_reap(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="cortex-sentinel reap",
        description="回收死线工作树 / 可选收残留 dev server。默认只看不动。",
    )
    parser.add_argument("--apply", action="store_true", help="真的送回收站；默认只看")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--dev-servers", action="store_true", help="改跑 dev server 回收器")
    args, rest = parser.parse_known_args(argv)
    forwarded: list[str] = list(rest)
    if args.apply:
        forwarded.append("--apply")
    if args.json:
        forwarded.append("--json")
    if args.dev_servers:
        from cortex_sentinel.devserver import main as reaper_main

        return reaper_main() if not forwarded else _run_devserver(forwarded)
    from cortex_sentinel.reclaim import main as reclaim_main

    return reclaim_main(forwarded)


def _run_devserver(argv: list[str]) -> int:
    from cortex_sentinel import devserver

    # 原入口不收 argv，只读 sys.argv。这里临时替换。
    old = sys.argv
    try:
        sys.argv = [old[0], *argv]
        return int(devserver.main())
    finally:
        sys.argv = old


def _cmd_dispatch(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="cortex-sentinel dispatch")
    parser.add_argument("engine", choices=("codex", "grok", "progress"))
    args, rest = parser.parse_known_args(argv)
    if args.engine == "grok":
        from cortex_sentinel.dispatch.grok import main as grok_main

        return int(grok_main(rest))
    if args.engine == "codex":
        from cortex_sentinel.dispatch import codex as codex_mod

        target = codex_mod.main
    else:
        from cortex_sentinel.dispatch import progress as progress_mod

        target = progress_mod.main
    old = sys.argv
    try:
        sys.argv = [old[0], *rest]
        return int(target() or 0)
    finally:
        sys.argv = old


def _cmd_doctor(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="cortex-sentinel doctor", description="自检家目录、配置、python、launchd 模板是否已装")
    parser.parse_args(argv)
    from cortex_sentinel.paths import config_path, load_config, sentinel_home

    home = sentinel_home()
    cfg_file = config_path()
    cfg = load_config()
    projects = cfg.get("projects") or []
    version = sys.version_info
    py_ok = version >= (3, 9)
    plist = Path.home() / "Library" / "LaunchAgents" / "com.falcon.cortex.memory-monitor.plist"
    print(f"python: {sys.version.split()[0]} ({'ok' if py_ok else 'need >= 3.9'})")
    print(f"executable: {sys.executable}")
    print(f"home: {home} exists={home.is_dir()}")
    print(f"config: {cfg_file} exists={cfg_file.exists()} projects={len(projects)}")
    print(f"launchd plist present: {plist.exists()} ({plist})")
    print(f"CORTEX_SENTINEL_HOME: {os.environ.get('CORTEX_SENTINEL_HOME') or '(unset, default ~/.cortex-sentinel)'}")
    return 0 if py_ok else 2


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="cortex-sentinel",
        description="Cortex 哨兵独立版：盯线、通道、机器健康。不依赖 Cortex 仓。",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="通道判决（Grok / Codex 通不通）")
    sub.add_parser("watch", help="跨会话盯线（list / watch）")
    sub.add_parser("lines", help="登记表 + 各线 status 文件")
    sub.add_parser("reap", help="回收死线 / 可选收残留 dev server")
    sub.add_parser("doctor", help="自检家目录、配置、python、launchd")
    sub.add_parser("dispatch", help="派工：codex / grok / progress")
    return parser


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        build_parser().print_help()
        return 2
    cmd = argv[0]
    rest = argv[1:]
    if cmd in {"-h", "--help"}:
        build_parser().print_help()
        return 0
    dispatch = {
        "status": _cmd_status,
        "watch": _cmd_watch,
        "lines": _cmd_lines,
        "reap": _cmd_reap,
        "doctor": _cmd_doctor,
        "dispatch": _cmd_dispatch,
    }
    handler = dispatch.get(cmd)
    if handler is None:
        build_parser().print_help()
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return int(handler(rest) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
