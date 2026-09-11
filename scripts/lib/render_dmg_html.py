#!/usr/bin/env python3
"""把 DMG 用的 HTML 渲成 PNG（占位符换成 data URI，Chrome 截图，标 144 dpi）。"""

from __future__ import annotations

import argparse
import base64
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


PLACEHOLDERS = ("__APP_ICON__", "__REPAIR_ICON__", "__IMG__")


def _data_uri(path: Path) -> str:
    payload = path.read_bytes()
    suffix = path.suffix.lower()
    mime = {
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".gif": "image/gif",
        ".webp": "image/webp",
        ".svg": "image/svg+xml",
    }.get(suffix, "image/png")
    encoded = base64.b64encode(payload).decode("ascii")
    return f"data:{mime};base64,{encoded}"


def inject_placeholders(template: str, replacements: dict[str, Path]) -> str:
    html = template
    for key, path in replacements.items():
        token = key if key.startswith("__") else f"__{key}__"
        if token not in html:
            raise SystemExit(f"模板里没有占位符 {token}")
        html = html.replace(token, _data_uri(path))
    missing = [token for token in PLACEHOLDERS if token in html]
    if missing:
        raise SystemExit("还没替换的占位符：" + ", ".join(missing))
    return html


def _chrome_bin() -> Path:
    env = os.environ.get("CORTEX_CHROME_BIN", "").strip()
    if env:
        path = Path(env)
        if path.is_file() and os.access(path, os.X_OK):
            return path
        raise SystemExit(f"CORTEX_CHROME_BIN 不可执行：{path}")
    default = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    if default.is_file() and os.access(default, os.X_OK):
        return default
    raise SystemExit("找不到 Chrome，用 CORTEX_CHROME_BIN 指定可执行文件")


def _command_claims_user_data_dir(command: str, user_data_dir: Path) -> bool:
    """只认 --user-data-dir 的完整参数，拒绝路径前缀碰撞和 --profile-dir。"""
    marker = str(user_data_dir)
    tokens = (f"--user-data-dir={marker}", f"--user-data-dir {marker}")
    for token in tokens:
        start = 0
        while True:
            index = command.find(token, start)
            if index < 0:
                break
            end = index + len(token)
            if end == len(command) or command[end].isspace():
                return True
            start = index + 1
    return False


def _pids_for_user_data_dir(user_data_dir: Path) -> list[int]:
    result = subprocess.run(
        ["/bin/ps", "-ax", "-o", "pid=", "-o", "command="],
        capture_output=True,
        text=True,
        check=False,
    )
    found: list[int] = []
    self_pid = os.getpid()
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        if pid == self_pid:
            continue
        if not _command_claims_user_data_dir(command, user_data_dir):
            continue
        found.append(pid)
    return found


def _descendant_pids(root_pid: int) -> set[int]:
    result = subprocess.run(
        ["/bin/ps", "-ax", "-o", "pid=", "-o", "ppid="],
        capture_output=True,
        text=True,
        check=False,
    )
    children: dict[int, list[int]] = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
        except ValueError:
            continue
        children.setdefault(ppid, []).append(pid)
    found = {root_pid}
    stack = [root_pid]
    while stack:
        current = stack.pop()
        for child in children.get(current, []):
            if child not in found:
                found.add(child)
                stack.append(child)
    return found


def _owned_chrome_pids(parent_pid: int | None) -> set[int]:
    if not parent_pid:
        return set()
    try:
        return _descendant_pids(parent_pid)
    except OSError:
        return {parent_pid}


def _signal_owned(pids: set[int], sig: int) -> None:
    for pid in sorted(pids):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            continue


