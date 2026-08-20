#!/usr/bin/env python3
"""Codex / Grok 派工登记表的唯一写入与时间戳兼容规则。"""

from __future__ import annotations

import fcntl
import json
import os
import re
import socket
import subprocess
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


EAST_EIGHT = timezone(timedelta(hours=8))
REQUIRED_FIELDS = ("slug", "label_zh", "dispatcher_zh", "registered_at", "engine")

_ISO_WITH_TIMEZONE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)
_NAIVE_WITH_T = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?$")
_NAIVE_WITH_SPACE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")


class LineRegistryError(ValueError):
    """登记表不可读或新登记不符合哨兵合同。"""


@dataclass(frozen=True)
class RegistrationWriteResult:
    entry: dict[str, str]
    action: str
    index: int


def east_eight_timestamp(now: datetime | None = None) -> str:
    """生成东八区、带秒、带时区的唯一写入格式。"""
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        raise LineRegistryError("registered_at clock must include timezone")
    return current.astimezone(EAST_EIGHT).isoformat(timespec="seconds")


def sentinel_timestamp_seconds(value: object) -> float | None:
    """复刻哨兵 registered_at 的可接受集合，返回可解析秒数或 None。"""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str):
        return None

    stripped = value.strip()
    try:
        return float(stripped)
    except ValueError:
        pass

    if _ISO_WITH_TIMEZONE.fullmatch(stripped):
        try:
            return datetime.fromisoformat(stripped.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    if _NAIVE_WITH_T.fullmatch(stripped) or _NAIVE_WITH_SPACE.fullmatch(stripped):
        try:
            return datetime.fromisoformat(stripped).replace(tzinfo=EAST_EIGHT).timestamp()
        except ValueError:
            return None
    return None


def validate_registration(entry: object) -> list[str]:
    """校验守护新写条目的固定字段与哨兵时间戳合同。"""
    if not isinstance(entry, dict):
        return ["entry must be an object"]

    findings: list[str] = []
    missing = [field for field in REQUIRED_FIELDS if field not in entry]
    if missing:
        findings.append(f"missing fields: {', '.join(missing)}")
    for field in ("slug", "label_zh", "dispatcher_zh", "engine", "host"):
        value = entry.get(field)
        if field in entry and (not isinstance(value, str) or not value.strip()):
            findings.append(f"{field} must be a non-empty string")
    if "registered_at" in entry and sentinel_timestamp_seconds(entry["registered_at"]) is None:
        findings.append("registered_at is not decodable by Cortex Sentinel")
    return findings


def _load_registry(path: Path) -> list[Any]:
    if not path.exists():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LineRegistryError(f"invalid line registry {path}: {exc}") from exc
    if not isinstance(payload, list):
        raise LineRegistryError(f"line registry must be a JSON array: {path}")
    return payload


def _write_registry_atomic(path: Path, rows: list[Any]) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    try:
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(rows, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def local_host_name(
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    gethostname: Callable[[], str] = socket.gethostname,
) -> str | None:
    """本机展示名：优先 scutil ComputerName，回落 hostname；两个都拿不到就返回 None。"""
    try:
        completed = run(
            ["scutil", "--get", "ComputerName"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        completed = None
    if completed is not None:
        name = (completed.stdout or "").strip()
        if completed.returncode == 0 and name:
            return name
    try:
        name = (gethostname() or "").strip()
    except OSError:
        return None
    return name or None


def upsert_line_registration(
    path: Path,
    *,
    slug: str,
    label_zh: str,
    dispatcher_zh: str,
    engine: str = "codex",
    now: datetime | None = None,
    host: str | None = None,
) -> RegistrationWriteResult:
    """按 slug 收敛成唯一登记；registry 是当前元数据，不把 resume 当事件账本追加。"""
    entry = {
        "slug": slug.strip(),
        "label_zh": label_zh.strip(),
        "dispatcher_zh": dispatcher_zh.strip(),
        "registered_at": east_eight_timestamp(now),
        "engine": engine.strip(),
    }
    if host is not None:
        entry["host"] = host.strip() if isinstance(host, str) else host
    findings = validate_registration(entry)
    if findings:
        raise LineRegistryError("; ".join(findings))

    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(path.name + ".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        rows = _load_registry(path)
        matching = [
            index
            for index, row in enumerate(rows)
            if isinstance(row, dict) and row.get("slug") == entry["slug"]
        ]
        if matching:
            index = matching[0]
            rows[index] = entry
            for duplicate_index in reversed(matching[1:]):
                del rows[duplicate_index]
            action = "updated"
        else:
            rows.append(entry)
            index = len(rows) - 1
            action = "inserted"
        _write_registry_atomic(path, rows)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    return RegistrationWriteResult(entry=entry, action=action, index=index)
