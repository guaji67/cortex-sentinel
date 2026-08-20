#!/usr/bin/env python3
"""自动回收并行线留下的开发副本。默认只看不动；监控带 --apply 才送回收站。

收的是「干完没人删」的那一类，不是用户数据。永远不碰 ~/CortexData、镜像盘、
主仓工作树、WebRuntime/current、HealthRuntime/current。删除一律 mv 进 ~/.Trash，
脚本里不出现 rm。

判「工作树已合并」用 git 对象/补丁身份，不看分支名，也不做逐文件语义比对：

1. `git merge-base --is-ancestor HEAD origin/main`（ff / merge commit 都成立）
2. 否则 `git cherry origin/main HEAD` 全部是 `-`（补丁已在 main，rebase 后仍认）

有未提交改动、或 status.json 里这条线还在 running/waiting_relay：不删，只报警。

Multica 工作区整目录回收不看父 issue 状态（`in_review` / `blocked` 照样可以收）。
只看这一份 run 自己交没交完，四条同时成立才 mv 进回收站：

1. 服务端 run 是终态：`completed` / `failed` / `cancelled`（`failed` 也算，常已干完）
2. 产物已经不在这个目录里独有：分支/HEAD 在目录外的 git 身份里，或已贴进票的评论/附件
3. 目录里 `git status --porcelain` 为空
4. 目录 mtime 超过 24 小时，且 `lsof +D` 显示没有进程在用

第 2 条核不过：不删，改告警（有产物没人捞比磁盘满严重）。构建产物
`node_modules` / `.next` / `.turbo` 仍按 12 小时剥，跟 Multica 自己的 GC 互补。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional



GIB = 1024**3
TERMINAL_LINE_STATES = frozenset({"done", "dead", "killed", "help"})
ACTIVE_LINE_STATES = frozenset({"running", "waiting_relay"})
ARTIFACT_DIR_NAMES = frozenset({".next", ".turbo", "node_modules"})
ARTIFACT_PREFIXES = (".next-",)
CACHE_IDLE_SECONDS = 7 * 24 * 3600
RUNNER_IDLE_SECONDS = 7 * 24 * 3600
MULTICA_TASK_TTL_SECONDS = 24 * 3600
MULTICA_ARTIFACT_TTL_SECONDS = 12 * 3600
MULTICA_ORPHAN_TTL_SECONDS = 72 * 3600
MULTICA_RUN_TERMINAL = frozenset({"completed", "failed", "cancelled"})
MULTICA_CLI_TIMEOUT = 20.0
MULTICA_LSOF_TIMEOUT = 15.0
WEBRUNTIME_BACKUP_KEEP = 1
TRASH_LABEL = "autoreclaim"
ROUND_BUDGET_SECONDS = 90.0
CACHE_VERSION = 1
CLI_PREFETCH_WORKERS = 8
_REPO_DATA_DIR_NAME = "data"
_HEALTH_DIR_NAME = "health"

GitRunner = Callable[[Sequence[str], Optional[Path]], subprocess.CompletedProcess[str]]
TrashFn = Callable[[Path, str], Path]
MulticaJsonFn = Callable[[Sequence[str]], Any]
InUseFn = Callable[[Path], bool]


class ReclaimError(RuntimeError):
    """Planning or apply failed in a way the caller should see."""


@dataclass
class ReclaimItem:
    category: str
    path: str
    action: str
    reason: str
    bytes: int = 0
    extra: dict[str, Any] | None = None


def _run_git(
    args: Sequence[str],
    cwd: Path | None,
    *,
    timeout: float = 30.0,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=None if cwd is None else str(cwd),
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _resolve_data_root() -> Path | None:
    env_value = os.environ.get("CORTEX_DATA_ROOT", "").strip()
    if env_value:
        return Path(env_value).expanduser().resolve()
    from cortex_sentinel.paths import projects

    for row in projects():
        raw = row.get("data_root")
        if isinstance(raw, str) and raw.strip():
            return Path(raw).expanduser().resolve()
    return None


def protected_trees(*, home: Path, data_root: Path | None) -> list[Path]:
    """Paths whose *contents* must never be reclaimed (user data / live runtimes)."""
    trees = [
        home / "CortexData",
        Path("/Volumes/CortexMirror"),
        home / "Library" / "Application Support" / "Cortex" / "WebRuntime" / "current",
        home / "Library" / "Application Support" / "Cortex" / "HealthRuntime" / "current",
    ]
    if data_root is not None:
        trees.append(data_root)
    return trees


def exact_protected(*, home: Path) -> list[Path]:
    """Refuse to trash these exact paths. Children are not automatically protected."""
    return [home.resolve(), Path("/"), Path("/Users"), Path("/Volumes")]


@dataclass(frozen=True)
class Protection:
    trees: tuple[Path, ...]
    exact: tuple[Path, ...]

    def blocks(self, path: Path) -> bool:
        resolved = path.resolve()
        for candidate in self.exact:
            try:
                if resolved == candidate.resolve():
                    return True
            except OSError:
                if resolved == candidate:
                    return True
        for prefix in self.trees:
            try:
                prefix_resolved = prefix.resolve()
            except OSError:
                prefix_resolved = prefix
            if resolved == prefix_resolved:
                return True
            try:
                resolved.relative_to(prefix_resolved)
                return True
            except ValueError:
                continue
        return False


def make_protection(*, home: Path, data_root: Path | None = None) -> Protection:
    return Protection(
        trees=tuple(protected_trees(home=home, data_root=data_root)),
        exact=tuple(exact_protected(home=home)),
    )


def _is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except (ValueError, OSError):
        return False


def dir_size_bytes(path: Path) -> int:
    total = 0
    try:
        if path.is_file() or path.is_symlink():
            return path.lstat().st_size
    except OSError:
        return 0
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in files:
            try:
                total += (Path(root) / name).lstat().st_size
            except OSError:
                continue
        # keep walking; skip huge well-known trees already counted via files
        _ = dirs
    return total


def last_touched_epoch(path: Path) -> float:
    """Prefer atime; if macOS never updated atime, fall back to mtime."""
    try:
        st = path.lstat()
    except OSError:
        return 0.0
    atime = float(st.st_atime)
    mtime = float(st.st_mtime)
    # noatime / APFS 常见：atime 停在创建时刻，比 mtime 还老。这时 atime 不能当「最后访问」。
    if atime + 1 < mtime:
        return mtime
    return max(atime, mtime)


def trash_to_finder(path: Path, label: str, *, home: Path) -> Path:
    """Move into ~/.Trash. Never rm. Mirrors scripts/trash_path.sh."""
    if not path.exists() and not path.is_symlink():
        raise ReclaimError(f"路径不存在: {path}")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    safe_label = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in label) or "item"
    dest_dir = home / ".Trash" / f"cortex-{safe_label}-{stamp}"
    dest_dir.mkdir(parents=True, exist_ok=True)
    target = dest_dir / path.name
    shutil.move(str(path), str(target))
    return target


def parse_worktree_porcelain(text: str) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in (text or "").splitlines():
        if not line.strip():
            if current:
                rows.append(current)
                current = {}
            continue
        if line.startswith("worktree "):
            if current:
                rows.append(current)
            current = {"worktree": line.split(" ", 1)[1]}
        elif line.startswith("HEAD "):
            current["head"] = line.split(" ", 1)[1]
        elif line.startswith("branch "):
            current["branch"] = line.split(" ", 1)[1]
        elif line == "bare":
            current["bare"] = "1"
        elif line == "detached":
            current["detached"] = "1"
        elif line.startswith("locked"):
            current["locked"] = line
    if current:
        rows.append(current)
    return rows


def merged_into_main(
    repo: Path,
    commit: str,
    *,
    main_ref: str = "refs/remotes/origin/main",
    git: GitRunner | None = None,
) -> tuple[bool, str]:
    """Does *commit* already live on main, by object/patch identity.

    Never look at branch names. ``HEAD == origin/main`` (fresh clone, no unique
    commits) is *not* merged work — that is ``no-unique-commits``.
    """
    run = git or (lambda args, cwd: _run_git(args, cwd))
    cherry = run(["cherry", main_ref, commit], repo)
    if cherry.returncode != 0:
        return False, f"cherry-failed:{cherry.stderr.strip() or cherry.returncode}"
    lines = [line for line in cherry.stdout.splitlines() if line.strip()]
    plus = [line for line in lines if line.startswith("+")]
    if plus:
        return False, f"unique-patches:{len(plus)}"
    minus = [line for line in lines if line.startswith("-")]
    if minus:
        return True, "cherry-equivalent"

    ancestor = run(["merge-base", "--is-ancestor", commit, main_ref], repo)
    main_sha = run(["rev-parse", main_ref], repo)
    commit_sha = run(["rev-parse", commit], repo)
    on_main = (
        ancestor.returncode == 0
        and main_sha.returncode == 0
        and commit_sha.returncode == 0
        and main_sha.stdout.strip() == commit_sha.stdout.strip()
    )
    if ancestor.returncode == 0 and not on_main:
        # 工作树停在 main 历史里更早的提交：要么功能分支已合入，要么只是落后。
        # 调用方对这种再加「最近还在动就不收」。
        return True, "ancestor-of-main"
    return False, "no-unique-commits"


def worktree_dirty(worktree: Path, *, git: GitRunner | None = None) -> str:
    run = git or (lambda args, cwd: _run_git(args, cwd))
    result = run(["status", "--porcelain"], worktree)
    if result.returncode != 0:
        return f"status-failed:{result.stderr.strip() or result.returncode}"
    return result.stdout.strip()


def load_active_workdirs(logs_dirs: Sequence[Path]) -> set[str]:
    active: set[str] = set()
    for logs_dir in logs_dirs:
        if not logs_dir.is_dir():
            continue
        for pattern in ("codex-*.status.json", "grok-*.status.json", "*-babysitter*.status.json"):
            for path in logs_dir.glob(pattern):
                try:
                    payload = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError, UnicodeError):
                    continue
                if not isinstance(payload, dict):
                    continue
                state = str(payload.get("state") or "")
                if state not in ACTIVE_LINE_STATES:
                    continue
                workdir = str(payload.get("workdir") or payload.get("cd") or "").strip()
                if workdir:
                    active.add(str(Path(workdir).expanduser()))
    return active


def _item(
    category: str,
    path: Path,
    action: str,
    reason: str,
    *,
    extra: dict[str, Any] | None = None,
) -> ReclaimItem:
    # 目录体积不是四条回收判据之一。为算它去 walk 整棵 28G 树，
    # 一轮会自己把 10 分钟间隔吃掉。需要体积时再显式 dir_size_bytes。
    return ReclaimItem(
        category=category,
        path=str(path),
        action=action,
        reason=reason,
        bytes=0,
        extra=extra,
    )


def plan_worktrees(
    repo: Path,
    *,
    main_ref: str,
    active_workdirs: set[str],
    protection: Protection,
    git: GitRunner | None = None,
    skip_paths: Sequence[Path] = (),
) -> list[ReclaimItem]:
    run = git or (lambda args, cwd: _run_git(args, cwd))
    listed = run(["worktree", "list", "--porcelain"], repo)
    if listed.returncode != 0:
        return [
            ReclaimItem(
                category="worktree",
                path=str(repo),
                action="alert",
                reason=f"worktree-list-failed:{listed.stderr.strip() or listed.returncode}",
            )
        ]
    items: list[ReclaimItem] = []
    rows = parse_worktree_porcelain(listed.stdout)
    skip = {str(path.resolve()) for path in skip_paths}
    for index, row in enumerate(rows):
        raw = row.get("worktree")
        if not raw:
            continue
        path = Path(raw)
        if index == 0:
            continue  # 主仓
        if row.get("bare") == "1":
            continue
        if str(path.resolve()) in skip:
            items.append(_item("worktree", path, "keep", "current-workdir"))
            continue
        if protection.blocks(path):
            items.append(_item("worktree", path, "keep", "protected"))
            continue
        if row.get("locked"):
            items.append(_item("worktree", path, "alert", "locked"))
            continue
        if any(str(path) == active or str(path.resolve()) == str(Path(active).expanduser().resolve())
               for active in active_workdirs):
            items.append(_item("worktree", path, "alert", "line-still-running"))
            continue
        dirty = worktree_dirty(path, git=git)
        if dirty:
            items.append(
                _item(
                    "worktree",
                    path,
                    "alert",
                    "uncommitted-changes",
                    extra={"dirty": dirty[:500]},
                )
            )
            continue
        head = row.get("head") or ""
        if not head:
            items.append(_item("worktree", path, "alert", "missing-head"))
            continue
        merged, why = merged_into_main(repo, head, main_ref=main_ref, git=git)
        if not merged:
            items.append(_item("worktree", path, "keep", why, extra={"head": head, "branch": row.get("branch")}))
            continue
        items.append(
            _item(
                "worktree",
                path,
                "trash",
                why,
                extra={"head": head, "branch": row.get("branch")},
            )
        )
    return items


def plan_webruntime_backups(backups_root: Path, *, keep: int = WEBRUNTIME_BACKUP_KEEP) -> list[ReclaimItem]:
    if not backups_root.is_dir():
        return []
    dirs = sorted(
        [path for path in backups_root.iterdir() if path.is_dir()],
        key=lambda path: path.name,
        reverse=True,
    )
    items: list[ReclaimItem] = []
    for index, path in enumerate(dirs):
        if index < keep:
            items.append(_item("packaging", path, "keep", f"newest-backup-{index + 1}"))
        else:
            items.append(_item("packaging", path, "trash", f"previous-webruntime-backup keep={keep}"))
    staging_parent = backups_root.parent
    if staging_parent.is_dir():
        for path in staging_parent.iterdir():
            if path.name.startswith(".staging-") and path.is_dir():
                items.append(_item("packaging", path, "trash", "webruntime-failed-staging"))
    return items


_DIST_STEM_PREFIXES = ("Cortex-Core-", "cortex-mac-core-")
_DIST_SUFFIXES = (
    ".app-manifest.json",
    ".build.json",
    ".zip",
    ".app",
)


def dist_family_stem(name: str) -> str | None:
    if not any(name.startswith(prefix) for prefix in _DIST_STEM_PREFIXES):
        return None
    for suffix in _DIST_SUFFIXES:
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def plan_dist_previous(
    dist_dir: Path,
    *,
    keep_stem: str | None = None,
    keep_latest: int = 1,
) -> list[ReclaimItem]:
    if not dist_dir.is_dir():
        return []
    items: list[ReclaimItem] = []
    groups: dict[str, list[Path]] = {}
    for path in dist_dir.iterdir():
        name = path.name
        if name in {".DS_Store"}:
            continue
        if name == "Cortex.app":
            items.append(_item("packaging", path, "keep", "current-app-slot"))
            continue
        stem = dist_family_stem(name)
        if stem is None:
            continue
        groups.setdefault(stem, []).append(path)

    keep_stems: set[str] = set()
    if keep_stem:
        keep_stems.add(keep_stem)
    elif keep_latest > 0:
        keep_stems.update(sorted(groups, reverse=True)[:keep_latest])

    for stem, paths in groups.items():
        if stem in keep_stems:
            reason = "current-artifact-stem" if keep_stem == stem else "newest-dist-stem"
            action = "keep"
        else:
            reason = "previous-packaging-artifact"
            action = "trash"
        for path in paths:
            items.append(_item("packaging", path, action, reason))
    return items


def _is_artifact_dir(path: Path) -> bool:
    if path.name in ARTIFACT_DIR_NAMES:
        return True
    return any(path.name.startswith(prefix) for prefix in ARTIFACT_PREFIXES)


def plan_build_caches(
    roots: Sequence[Path],
    *,
    now: datetime,
    idle_seconds: int,
    protection: Protection,
    skip_under: Sequence[Path] = (),
) -> list[ReclaimItem]:
    cutoff = now.timestamp() - idle_seconds
    items: list[ReclaimItem] = []
    for root in roots:
        if not root.is_dir():
            continue
        for dirpath, dirnames, _files in os.walk(root, followlinks=False):
            current = Path(dirpath)
            if current.name in {".git", ".Trash"}:
                dirnames[:] = []
                continue
            if protection.blocks(current) or any(_is_under(current, skip) for skip in skip_under):
                dirnames[:] = []
                continue
            # 不要走进要收的目录里面再列孙目录
            drop: list[str] = []
            for name in list(dirnames):
                child = current / name
                if not _is_artifact_dir(child):
                    continue
                drop.append(name)
                touched = last_touched_epoch(child)
                if touched >= cutoff:
                    items.append(_item("cache", child, "keep", "recently-touched"))
                else:
                    items.append(_item("cache", child, "trash", "idle-build-cache"))
            for name in drop:
                dirnames.remove(name)
    return items


def _read_json_object(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _read_gc_meta(task_dir: Path) -> dict[str, Any] | None:
    return _read_json_object(task_dir / ".gc_meta.json")


def _parse_iso8601(value: str) -> datetime | None:
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc)


def _multica_bin() -> str | None:
    found = shutil.which("multica")
    if found:
        return found
    fallback = Path.home() / ".local" / "bin" / "multica"
    return str(fallback) if fallback.exists() else None


def _default_multica_json(args: Sequence[str]) -> Any:
    binary = _multica_bin()
    if binary is None:
        raise ReclaimError("multica-cli-unavailable")
    completed = subprocess.run(
        [binary, *args],
        capture_output=True,
        text=True,
        timeout=MULTICA_CLI_TIMEOUT,
        check=False,
    )
    if completed.returncode != 0:
        stderr = (completed.stderr or "").strip()
        raise ReclaimError(f"multica-cli-failed:{stderr or completed.returncode}")
    stdout = (completed.stdout or "").strip()
    if not stdout:
        return None
    try:
        return json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise ReclaimError("multica-cli-invalid-json") from exc


def _json_dicts(payload: Any, *keys: str) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if not isinstance(payload, dict):
        return []
    if not keys:
        return [payload]
    for key in keys:
        nested = payload.get(key)
        if isinstance(nested, list):
            return [item for item in nested if isinstance(item, dict)]
        if isinstance(nested, dict):
            nodes = nested.get("nodes")
            if isinstance(nodes, list):
                return [item for item in nodes if isinstance(item, dict)]
            return [nested]
    return []


def match_multica_run(runs: Sequence[dict[str, Any]], task_dir_name: str) -> dict[str, Any] | None:
    """Match a task directory name (usually the 8-char run prefix) to a server run."""
    needle = task_dir_name.strip().lower().replace("-", "")
    if not needle:
        return None
    for run in runs:
        run_id = str(run.get("id") or "").strip().lower().replace("-", "")
        if run_id and (run_id == needle or run_id.startswith(needle) or needle.startswith(run_id)):
            return run
    return None


def run_is_terminal(status: str) -> bool:
    return status.strip().lower() in MULTICA_RUN_TERMINAL


def directory_mtime_age(path: Path, now: datetime) -> float:
    try:
        return now.timestamp() - float(path.lstat().st_mtime)
    except OSError:
        return 0.0


def directory_in_use(path: Path, *, timeout: float = MULTICA_LSOF_TIMEOUT) -> bool:
    """True if lsof +D sees open files, or the probe itself cannot be trusted."""
    try:
        completed = subprocess.run(
            ["lsof", "+D", str(path)],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return True
    except OSError:
        return True
    return completed.returncode == 0


def _first_text(payload: dict[str, Any], *keys: str) -> str:
    for key in keys:
        value = payload.get(key)
        if value is None:
            continue
        text = str(value).strip()
        if text:
            return text
    return ""


def _task_identity(task_dir: Path, meta: dict[str, Any] | None) -> dict[str, str]:
    identity = {"issue_id": "", "issue_identifier": "", "task_id": ""}
    sources: list[dict[str, Any]] = []
    if meta:
        sources.append(meta)
    for relative in (
        Path("workdir") / ".multica" / "daemon_task_context.json",
        Path(".multica") / "daemon_task_context.json",
        Path("workdir") / ".agent_context" / "task_context.json",
    ):
        extra = _read_json_object(task_dir / relative)
        if extra:
            sources.append(extra)
    for payload in sources:
        if not identity["issue_id"]:
            identity["issue_id"] = _first_text(payload, "issue_id", "issueId", "issue_uuid")
        if not identity["issue_identifier"]:
            identity["issue_identifier"] = _first_text(
                payload, "issue_identifier", "issue_key", "identifier", "issue_ref"
            )
        if not identity["task_id"]:
            identity["task_id"] = _first_text(payload, "task_id", "run_id", "taskId")
    if not identity["task_id"]:
        identity["task_id"] = task_dir.name
    return identity


def _git_workdirs(task_dir: Path) -> list[Path]:
    found: list[Path] = []
    for dirpath, dirnames, _files in os.walk(task_dir, followlinks=False):
        current = Path(dirpath)
        try:
            depth = len(current.relative_to(task_dir).parts)
        except ValueError:
            dirnames[:] = []
            continue
        if depth > 4:
            dirnames[:] = []
            continue
        dirnames[:] = [
            name
            for name in dirnames
            if name not in {".git", "node_modules", ".next", ".turbo", ".Trash", "codex-home"}
        ]
        if (current / ".git").exists():
            found.append(current)
            dirnames[:] = []
    return found


def _remote_url_outside(url: str, task_dir: Path) -> bool:
    text = url.strip()
    if not text:
        return False
    if "://" in text and not text.startswith("file:"):
        return True
    if text.startswith("git@") or text.startswith("ssh://"):
        return True
    raw = text[7:] if text.startswith("file://") else text
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        candidate = (task_dir / candidate)
    try:
        resolved = candidate.resolve()
    except OSError:
        return True
    return not _is_under(resolved, task_dir)


def head_published_outside(
    repo: Path,
    task_dir: Path,
    *,
    git: GitRunner | None = None,
) -> tuple[bool, str]:
    """HEAD's objects/refs live outside this task dir, or a remote already has HEAD."""
    run = git or (lambda args, cwd: _run_git(args, cwd))
    common = run(["rev-parse", "--git-common-dir"], repo)
    if common.returncode == 0 and common.stdout.strip():
        common_path = Path(common.stdout.strip())
        if not common_path.is_absolute():
            common_path = repo / common_path
        try:
            resolved = common_path.resolve()
        except OSError:
            resolved = common_path
        if not _is_under(resolved, task_dir):
            return True, "git-common-dir-outside"
    head = run(["rev-parse", "HEAD"], repo)
    if head.returncode != 0 or not head.stdout.strip():
        return False, "head-missing"
    sha = head.stdout.strip()
    remotes = run(["remote", "-v"], repo)
    remote_urls: dict[str, str] = {}
    for line in remotes.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            remote_urls.setdefault(parts[0], parts[1])
    contained = run(["branch", "-r", "--contains", sha], repo)
    if contained.returncode == 0:
        for line in contained.stdout.splitlines():
            ref = line.strip()
            if not ref:
                continue
            if "->" in ref:
                ref = ref.split("->", 1)[1].strip()
            remote_name = ref.split("/", 1)[0]
            url = remote_urls.get(remote_name, "")
            if url and _remote_url_outside(url, task_dir):
                return True, f"remote-contains:{ref}"
    return False, "head-not-on-external-remote"


