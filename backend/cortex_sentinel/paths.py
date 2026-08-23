#!/usr/bin/env python3
"""SENTINEL_HOME 与 config.toml 解析。取代仓内 REPO_ROOT / CortexPaths。

状态一律写在家目录下，不写被监护项目仓库里。这样 launchd 也不用去碰
~/Documents 后面那堵 TCC 墙。

解析顺序：环境变量 CORTEX_SENTINEL_HOME 优先，没有就 ~/.cortex-sentinel。

配置文件不存在时返回空项目列表，盯线 / 通道 / 内存这些跟项目无关的功能
必须还能空跑，不许崩。

config.toml 示例（默认值只是例子，不会在缺文件时自动写进去）：

    [[projects]]
    name = "cortex"
    root = "/path/to/cortex"
    data_root = "/path/to/cortex-data"
    dev_ports = [3000, "3401-3439"]
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any


_HOME_ENV = "CORTEX_SENTINEL_HOME"
_DEFAULT_HOME_NAME = ".cortex-sentinel"


def sentinel_home() -> Path:
    """CORTEX_SENTINEL_HOME 或 ~/.cortex-sentinel，保证目录存在。"""
    raw = os.environ.get(_HOME_ENV, "").strip()
    home = Path(raw).expanduser() if raw else Path.home() / _DEFAULT_HOME_NAME
    home.mkdir(parents=True, exist_ok=True)
    (home / "status").mkdir(parents=True, exist_ok=True)
    (home / "logs").mkdir(parents=True, exist_ok=True)
    return home


def registry_path() -> Path:
    """<home>/registry.json"""
    return sentinel_home() / "registry.json"


def status_dir() -> Path:
    """<home>/status"""
    path = sentinel_home() / "status"
    path.mkdir(parents=True, exist_ok=True)
    return path


def logs_dir() -> Path:
    """<home>/logs"""
    path = sentinel_home() / "logs"
    path.mkdir(parents=True, exist_ok=True)
    return path


def channel_status_path() -> Path:
    """<home>/channel-status.json"""
    return sentinel_home() / "channel-status.json"


def config_path() -> Path:
    return sentinel_home() / "config.toml"


def _quote_bare_port_ranges(text: str) -> str:
    """票面示例把 3401-3439 写成未加引号的数组元素，标准 TOML 会当成减法。

    解析前把数组里未加引号的 N-M 收成字符串，调用方仍然写成票面那种样子。
    """

    def repl(match: re.Match[str]) -> str:
        inner = re.sub(
            r'(?<!["\'])\b(\d+-\d+)\b(?!["\'])',
            r'"\1"',
            match.group(1),
        )
        return "[" + inner + "]"

    return re.sub(r"\[([^\[\]]*)\]", repl, text)


def _parse_scalar(raw: str) -> Any:
    text = raw.strip()
    if text.startswith("[") and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        items = []
        for part in inner.split(","):
            items.append(_parse_scalar(part))
        return items
    if len(text) >= 2 and text[0] == text[-1] and text[0] in {"'", '"'}:
        return text[1:-1]
    if text in {"true", "false"}:
        return text == "true"
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if re.fullmatch(r"-?\d+\.\d+", text):
        return float(text)
    return text


def _parse_config_toml_lite(text: str) -> dict[str, Any]:
    """3.9 没有 tomllib 时的子集解析：顶层键 + [[projects]] 表数组。"""
    data: dict[str, Any] = {"projects": []}
    current: dict[str, Any] | None = None
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        stripped = line.strip()
        if stripped == "[[projects]]":
            current = {}
            data["projects"].append(current)
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            current = None
            continue
        if "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        key = key.strip()
        parsed = _parse_scalar(value)
        if current is not None:
            current[key] = parsed
        else:
            data[key] = parsed
    return data


def _loads_toml(text: str) -> dict[str, Any]:
    prepared = _quote_bare_port_ranges(text)
    try:
        import tomllib  # Python 3.11+
    except ImportError:
        parsed = _parse_config_toml_lite(prepared)
    else:
        try:
            loaded = tomllib.loads(prepared)
        except Exception:
            parsed = _parse_config_toml_lite(prepared)
        else:
            parsed = loaded if isinstance(loaded, dict) else {"projects": []}
    if not isinstance(parsed.get("projects"), list):
        parsed["projects"] = []
    return parsed


def _expand_dev_ports(raw: Any) -> list[int]:
    ports: list[int] = []
    if not isinstance(raw, list):
        return ports
    for item in raw:
        if isinstance(item, bool):
            continue
        if isinstance(item, int):
            ports.append(item)
            continue
        if isinstance(item, str):
            text = item.strip()
            if re.fullmatch(r"\d+", text):
                ports.append(int(text))
                continue
            match = re.fullmatch(r"(\d+)-(\d+)", text)
            if match:
                lo, hi = int(match.group(1)), int(match.group(2))
                if lo <= hi and hi - lo <= 10_000:
                    ports.extend(range(lo, hi + 1))
    return ports


def _normalize_project(row: Any) -> dict[str, Any] | None:
    if not isinstance(row, dict):
        return None
    name = row.get("name")
    root = row.get("root")
    if not isinstance(name, str) or not name.strip():
        name = ""
    if not isinstance(root, str) or not root.strip():
        return None
    out: dict[str, Any] = {
        "name": name.strip() or Path(root).name,
        "root": str(Path(root).expanduser()),
    }
    data_root = row.get("data_root")
    if isinstance(data_root, str) and data_root.strip():
        out["data_root"] = str(Path(data_root).expanduser())
    ports = _expand_dev_ports(row.get("dev_ports"))
    if ports:
        out["dev_ports"] = ports
    return out


def load_config() -> dict:
    """读 config.toml，不存在返回 {"projects": []}。"""
    path = config_path()
    if not path.exists():
        return {"projects": []}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {"projects": []}
    parsed = _loads_toml(text)
    projects_out = []
    for row in parsed.get("projects") or []:
        normalized = _normalize_project(row)
        if normalized is not None:
            projects_out.append(normalized)
    parsed["projects"] = projects_out
    return parsed


def projects() -> list[dict]:
    """配置里的项目列表，可能是空的。"""
    rows = load_config().get("projects") or []
    return [row for row in rows if isinstance(row, dict)]


def find_project(path: Path) -> dict | None:
    """某个路径属于哪个被监护项目。"""
    try:
        resolved = Path(path).expanduser().resolve()
    except OSError:
        resolved = Path(path).expanduser()
    best: dict[str, Any] | None = None
    best_len = -1
    for row in projects():
        root_raw = row.get("root")
        if not isinstance(root_raw, str) or not root_raw.strip():
            continue
        root = Path(root_raw).expanduser()
        try:
            root_resolved = root.resolve()
        except OSError:
            root_resolved = root
        try:
            resolved.relative_to(root_resolved)
        except ValueError:
            continue
        n = len(str(root_resolved))
        if n > best_len:
            best = row
            best_len = n
    return best