def _stop_chrome(user_data_dir: Path, parent_pid: int | None) -> None:
    # 认领只认自己拉起的 pid / 子孙 / 进程组。profile 路径即使完全相同
    # 也不拿来扫杀，否则共用目录或前缀碰撞会误杀另一个渲染器。
    del user_data_dir
    pids = _owned_chrome_pids(parent_pid)
    pids.discard(os.getpid())
    pids.discard(os.getppid())
    if parent_pid:
        try:
            if os.getpgid(parent_pid) == parent_pid:
                os.killpg(parent_pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError, OSError):
            pass
    _signal_owned(pids, signal.SIGTERM)
    time.sleep(0.4)
    if parent_pid:
        try:
            if os.getpgid(parent_pid) == parent_pid:
                os.killpg(parent_pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
    _signal_owned(pids, signal.SIGKILL)


def screenshot_html(
    html_path: Path,
    out_png: Path,
    width: int,
    height: int,
    scale: int,
    profile_dir: Path,
) -> None:
    chrome = _chrome_bin()
    out_png.parent.mkdir(parents=True, exist_ok=True)
    if out_png.exists():
        out_png.unlink()

    command = [
        str(chrome),
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--no-first-run",
        "--no-default-browser-check",
        f"--user-data-dir={profile_dir}",
        f"--force-device-scale-factor={scale}",
        f"--window-size={width},{height}",
        f"--screenshot={out_png}",
        html_path.resolve().as_uri(),
    ]
    proc = subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        deadline = time.time() + 60
        while time.time() < deadline:
            if out_png.is_file() and out_png.stat().st_size > 0:
                time.sleep(0.8)
                break
            if proc.poll() is not None and not (out_png.is_file() and out_png.stat().st_size > 0):
                break
            time.sleep(0.2)
        else:
            raise SystemExit("Chrome 截图超时，没有生成 PNG")
    finally:
        _stop_chrome(profile_dir, proc.pid)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()

    if not out_png.is_file() or out_png.stat().st_size == 0:
        raise SystemExit(f"渲染失败，没有生成 {out_png}")

    expected_w = width * scale
    expected_h = height * scale
    probe = subprocess.run(
        ["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(out_png)],
        capture_output=True,
        text=True,
        check=False,
    )
    got_w = got_h = None
    for line in probe.stdout.splitlines():
        if "pixelWidth:" in line:
            got_w = int(line.split(":")[-1].strip())
        elif "pixelHeight:" in line:
            got_h = int(line.split(":")[-1].strip())
    if (got_w, got_h) != (expected_w, expected_h):
        resize = subprocess.run(
            ["/usr/bin/sips", "-z", str(expected_h), str(expected_w), str(out_png)],
            capture_output=True,
            text=True,
            check=False,
        )
        if resize.returncode != 0:
            raise SystemExit(
                f"截图像素是 {got_w}x{got_h}，期望 {expected_w}x{expected_h}，sips 缩放失败：{resize.stderr}"
            )

    tagged = subprocess.run(
        ["/usr/bin/sips", "-s", "dpiWidth", "144", "-s", "dpiHeight", "144", str(out_png)],
        capture_output=True,
        text=True,
        check=False,
    )
    if tagged.returncode != 0:
        raise SystemExit(f"给 PNG 标 144 dpi 失败：{tagged.stderr}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="渲染 Cortex DMG 用的 HTML 为 PNG")
    parser.add_argument("--html", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--width", required=True, type=int)
    parser.add_argument("--height", required=True, type=int)
    parser.add_argument("--scale", type=int, default=2)
    parser.add_argument("--profile-dir", type=Path, required=True)
    parser.add_argument(
        "--replace",
        action="append",
        default=[],
        metavar="NAME=PATH",
        help="替换 __NAME__ 为图片 data URI，可重复",
    )
    parser.add_argument(
        "--rendered-html",
        type=Path,
        help="把替换后的 HTML 另存一份（便于核对占位符）",
    )
    args = parser.parse_args(argv)

    if not args.html.is_file():
        raise SystemExit(f"找不到 HTML：{args.html}")

    html = args.html.read_text(encoding="utf-8")
    replacements: dict[str, Path] = {}
    for item in args.replace:
        if "=" not in item:
            raise SystemExit(f"--replace 格式应为 NAME=PATH，收到：{item}")
        name, raw_path = item.split("=", 1)
        path = Path(raw_path)
        if not path.is_file():
            raise SystemExit(f"替换图片不存在：{path}")
        replacements[name] = path
    if replacements:
        html = inject_placeholders(html, replacements)

    args.profile_dir.mkdir(parents=True, exist_ok=True)
    work_html = args.profile_dir / "page.html"
    work_html.write_text(html, encoding="utf-8")
    if args.rendered_html:
        args.rendered_html.parent.mkdir(parents=True, exist_ok=True)
        args.rendered_html.write_text(html, encoding="utf-8")

    screenshot_html(
        html_path=work_html,
        out_png=args.out,
        width=args.width,
        height=args.height,
        scale=args.scale,
        profile_dir=args.profile_dir,
    )
    print(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