def _nonempty_tree(root: Path) -> bool:
    if not root.is_dir():
        return False
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [
            name for name in dirnames if name not in {".git", "node_modules", ".next", ".turbo"}
        ]
        for name in filenames:
            try:
                if (Path(dirpath) / name).lstat().st_size > 0:
                    return True
            except OSError:
                continue
    return False


def _local_unique_kinds(
    task_dir: Path,
    *,
    git: GitRunner | None = None,
) -> list[str]:
    kinds: list[str] = []
    dirty_any = False
    unpublished_any = False
    for repo in _git_workdirs(task_dir):
        dirty = worktree_dirty(repo, git=git)
        if dirty:
            dirty_any = True
            continue
        published, _why = head_published_outside(repo, task_dir, git=git)
        if not published:
            unpublished_any = True
    if dirty_any:
        kinds.append("uncommitted-changes")
    if unpublished_any:
        kinds.append("unpushed-commits")
    if _nonempty_tree(task_dir / "output") or _nonempty_tree(task_dir / "logs"):
        kinds.append("local-output")
    if _nonempty_tree(task_dir / ".artifacts"):
        kinds.append("local-artifacts")
    if _nonempty_tree(task_dir / "codex-home" / "sessions"):
        kinds.append("local-sessions")
    return kinds


def _comment_moment(row: dict[str, Any]) -> datetime | None:
    return _parse_iso8601(
        _first_text(row, "created_at", "updated_at", "inserted_at", "timestamp")
    )


def _comment_body(row: dict[str, Any]) -> str:
    return _first_text(row, "content", "body", "text", "summary")


def issue_has_posted_artifacts(
    issue: dict[str, Any] | None,
    comments: Sequence[dict[str, Any]],
    *,
    since: datetime | None,
) -> tuple[bool, str]:
    attachments = _json_dicts(issue or {}, "attachments")
    if attachments:
        return True, "issue-attachments"
    for row in comments:
        nested = _json_dicts(row, "attachments")
        if nested:
            return True, "comment-attachments"
        body = _comment_body(row)
        if not body:
            continue
        moment = _comment_moment(row)
        if since is None or moment is None or moment >= since:
            return True, "issue-comments"
    return False, "no-issue-artifacts"


class _MulticaLookup:
    def __init__(self, fn: MulticaJsonFn | None) -> None:
        self._fn = fn
        self._runs: dict[str, list[dict[str, Any]] | None] = {}
        self._issue: dict[str, dict[str, Any] | None] = {}
        self._comments: dict[str, list[dict[str, Any]] | None] = {}
        self._lock = threading.Lock()
        self.unavailable = False

    def _call(self, args: Sequence[str]) -> Any:
        try:
            if self._fn is None:
                return _default_multica_json(args)
            return self._fn(args)
        except ReclaimError as exc:
            if "unavailable" in str(exc):
                self.unavailable = True
            raise

    def load_persisted_runs(self, blob: dict[str, Any]) -> None:
        for issue_id, payload in blob.items():
            if not isinstance(payload, dict):
                continue
            rows = payload.get("rows")
            if not isinstance(rows, list) or not payload.get("all_terminal"):
                continue
            self._runs[str(issue_id)] = [row for row in rows if isinstance(row, dict)]

    def load_persisted_issues(self, blob: dict[str, Any]) -> None:
        for issue_id, payload in blob.items():
            if not isinstance(payload, dict):
                continue
            issue = payload.get("issue")
            comments = payload.get("comments")
            if isinstance(issue, dict):
                self._issue[str(issue_id)] = issue
            if isinstance(comments, list):
                self._comments[str(issue_id)] = [row for row in comments if isinstance(row, dict)]

    def dump_runs(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for issue_id, rows in self._runs.items():
            if not rows:
                continue
            statuses = [str(row.get("status") or "").strip().lower() for row in rows]
            if statuses and all(run_is_terminal(status) for status in statuses):
                out[issue_id] = {"rows": rows, "all_terminal": True}
        return out

    def dump_issues(self) -> dict[str, Any]:
        out: dict[str, Any] = {}
        for issue_id, issue in self._issue.items():
            comments = self._comments.get(issue_id)
            if issue is None and not comments:
                continue
            out[issue_id] = {"issue": issue, "comments": comments or []}
        return out

    def runs(self, issue_id: str) -> list[dict[str, Any]] | None:
        with self._lock:
            if issue_id in self._runs:
                return self._runs[issue_id]
        try:
            payload = self._call(
                ["issue", "runs", issue_id, "--full-id", "--output", "json"]
            )
        except (ReclaimError, OSError, subprocess.TimeoutExpired):
            with self._lock:
                self._runs[issue_id] = None
            return None
        rows = _json_dicts(payload, "runs", "data", "items")
        with self._lock:
            self._runs[issue_id] = rows
        return rows

    def issue(self, issue_id: str) -> dict[str, Any] | None:
        with self._lock:
            if issue_id in self._issue:
                return self._issue[issue_id]
        try:
            payload = self._call(["issue", "get", issue_id, "--output", "json"])
        except (ReclaimError, OSError, subprocess.TimeoutExpired):
            with self._lock:
                self._issue[issue_id] = None
            return None
        rows = _json_dicts(payload, "issue", "data")
        if rows:
            issue = rows[0]
        elif isinstance(payload, dict) and (payload.get("id") or payload.get("identifier")):
            issue = payload
        else:
            issue = None
        with self._lock:
            self._issue[issue_id] = issue
        return issue

    def comments(self, issue_id: str) -> list[dict[str, Any]] | None:
        with self._lock:
            if issue_id in self._comments:
                return self._comments[issue_id]
        try:
            payload = self._call(
                ["issue", "comment", "list", issue_id, "--output", "json"]
            )
        except (ReclaimError, OSError, subprocess.TimeoutExpired):
            with self._lock:
                self._comments[issue_id] = None
            return None
        rows = _json_dicts(payload, "comments", "data", "items")
        with self._lock:
            self._comments[issue_id] = rows
        return rows

    def refresh_comments(self, issue_id: str) -> list[dict[str, Any]] | None:
        with self._lock:
            self._comments.pop(issue_id, None)
        return self.comments(issue_id)


def _artifact_items(task_dir: Path) -> list[ReclaimItem]:
    items: list[ReclaimItem] = []
    for dirpath, dirnames, _files in os.walk(task_dir, followlinks=False):
        current = Path(dirpath)
        if current.name in {".git", ".Trash"}:
            dirnames[:] = []
            continue
        drop: list[str] = []
        for name in list(dirnames):
            child = current / name
            if _is_artifact_dir(child):
                drop.append(name)
                items.append(_item("multica", child, "trash", "artifact-past-ttl"))
        for name in drop:
            dirnames.remove(name)
    return items


def _decision_extra(
    *,
    identity: dict[str, str],
    run: dict[str, Any] | None,
    run_status: str,
    artifacts: str,
    git_state: str,
    mtime_age: float,
    in_use: bool | None,
    unique: Sequence[str] = (),
) -> dict[str, Any]:
    run_id = ""
    if run:
        run_id = str(run.get("id") or "").strip()
    checks = {
        "run_terminal": run_is_terminal(run_status),
        "artifacts_salvaged": artifacts,
        "git_clean": git_state == "clean",
        "mtime_age_hours": round(mtime_age / 3600.0, 3),
        "in_use": in_use,
    }
    decision = (
        f"run={run_status or 'unknown'}; artifacts={artifacts}; git={git_state}; "
        f"mtime={mtime_age / 3600.0:.1f}h; lsof={'in-use' if in_use else 'idle' if in_use is False else 'unchecked'}"
    )
    extra: dict[str, Any] = {
        "issue_id": identity.get("issue_id") or "",
        "issue": identity.get("issue_identifier") or "",
        "run_id": run_id or identity.get("task_id") or "",
        "run_status": run_status,
        "decision": decision,
        "checks": checks,
    }
    if unique:
        extra["unique"] = list(unique)
    return extra


def _plan_one_multica_task(
    task_dir: Path,
    *,
    now: datetime,
    task_ttl: int,
    artifact_ttl: int,
    orphan_ttl: int,
    git: GitRunner | None,
    lookup: _MulticaLookup,
    in_use_fn: InUseFn | None,
) -> list[ReclaimItem]:
    meta = _read_gc_meta(task_dir)
    identity = _task_identity(task_dir, meta)
    mtime_age = directory_mtime_age(task_dir, now)
    completed_at = _parse_iso8601(str((meta or {}).get("completed_at") or ""))
    completed_age = (now - completed_at).total_seconds() if completed_at else None

    def with_artifacts(primary: ReclaimItem) -> list[ReclaimItem]:
        rows = [primary]
        if completed_age is not None and completed_age >= artifact_ttl:
            artifacts = _artifact_items(task_dir)
            if artifacts:
                rows.extend(artifacts)
        return rows

    extra_base = {
        "issue_id": identity["issue_id"],
        "issue": identity["issue_identifier"],
        "run_id": identity["task_id"],
    }

    if not identity["issue_id"]:
        reason = "issue-id-missing"
        if mtime_age >= task_ttl:
            return [
                _item(
                    "multica",
                    task_dir,
                    "alert",
                    reason,
                    extra={**extra_base, "decision": "cannot-check-run-or-salvage; missing issue_id"},
                )
            ]
        if meta is None:
            keep_reason = "orphan-within-ttl" if mtime_age < orphan_ttl else "orphan-unidentified"
            return [_item("multica", task_dir, "keep", keep_reason, extra=extra_base)]
        keep = _item("multica", task_dir, "keep", reason, extra=extra_base)
        if completed_age is not None and completed_age >= artifact_ttl:
            artifacts = _artifact_items(task_dir)
            return [keep, *artifacts] if artifacts else [keep]
        return [keep]

    try:
        runs = lookup.runs(identity["issue_id"])
    except Exception:
        runs = None
    if runs is None:
        reason = "run-status-unknown"
        action = "alert" if mtime_age >= task_ttl else "keep"
        return [
            _item(
                "multica",
                task_dir,
                action,
                reason,
                extra={**extra_base, "decision": "multica issue runs lookup failed"},
            )
        ]

    run = match_multica_run(runs, task_dir.name)
    if run is None and identity["task_id"] != task_dir.name:
        run = match_multica_run(runs, identity["task_id"])
    if run is None:
        reason = "run-not-matched"
        action = "alert" if mtime_age >= task_ttl else "keep"
        return [
            _item(
                "multica",
                task_dir,
                action,
                reason,
                extra={**extra_base, "decision": "directory name did not match any issue run"},
            )
        ]

    run_status = str(run.get("status") or "").strip().lower()
    extra_base["run_id"] = str(run.get("id") or identity["task_id"])
    extra_base["run_status"] = run_status
    if not run_is_terminal(run_status):
        return [
            _item(
                "multica",
                task_dir,
                "keep",
                f"run-not-terminal:{run_status or 'empty'}",
                extra=_decision_extra(
                    identity=identity,
                    run=run,
                    run_status=run_status,
                    artifacts="unchecked",
                    git_state="unchecked",
                    mtime_age=mtime_age,
                    in_use=None,
                ),
            )
        ]

    issue = lookup.issue(identity["issue_id"])
    if issue:
        identifier = _first_text(issue, "identifier", "key")
        if identifier:
            identity["issue_identifier"] = identifier
    comments = lookup.comments(identity["issue_id"]) or []
    since = _parse_iso8601(str(run.get("started_at") or run.get("created_at") or "")) or completed_at
    posted, posted_why = issue_has_posted_artifacts(issue, comments, since=since)
    unique = _local_unique_kinds(task_dir, git=git)
    git_dirty = "uncommitted-changes" in unique
    unpublished = "unpushed-commits" in unique
    leftover_files = [
        kind for kind in unique if kind in {"local-output", "local-artifacts", "local-sessions"}
    ]
    if git_dirty:
        git_state = "dirty"
    elif unpublished:
        git_state = "unpushed"
    else:
        git_state = "clean"

    # 未提交 / 未推的提交 / 只存在于本目录的 output·附件·session，
    # 只要还没贴到票上，就一律算「产物只在这个目录里」。git 停在 main
    # 救不了只写在 rollout 里的报告。
    if not unique:
        artifacts_why = "nothing-unique"
        salvaged = True
    elif posted:
        artifacts_why = posted_why
        salvaged = True
    elif unpublished:
        artifacts_why = "unpushed-commits"
        salvaged = False
    elif leftover_files:
        artifacts_why = ",".join(leftover_files)
        salvaged = False
    elif git_dirty:
        artifacts_why = "uncommitted-changes"
        salvaged = False
    else:
        artifacts_why = "head-published"
        salvaged = True

    extra = _decision_extra(
        identity=identity,
        run=run,
        run_status=run_status,
        artifacts=artifacts_why,
        git_state=git_state,
        mtime_age=mtime_age,
        in_use=None,
        unique=unique,
    )

    if git_dirty:
        return with_artifacts(
            _item("multica", task_dir, "alert", "uncommitted-changes", extra=extra)
        )
    if not salvaged:
        return with_artifacts(
            _item("multica", task_dir, "alert", "unsalvaged-artifacts", extra=extra)
        )
    if mtime_age < task_ttl:
        keep_reason = (
            "mtime-within-ttl"
            if (completed_age is None or completed_age >= artifact_ttl)
            else "completed-within-artifact-ttl"
        )
        keep = _item("multica", task_dir, "keep", keep_reason, extra=extra)
        if completed_age is not None and completed_age >= artifact_ttl:
            artifacts = _artifact_items(task_dir)
            return [keep, *artifacts] if artifacts else [keep]
        return [keep]

    busy_fn = in_use_fn or directory_in_use
    busy = bool(busy_fn(task_dir))
    extra = _decision_extra(
        identity=identity,
        run=run,
        run_status=run_status,
        artifacts=artifacts_why,
        git_state=git_state,
        mtime_age=mtime_age,
        in_use=busy,
        unique=unique,
    )
    if busy:
        return with_artifacts(
            _item("multica", task_dir, "keep", "directory-in-use", extra=extra)
        )
    return [
        _item(
            "multica",
            task_dir,
            "trash",
            f"run-terminal-salvaged-idle:{run_status}",
            extra=extra,
        )
    ]


def _item_from_dict(payload: dict[str, Any]) -> ReclaimItem:
    extra = payload.get("extra")
    return ReclaimItem(
        category=str(payload.get("category") or "multica"),
        path=str(payload.get("path") or ""),
        action=str(payload.get("action") or "keep"),
        reason=str(payload.get("reason") or ""),
        bytes=int(payload.get("bytes") or 0),
        extra=extra if isinstance(extra, dict) else None,
    )


def _aux_paths_for(task_dir: Path, git_dirs: Sequence[Path] = ()) -> list[str]:
    paths = [
        task_dir / ".gc_meta.json",
        task_dir / "output",
        task_dir / "logs",
        task_dir / ".artifacts",
        task_dir / "codex-home" / "sessions",
        task_dir / "workdir",
    ]
    paths.extend(repo / ".git" for repo in git_dirs)
    if not git_dirs:
        paths.extend(
            [
                task_dir / "workdir" / ".git",
                task_dir / "workdir" / "repo" / ".git",
            ]
        )
    return [str(path) for path in paths]


def _record_stat(fingerprint: dict[str, list[int]], path: Path) -> None:
    try:
        st = path.lstat()
        fingerprint[str(path)] = [int(st.st_mtime_ns), int(st.st_ino)]
    except OSError:
        fingerprint[str(path)] = [0, 0]


FINGERPRINT_SKIP_DIRS = frozenset(
    {".git", "node_modules", ".next", ".turbo", ".Trash"}
)
FINGERPRINT_FILE_CAP = 400


def _walk_fingerprint(
    fingerprint: dict[str, list[int]],
    root: Path,
    *,
    limit: int,
) -> int:
    counted = 0
    try:
        walker = os.walk(root, followlinks=False)
    except OSError:
        _record_stat(fingerprint, root)
        return 0
    for dirpath, dirnames, filenames in walker:
        dirnames[:] = [name for name in dirnames if name not in FINGERPRINT_SKIP_DIRS]
        current = Path(dirpath)
        _record_stat(fingerprint, current)
        for name in filenames:
            _record_stat(fingerprint, current / name)
            counted += 1
            if counted >= limit:
                fingerprint[f"{root}#overflow"] = [counted, 1]
                dirnames[:] = []
                return counted
    fingerprint[f"{root}#count"] = [counted, 0]
    return counted


def _task_fingerprint(task_dir: Path, aux: Sequence[str]) -> dict[str, list[int]]:
    fingerprint: dict[str, list[int]] = {}
    _record_stat(fingerprint, task_dir)
    for raw in aux:
        path = Path(raw)
        if path.name == ".git":
            _record_stat(fingerprint, path)
            _record_stat(fingerprint, path / "HEAD")
            _record_stat(fingerprint, path / "index")
            refs = path / "refs"
            if refs.is_dir():
                _walk_fingerprint(fingerprint, refs, limit=80)
            continue
        if path.is_dir():
            _walk_fingerprint(fingerprint, path, limit=FINGERPRINT_FILE_CAP)
        else:
            _record_stat(fingerprint, path)
    return fingerprint


def empty_round_state() -> dict[str, Any]:
    return {
        "version": CACHE_VERSION,
        "resume_after": "",
        "runs": {},
        "issues": {},
        "tasks": {},
    }


def load_round_state(path: Path | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return empty_round_state()
    payload = _read_json_object(path)
    if not payload or int(payload.get("version") or 0) != CACHE_VERSION:
        return empty_round_state()
    payload.setdefault("resume_after", "")
    payload.setdefault("runs", {})
    payload.setdefault("issues", {})
    payload.setdefault("tasks", {})
    return payload


def save_round_state(path: Path | None, state: dict[str, Any]) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(state, ensure_ascii=False)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(encoded + "\n", encoding="utf-8")
    tmp.replace(path)


def rotate_task_dirs(paths: Sequence[Path], resume_after: str) -> list[Path]:
    ordered = list(paths)
    if not resume_after or not ordered:
        return ordered
    names = [str(path) for path in ordered]
    if resume_after not in names:
        return ordered
    index = names.index(resume_after) + 1
    if index >= len(ordered):
        return ordered
    return ordered[index:] + ordered[:index]


def _prefetch_issue_runs(
    lookup: _MulticaLookup,
    issue_ids: Sequence[str],
    *,
    workers: int,
) -> None:
    unique = [issue_id for issue_id in dict.fromkeys(issue_ids) if issue_id]
    if not unique:
        return
    pool_size = max(1, min(int(workers), len(unique)))
    if pool_size == 1:
        for issue_id in unique:
            lookup.runs(issue_id)
        return
    with ThreadPoolExecutor(max_workers=pool_size) as pool:
        list(pool.map(lookup.runs, unique))


def _cache_reusable_without_cli(
    entry: dict[str, Any] | None,
    task_dir: Path,
    now: datetime,
) -> bool:
    if not isinstance(entry, dict):
        return False
    fingerprint = _task_fingerprint(task_dir, entry.get("aux_paths") or [])
    recheck_at = entry.get("recheck_at")
    still_fresh = fingerprint == entry.get("fingerprint") and (
        recheck_at is None or now.timestamp() < float(recheck_at)
    )
    return bool(
        still_fresh
        and entry.get("run_terminal")
        and not entry.get("needs_comments")
    )


def _prefetch_issue_details(
    lookup: _MulticaLookup,
    issue_ids: Sequence[str],
    *,
    workers: int,
) -> None:
    unique = [issue_id for issue_id in dict.fromkeys(issue_ids) if issue_id]
    if not unique:
        return

    def load(issue_id: str) -> None:
        lookup.issue(issue_id)
        lookup.comments(issue_id)

    pool_size = max(1, min(int(workers), len(unique)))
    if pool_size == 1:
        for issue_id in unique:
            load(issue_id)
        return
    with ThreadPoolExecutor(max_workers=pool_size) as pool:
        list(pool.map(load, unique))


def _issue_id_for_task(task_dir: Path, entry: dict[str, Any] | None) -> str:
    if isinstance(entry, dict):
        cached = str(entry.get("issue_id") or "")
        if cached:
            return cached
    return _task_identity(task_dir, _read_gc_meta(task_dir)).get("issue_id") or ""


def _recheck_at_for(
    primary: ReclaimItem,
    task_dir: Path,
    *,
    now: datetime,
    task_ttl: int,
    artifact_ttl: int,
    orphan_ttl: int,
) -> float | None:
    if primary.action != "keep":
        return None
    age = directory_mtime_age(task_dir, now)
    if primary.reason == "mtime-within-ttl":
        remaining = task_ttl - age
    elif primary.reason == "orphan-within-ttl":
        remaining = orphan_ttl - age
    elif primary.reason == "completed-within-artifact-ttl":
        remaining = artifact_ttl
    else:
        return None
    if remaining <= 0:
        return now.timestamp()
    return now.timestamp() + remaining


def _cache_entry_from_items(
    task_dir: Path,
    rows: Sequence[ReclaimItem],
    *,
    now: datetime,
    task_ttl: int,
    artifact_ttl: int,
    orphan_ttl: int,
) -> dict[str, Any]:
    primary = rows[0]
    extra = primary.extra or {}
    run_status = str(extra.get("run_status") or "")
    need_git = run_is_terminal(run_status) and primary.reason not in {
        "protected",
        "bare-repo-cache",
        "issue-id-missing",
        "run-status-unknown",
        "run-not-matched",
    }
    git_dirs = _git_workdirs(task_dir) if need_git else []
    aux = _aux_paths_for(task_dir, git_dirs)
    return {
        "fingerprint": _task_fingerprint(task_dir, aux),
        "aux_paths": aux,
        "items": [asdict(item) for item in rows],
        "run_status": run_status,
        "run_terminal": run_is_terminal(run_status),
        "issue_id": str(extra.get("issue_id") or ""),
        "recheck_at": _recheck_at_for(
            primary,
            task_dir,
            now=now,
            task_ttl=task_ttl,
            artifact_ttl=artifact_ttl,
            orphan_ttl=orphan_ttl,
        ),
        "needs_comments": primary.reason == "unsalvaged-artifacts",
        "needs_lsof": primary.action == "trash" or primary.reason == "directory-in-use",
    }


def _reuse_cached_task(
    task_dir: Path,
    entry: dict[str, Any],
    *,
    now: datetime,
    lookup: _MulticaLookup,
    in_use_fn: InUseFn | None,
) -> list[ReclaimItem] | None:
    fingerprint = _task_fingerprint(task_dir, entry.get("aux_paths") or [])
    if fingerprint != entry.get("fingerprint"):
        return None
    recheck_at = entry.get("recheck_at")
    if recheck_at is not None and now.timestamp() >= float(recheck_at):
        return None
    raw_items = entry.get("items")
    if not isinstance(raw_items, list) or not raw_items:
        return None
    rows = [_item_from_dict(item) for item in raw_items if isinstance(item, dict)]
    if not rows:
        return None
    if not entry.get("run_terminal"):
        issue_id = str(entry.get("issue_id") or "")
        if not issue_id:
            return None
        runs = lookup.runs(issue_id)
        if runs is None:
            return None
        run = match_multica_run(runs, task_dir.name)
        status = str((run or {}).get("status") or "").strip().lower()
        if run_is_terminal(status):
            return None
        return rows
    if entry.get("needs_comments"):
        issue_id = str(entry.get("issue_id") or "")
        if not issue_id:
            return None
        issue = lookup.issue(issue_id)
        comments = lookup.refresh_comments(issue_id) or []
        posted, _why = issue_has_posted_artifacts(issue, comments, since=None)
        if posted:
            return None
    if entry.get("needs_lsof"):
        busy_fn = in_use_fn or directory_in_use
        busy = bool(busy_fn(task_dir))
        primary = rows[0]
        extra = dict(primary.extra or {})
        checks = dict(extra.get("checks") or {})
        checks["in_use"] = busy
        extra["checks"] = checks
        if busy and primary.action == "trash":
            rows[0] = ReclaimItem(
                category=primary.category,
                path=primary.path,
                action="keep",
                reason="directory-in-use",
                bytes=primary.bytes,
                extra=extra,
            )
        elif not busy and primary.reason == "directory-in-use":
            return None
        else:
            rows[0] = ReclaimItem(
                category=primary.category,
                path=primary.path,
                action=primary.action,
                reason=primary.reason,
                bytes=primary.bytes,
                extra=extra,
            )
    return rows


def plan_multica_workspaces(
    workspaces_root: Path,
    *,
    now: datetime,
    protection: Protection,
    task_ttl: int = MULTICA_TASK_TTL_SECONDS,
    artifact_ttl: int = MULTICA_ARTIFACT_TTL_SECONDS,
    orphan_ttl: int = MULTICA_ORPHAN_TTL_SECONDS,
    git: GitRunner | None = None,
    multica_json: MulticaJsonFn | None = None,
    in_use: InUseFn | None = None,
    cache: dict[str, Any] | None = None,
    deadline_monotonic: float | None = None,
    resume_after: str = "",
    progress: dict[str, Any] | None = None,
    workers: int = CLI_PREFETCH_WORKERS,
) -> list[ReclaimItem]:
    if progress is not None:
        progress.update(
            judged=0,
            total=0,
            reused=0,
            fresh=0,
            incomplete=False,
            resume_after=resume_after,
            message="",
        )
    if not workspaces_root.is_dir():
        return []
    lookup = _MulticaLookup(multica_json)
    if cache is not None:
        lookup.load_persisted_runs(cache.get("runs") or {})
        lookup.load_persisted_issues(cache.get("issues") or {})
    items: list[ReclaimItem] = []
    task_dirs: list[Path] = []
    try:
        workspaces = sorted(workspaces_root.iterdir(), key=lambda path: path.name)
    except OSError:
        return []
    for workspace in workspaces:
        if not workspace.is_dir() or workspace.name.startswith("."):
            continue
        if workspace.name == ".repos":
            items.append(_item("multica", workspace, "keep", "bare-repo-cache"))
            continue
        try:
            children = sorted(workspace.iterdir(), key=lambda path: path.name)
        except OSError:
            continue
        for task_dir in children:
            if not task_dir.is_dir() or task_dir.name.startswith("."):
                continue
            task_dirs.append(task_dir)

    ordered = rotate_task_dirs(task_dirs, resume_after)
    cached_tasks = (cache or {}).get("tasks") if cache is not None else None
    judged = 0
    reused = 0
    fresh = 0
    incomplete = False
    last_path = resume_after
    wave_size = max(1, int(workers))
    index = 0
    while index < len(ordered):
        if deadline_monotonic is not None and time.monotonic() >= deadline_monotonic:
            incomplete = True
            break
        wave = ordered[index : index + wave_size]
        runs_ids: list[str] = []
        detail_ids: list[str] = []
        for task_dir in wave:
            if protection.blocks(task_dir):
                continue
            entry = cached_tasks.get(str(task_dir)) if isinstance(cached_tasks, dict) else None
            if _cache_reusable_without_cli(
                entry if isinstance(entry, dict) else None,
                task_dir,
                now,
            ):
                continue
            issue_id = _issue_id_for_task(
                task_dir,
                entry if isinstance(entry, dict) else None,
            )
            if not issue_id:
                continue
            if isinstance(entry, dict) and not entry.get("run_terminal") and not entry.get("needs_comments"):
                runs_ids.append(issue_id)
            else:
                detail_ids.append(issue_id)
        _prefetch_issue_runs(lookup, [*runs_ids, *detail_ids], workers=workers)
        _prefetch_issue_details(lookup, detail_ids, workers=workers)
        for task_dir in wave:
            if deadline_monotonic is not None and time.monotonic() >= deadline_monotonic:
                incomplete = True
                break
            if protection.blocks(task_dir):
                items.append(_item("multica", task_dir, "keep", "protected"))
                judged += 1
                last_path = str(task_dir)
                continue
            entry = cached_tasks.get(str(task_dir)) if isinstance(cached_tasks, dict) else None
            reused_rows = None
            if isinstance(entry, dict):
                reused_rows = _reuse_cached_task(
                    task_dir,
                    entry,
                    now=now,
                    lookup=lookup,
                    in_use_fn=in_use,
                )
            if reused_rows is not None:
                items.extend(reused_rows)
                reused += 1
            else:
                rows = _plan_one_multica_task(
                    task_dir,
                    now=now,
                    task_ttl=task_ttl,
                    artifact_ttl=artifact_ttl,
                    orphan_ttl=orphan_ttl,
                    git=git,
                    lookup=lookup,
                    in_use_fn=in_use,
                )
                items.extend(rows)
                fresh += 1
                if cache is not None and rows:
                    tasks = cache.setdefault("tasks", {})
                    if isinstance(tasks, dict):
                        tasks[str(task_dir)] = _cache_entry_from_items(
                            task_dir,
                            rows,
                            now=now,
                            task_ttl=task_ttl,
                            artifact_ttl=artifact_ttl,
                            orphan_ttl=orphan_ttl,
                        )
            judged += 1
            last_path = str(task_dir)
        if incomplete:
            break
        index += wave_size

    if cache is not None:
        cache["runs"] = lookup.dump_runs()
        cache["issues"] = lookup.dump_issues()
        cache["resume_after"] = last_path if incomplete else ""
        live = {str(path) for path in task_dirs}
        try:
            root_resolved = workspaces_root.resolve()
        except OSError:
            root_resolved = workspaces_root
        tasks = cache.get("tasks")
        if isinstance(tasks, dict):
            stale = []
            for key in tasks:
                if key in live:
                    continue
                try:
                    belongs = Path(key).resolve().is_relative_to(root_resolved)
                except (ValueError, OSError):
                    belongs = False
                if belongs:
                    stale.append(key)
            for gone in stale:
                tasks.pop(gone, None)

    if progress is not None:
        total = len(task_dirs)
        progress.update(
            judged=judged,
            total=total,
            reused=reused,
            fresh=fresh,
            incomplete=incomplete,
            resume_after=last_path if incomplete else "",
            message=(
                f"本轮只判了 {judged}/{total}，下轮接着判"
                if incomplete
                else (f"本轮判了 {judged}/{total}" if total else "")
            ),
        )
    return items


def plan_runner_work(
    runner_dir: Path,
    *,
    now: datetime,
    idle_seconds: int,
    protection: Protection,
) -> list[ReclaimItem]:
    work = runner_dir / "_work"
    if not work.is_dir():
        return []
    cutoff = now.timestamp() - idle_seconds
    items: list[ReclaimItem] = []
    for child in work.iterdir():
        if not child.is_dir():
            continue
        if protection.blocks(child):
            items.append(_item("runner", child, "keep", "protected"))
            continue
        if child.name in {"_update", "_temp"}:
            continue
        touched = last_touched_epoch(child)
        if touched >= cutoff:
            items.append(_item("runner", child, "keep", "recent-runner-work"))
        else:
            items.append(_item("runner", child, "trash", "idle-runner-work"))
    return items


def default_roots(home: Path) -> dict[str, Path]:
    from cortex_sentinel.paths import projects

    configured = projects()
    first = next((row for row in configured if str(row.get("root") or "").strip()), None)
    if first is not None:
        repo = Path(str(first["root"])).expanduser()
        worktrees = Path(str(repo) + "-worktrees")
    else:
        repo = home / ".cortex-sentinel" / "unconfigured-project"
        worktrees = home / ".cortex-sentinel" / "unconfigured-worktrees"
    return {
        "home": home,
        "repo": repo,
        "worktrees": worktrees,
        "webruntime": home / "Library" / "Application Support" / "Cortex" / "WebRuntime",
        "multica_desktop": home / "multica_workspaces_desktop-api.multica.ai",
        "multica_plain": home / "multica_workspaces",
        "runner": home / "actions-runner-cortex",
        "desktop_cache": home / ".cache" / "cortex-desktop",
    }


def plan_all(
    *,
    home: Path,
    repo: Path | None = None,
    now: datetime | None = None,
    git: GitRunner | None = None,
    keep_dist_stem: str | None = None,
    skip_worktrees: Sequence[Path] = (),
    only: Sequence[str] | None = None,
    cache: dict[str, Any] | None = None,
    deadline_monotonic: float | None = None,
    resume_after: str = "",
    progress: dict[str, Any] | None = None,
    workers: int = CLI_PREFETCH_WORKERS,
) -> list[ReclaimItem]:
    moment = now or _now()
    roots = default_roots(home)
    if repo is not None:
        roots["repo"] = repo
        parent = repo.parent
        # worktree 协议默认把树放在「主仓目录名-worktrees」
        candidate = Path(str(repo) + "-worktrees")
        if candidate.is_dir():
            roots["worktrees"] = candidate
        elif (parent / "cortex-worktrees").is_dir():
            roots["worktrees"] = parent / "cortex-worktrees"
    data_root = _resolve_data_root()
    protection = make_protection(home=home, data_root=data_root)
    wanted = set(only) if only else {
        "worktree",
        "packaging",
        "cache",
        "multica",
        "runner",
    }
    if "packaging" in wanted:
        wanted.update({"webruntime", "dist"})
    items: list[ReclaimItem] = []

    logs_dirs = [roots["repo"] / "logs", roots["worktrees"]]
    # worktree 各自的 logs/ 是实体目录
    wt_root = roots["worktrees"]
    if wt_root.is_dir():
        for child in wt_root.iterdir():
            logs_dirs.append(child / "logs")
    active = load_active_workdirs(logs_dirs)

    if "worktree" in wanted and roots["repo"].is_dir() and (roots["repo"] / ".git").exists():
        main_ref = "refs/remotes/origin/main"
        show = (git or (lambda args, cwd: _run_git(args, cwd)))(["show-ref", "--verify", "--quiet", main_ref], roots["repo"])
        if show.returncode != 0:
            main_ref = "refs/heads/main"
        items.extend(
            plan_worktrees(
                roots["repo"],
                main_ref=main_ref,
                active_workdirs=active,
                protection=protection,
                git=git,
                skip_paths=list(skip_worktrees),
            )
        )

    if "webruntime" in wanted:
        items.extend(plan_webruntime_backups(roots["webruntime"] / "backups"))
    if "dist" in wanted or "packaging" in wanted:
        items.extend(plan_dist_previous(roots["repo"] / "dist", keep_stem=keep_dist_stem))

    if "cache" in wanted:
        skip_live = [
            roots["webruntime"] / "current",
            home / "Library" / "Application Support" / "Cortex" / "HealthRuntime" / "current",
            roots["repo"] / "src" / "web" / "node_modules",
        ]
        cache_roots = [roots["worktrees"], roots["desktop_cache"]]
        items.extend(
            plan_build_caches(
                cache_roots,
                now=moment,
                idle_seconds=CACHE_IDLE_SECONDS,
                protection=protection,
                skip_under=skip_live,
            )
        )

    if "multica" in wanted:
        combined = {
            "judged": 0,
            "total": 0,
            "reused": 0,
            "fresh": 0,
            "incomplete": False,
            "resume_after": "",
            "message": "",
        }
        for key in ("multica_desktop", "multica_plain"):
            part: dict[str, Any] = {}
            items.extend(
                plan_multica_workspaces(
                    roots[key],
                    now=moment,
                    protection=protection,
                    git=git,
                    cache=cache,
                    deadline_monotonic=deadline_monotonic,
                    resume_after=resume_after if key == "multica_desktop" else "",
                    progress=part,
                    workers=workers,
                )
            )
            combined["judged"] += int(part.get("judged") or 0)
            combined["total"] += int(part.get("total") or 0)
            combined["reused"] += int(part.get("reused") or 0)
            combined["fresh"] += int(part.get("fresh") or 0)
            if part.get("incomplete"):
                combined["incomplete"] = True
                combined["resume_after"] = str(part.get("resume_after") or combined["resume_after"])
        if combined["incomplete"]:
            combined["message"] = (
                f"本轮只判了 {combined['judged']}/{combined['total']}，下轮接着判"
            )
        elif combined["total"]:
            combined["message"] = f"本轮判了 {combined['judged']}/{combined['total']}"
        if progress is not None:
            progress.update(combined)
        if cache is not None and combined["incomplete"]:
            cache["resume_after"] = combined["resume_after"]
        elif cache is not None:
            cache["resume_after"] = ""

    if "runner" in wanted:
        items.extend(
            plan_runner_work(
                roots["runner"],
                now=moment,
                idle_seconds=RUNNER_IDLE_SECONDS,
                protection=protection,
            )
        )
    return items


def apply_items(
    items: Sequence[ReclaimItem],
    *,
    home: Path,
    protection: Protection,
    trash: TrashFn | None = None,
    git_prune_repo: Path | None = None,
    git: GitRunner | None = None,
) -> list[dict[str, Any]]:
    trash_fn = trash or (lambda path, label: trash_to_finder(path, label, home=home))
    results: list[dict[str, Any]] = []
    trashed_worktree = False
    for item in items:
        record = asdict(item)
        if item.action != "trash":
            results.append(record)
            continue
        path = Path(item.path)
        if protection.blocks(path):
            record["action"] = "keep"
            record["reason"] = f"protected-at-apply:{item.reason}"
            results.append(record)
            continue
        try:
            dest = trash_fn(path, f"{TRASH_LABEL}-{item.category}")
        except Exception as exc:  # noqa: BLE001 - 单条失败不许打断整轮
            record["action"] = "alert"
            record["reason"] = f"trash-failed:{exc}"
            results.append(record)
            continue
        record["trashed_to"] = str(dest)
        results.append(record)
        if item.category == "worktree":
            trashed_worktree = True
    if trashed_worktree and git_prune_repo is not None:
        run = git or (lambda args, cwd: _run_git(args, cwd))
        run(["worktree", "prune"], git_prune_repo)
    return results


def summarize(items: Sequence[ReclaimItem] | Sequence[dict[str, Any]]) -> dict[str, Any]:
    trash_n = 0
    alert_n = 0
    keep_n = 0
    bytes_n = 0
    for item in items:
        if isinstance(item, ReclaimItem):
            action = item.action
            size = item.bytes
        else:
            action = str(item.get("action") or "")
            size = int(item.get("bytes") or 0)
        if action == "trash":
            trash_n += 1
            bytes_n += size
        elif action == "alert":
            alert_n += 1
        else:
            keep_n += 1
    return {
        "trash": trash_n,
        "alert": alert_n,
        "keep": keep_n,
        "reclaimed_bytes": bytes_n,
    }


def default_state_path() -> Path:
    try:
        from cortex_sentinel.devserver import _health_dir

        return _health_dir() / ".line-reclaimer-state.json"
    except Exception:
        from cortex_sentinel.paths import sentinel_home

        return sentinel_home() / _HEALTH_DIR_NAME / ".line-reclaimer-state.json"


def default_ledger_path() -> Path:
    try:
        from cortex_sentinel.devserver import LOG_PATH

        return LOG_PATH
    except Exception:
        from cortex_sentinel.paths import sentinel_home

        return sentinel_home() / _HEALTH_DIR_NAME / "dev-server-reaper.jsonl"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="真的送回收站；默认只看不动")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--repo", type=Path, default=None)
    parser.add_argument(
        "--only",
        action="append",
        choices=("worktree", "packaging", "webruntime", "cache", "multica", "runner"),
        help="只跑其中一类，可重复",
    )
    parser.add_argument("--keep-dist-stem", default=None, help="出包收尾时保留这一轮的 artifact stem")
    parser.add_argument(
        "--budget-seconds",
        type=float,
        default=ROUND_BUDGET_SECONDS,
        help="整轮挂钟预算，到点收工并打印已判 N/M。0 表示不截断",
    )
    parser.add_argument(
        "--state",
        type=Path,
        default=None,
        help="判定缓存路径；默认写在健康台账目录",
    )
    parser.add_argument(
        "--ledger",
        type=Path,
        default=None,
        help="心跳台账 jsonl；默认跟 dev_server_reaper 同一份",
    )
    parser.add_argument(
        "--interval-seconds",
        type=float,
        default=None,
        help="launchd 间隔，用来标「耗时超过一半」。默认 600",
    )
    parser.add_argument("--workers", type=int, default=CLI_PREFETCH_WORKERS)
    parser.add_argument(
        "--skip-reason",
        default="",
        help="心跳可见的空跑原因，例如 install-verify-marker",
    )
    parser.add_argument(
        "--install-verify-state",
        default="",
        help="安装验证标记本轮怎么处理：skipped / applied-despite-recent-skip",
    )
    args = parser.parse_args(argv)
    home = args.home.expanduser()
    repo = args.repo.expanduser() if args.repo else None
    cwd = Path.cwd()
    from cortex_sentinel.devserver import (
        MEMORY_MONITOR_INTERVAL_SECONDS,
        append_run_record,
        attach_round_duration,
        east_eight_ledger_ts,
    )

    state_path = (args.state or default_state_path()).expanduser()
    ledger_path = (args.ledger or default_ledger_path()).expanduser()
    interval = (
        float(args.interval_seconds)
        if args.interval_seconds is not None
        else float(MEMORY_MONITOR_INTERVAL_SECONDS)
    )
    cache = load_round_state(state_path)
    progress: dict[str, Any] = {}
    started = time.monotonic()
    budget = float(args.budget_seconds)
    deadline = None if budget <= 0 else started + budget
    skip_reason = str(args.skip_reason or "").strip()
    verify_state = str(args.install_verify_state or "").strip()
    if not verify_state and skip_reason == "install-verify-marker":
        verify_state = "skipped"
    heartbeat: dict[str, Any] = {
        "ts": east_eight_ledger_ts(),
        "kind": "line_reclaimer",
        "applied": bool(args.apply),
        "status": "running",
    }
    if skip_reason:
        heartbeat["skip_reason"] = skip_reason
    if verify_state:
        heartbeat["install_verify"] = verify_state
    # 先落一行 running。崩在 plan/apply 里、或被 launchd 掐掉时，外面至少能看见
    # 「这轮开始了但没结束」，而不是什么都不写。
    append_run_record(ledger_path, heartbeat)
    items: list[ReclaimItem] = []
    applied: list[dict[str, Any]] | None = None
    extra: dict[str, Any] = {
        "status": "error",
        "error": "did-not-finish",
    }
    try:
        if skip_reason == "install-verify-marker":
            # 安装验证空跑：只留痕，不扫盘。06:04 那轮空跑还扫了 296 秒，
            # 下一轮间隔只剩一半，机器一忙就像「没跑」。
            extra = {
                "status": "ok",
                "summary": summarize([]),
            }
        else:
            items = plan_all(
                home=home,
                repo=repo,
                keep_dist_stem=args.keep_dist_stem,
                skip_worktrees=[cwd],
                only=args.only,
                cache=cache,
                deadline_monotonic=deadline,
                resume_after=str(cache.get("resume_after") or ""),
                progress=progress,
                workers=max(1, int(args.workers)),
            )
            protection = make_protection(home=home, data_root=_resolve_data_root())
            if args.apply:
                applied = apply_items(
                    items,
                    home=home,
                    protection=protection,
                    git_prune_repo=repo if repo is not None else default_roots(home)["repo"],
                )
            extra = {
                "status": "ok",
                "summary": summarize(applied if applied is not None else items),
            }
            if progress.get("incomplete"):
                extra["incomplete"] = True
                extra["progress_message"] = str(
                    progress.get("message") or "本轮没跑完，下轮接着"
                )
                extra["resume_after"] = str(progress.get("resume_after") or "")
            save_round_state(state_path, cache)
    except Exception as exc:
        extra = {
            "status": "error",
            "error": f"{type(exc).__name__}: {exc}"[:800],
            "summary": summarize(applied if applied is not None else items),
        }
        print(extra["error"], file=sys.stderr)
    elapsed = time.monotonic() - started
    duration_record = attach_round_duration(
        ledger_path, elapsed, interval, extra=extra
    )
    summary = duration_record.get("summary") or extra.get("summary") or summarize([])
    payload: dict[str, Any] = {
        "applied": bool(args.apply),
        "status": extra.get("status") or duration_record.get("status"),
        "summary": summary,
        "items": applied if applied is not None else [asdict(item) for item in items],
        "duration_seconds": duration_record.get("duration_seconds"),
        "interval_seconds": duration_record.get("interval_seconds"),
        "duration_over_half_interval": bool(
            duration_record.get("duration_over_half_interval")
        ),
        "progress": {
            "judged": int(progress.get("judged") or 0),
            "total": int(progress.get("total") or 0),
            "reused": int(progress.get("reused") or 0),
            "fresh": int(progress.get("fresh") or 0),
            "incomplete": bool(progress.get("incomplete") or extra.get("incomplete")),
            "resume_after": str(
                progress.get("resume_after") or extra.get("resume_after") or ""
            ),
            "message": str(
                progress.get("message") or extra.get("progress_message") or ""
            ),
        },
    }
    if extra.get("error"):
        payload["error"] = extra["error"]
    if duration_record.get("duration_warn"):
        payload["duration_warn"] = duration_record["duration_warn"]
    if payload["progress"]["incomplete"] and payload["progress"]["message"]:
        print(payload["progress"]["message"], file=sys.stderr)
    if payload.get("duration_over_half_interval") and payload.get("duration_warn"):
        print(payload["duration_warn"], file=sys.stderr)
    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        summary = payload["summary"]
        print(
            f"回收计划: trash={summary['trash']} alert={summary['alert']} "
            f"keep={summary['keep']} ~{summary['reclaimed_bytes'] / GIB:.1f}G"
            f"{' APPLIED' if args.apply else ' DRY-RUN'}"
            f" duration={payload['duration_seconds']:.1f}s"
        )
        if payload["progress"]["message"]:
            print(payload["progress"]["message"])
        for item in payload["items"]:
            if item["action"] == "keep":
                continue
            print(f"  {item['action']:5} {item['category']:10} {item['reason']} {item['path']}")
            extra = item.get("extra") or {}
            bits = []
            issue = extra.get("issue") or extra.get("issue_id")
            if issue:
                bits.append(f"issue={issue}")
            run_id = extra.get("run_id")
            if run_id:
                bits.append(f"run={run_id}")
            decision = extra.get("decision")
            if decision:
                bits.append(str(decision))
            if bits:
                print(f"         {' '.join(bits)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
