#!/usr/bin/env python3
"""读 Cursor Agent 的会话库，把一条 Grok 线的真实执行进度打出来。

为什么需要它：grok_dispatch.py 用 --output-format text 起 cursor-agent，
那个格式是缓冲的，一条正在干活的线 stdout 可能整轮都是 0 字节。
以前的结论是「判活性只看 git 提交」，那是绕法不是解法——
cursor-agent 自己把每一步都写进了 ~/.cursor/chats/<项目>/<会话>/store.db，
逐工具调用可读、带时间戳、随写随更新。

实测边界（2026-08-19 用一条五步读文件的探针量的，日志全程 0 字节而库在长）:

- 库是**边跑边写**的：blob 数 4 -> 13 -> 32 -> 50 -> 53 -> 56 一路涨，而 stdout 直到进程
  退出才出现 103 字节。所以这个库能当实时进度用，日志不能。
- **起跑后约 20 到 30 秒库才出现**。这段时间查不到会话是正常的，别判成线死了。
- **blob 数会平台期**（实测出现过 50 -> 50）：单次工具调用耗时长的时候数字不动。判卡死
  要看一个时间窗内有没有增长，不能拿单次采样说事。
- 路径要用解析后的真实路径算 md5。macOS 上 `/tmp` 是 `/private/tmp` 的软链，拿字面
  路径算会得到一个根本不存在的目录，看起来就像「这条线没有会话记录」。

用法:
    python3 scripts/grok_progress.py --slug webreds0819
    python3 scripts/grok_progress.py --workdir /path/to/worktree
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cortex_sentinel.paths import status_dir

EAST_EIGHT = timezone(timedelta(hours=8))
CHATS_ROOT = Path.home() / ".cursor" / "chats"


def chat_dir_for(workdir: Path) -> Path:
    """Cursor 把会话按工作目录的绝对路径 md5 分目录存放（2026-08-19 实测反推）。"""
    digest = hashlib.md5(str(workdir.resolve()).encode("utf-8")).hexdigest()
    return CHATS_ROOT / digest


def status_of_slug(slug: str, repo_root: Path | None = None) -> dict | None:
    candidates = [status_dir() / f"grok-{slug}.status.json"]
    if repo_root is not None:
        root = Path(repo_root)
        candidates.append(root / "logs" / f"grok-{slug}.status.json")
        candidates.append(root / f"grok-{slug}.status.json")
    for status in candidates:
        if not status.exists():
            continue
        try:
            return json.loads(status.read_text(encoding="utf-8"))
        except Exception:
            return None
    return None


def workdir_of_slug(slug: str, repo_root: Path | None = None) -> Path | None:
    data = status_of_slug(slug, repo_root)
    if not data:
        return None
    return Path(data.get("workdir") or "")


def started_at_of_slug(slug: str, repo_root: Path | None = None) -> datetime | None:
    """这条线自己的起跑时刻，用来把别的线的会话排除掉。"""
    data = status_of_slug(slug, repo_root)
    if not data:
        return None
    raw = data.get("started_at")
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw)
    except ValueError:
        return None


def sessions_for(workdir: Path, since: datetime | None = None) -> list[Path]:
    """这个工作目录下的会话库，最近改的排前面。

    **工作目录不等于线。** 多条线共用一个工作目录（最典型的就是都在主仓里跑）时，
    这个 md5 目录下堆着的是历史上**所有**线的会话，包括早就跑完的。只按 mtime 取
    最新的那个，会把隔壁线的会话当成你问的那条线来读，而且读出来的数字长得完全正常
    ——这是 2026-08-19 实际踩到的：按目录汇总算出 10837 个事件，其实是几十条历史线
    叠在一起。

    所以给了起跑时刻就必须按它过滤：**只有这条线起跑之后才被写过的库，才可能是它的。**
    """
    root = chat_dir_for(workdir)
    if not root.is_dir():
        return []
    dbs = list(root.glob("*/store.db"))
    if since is not None:
        # 留 60 秒余量：起跑时刻由守护写入，跟 Cursor 落库之间有先后。
        floor = since.timestamp() - 60
        dbs = [d for d in dbs if d.stat().st_mtime >= floor]
    return sorted(dbs, key=lambda p: p.stat().st_mtime, reverse=True)


def read_events(db: Path) -> list[dict]:
    """先把库快照到临时目录再读。

    直接以 mode=ro 打开正在写的库会 unable to open database file——
    WAL 模式下 sqlite 还要碰同目录的 -wal / -shm，只读 URI 给不了它。
    快照顺带保证读到的是一致的一瞬间，不会读一半被写花。
    """
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "snapshot.db"
        shutil.copy2(db, target)
        for suffix in ("-wal", "-shm"):
            side = db.with_name(db.name + suffix)
            if side.exists():
                shutil.copy2(side, target.with_name(target.name + suffix))
        con = sqlite3.connect(str(target))
        try:
            rows = con.execute("select data from blobs").fetchall()
        finally:
            con.close()
    out: list[dict] = []
    for (blob,) in rows:
        try:
            obj = json.loads(bytes(blob).decode("utf-8", errors="replace"))
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("role"):
            out.append(obj)
    return out


def summarize(db: Path) -> dict:
    events = read_events(db)
    roles: dict[str, int] = {}
    for e in events:
        roles[e["role"]] = roles.get(e["role"], 0) + 1
    last_text = ""
    for e in reversed(events):
        if e.get("role") != "assistant":
            continue
        content = e.get("content")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text" and part.get("text"):
                    last_text = part["text"]
                    break
        elif isinstance(content, str):
            last_text = content
        if last_text:
            break
    mtime = datetime.fromtimestamp(db.stat().st_mtime, EAST_EIGHT)
    return {
        "db": str(db),
        "roles": roles,
        "tool_calls": roles.get("tool", 0),
        "last_activity": mtime.strftime("%m-%d %H:%M:%S"),
        "idle_seconds": int((datetime.now(EAST_EIGHT) - mtime).total_seconds()),
        "last_assistant_text": last_text[:400],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--slug")
    ap.add_argument("--workdir")
    ap.add_argument("--repo-root", default="", help="可选：旧布局下的项目根，用来找 logs/ 里的 status")
    args = ap.parse_args()

    repo_root = Path(args.repo_root) if args.repo_root else None
    if args.workdir:
        workdir = Path(args.workdir)
    elif args.slug:
        found = workdir_of_slug(args.slug, repo_root)
        if not found:
            print(f"找不到 {args.slug} 的 status 文件或其中的 workdir")
            return 2
        workdir = found
    else:
        print("要么给 --slug 要么给 --workdir")
        return 2

    started = started_at_of_slug(args.slug, repo_root) if args.slug else None
    dbs = sessions_for(workdir, since=started)
    if not dbs:
        if started is not None and sessions_for(workdir):
            print(f"这个工作目录有会话记录，但没有一个是 {args.slug} 起跑之后写的。")
            print(f"（起跑 {started.strftime('%m-%d %H:%M:%S')}，说明这条线还没往库里写，或者它根本没起来）")
            return 1
        print(f"这个工作目录在 Cursor 里没有会话记录: {workdir}")
        print(f"（找的是 {chat_dir_for(workdir)}）")
        return 1

    info = summarize(dbs[0])
    print(f"工作目录 : {workdir}")
    if len(dbs) > 1:
        print(f"⚠ 同一工作目录下有 {len(dbs)} 个会话库都在这条线起跑之后被写过 —— "
              "多半是几条线共用了一个工作目录。下面读的是最近改的那个，**不保证就是你问的这条线**。")
    print(f"会话库   : {info['db']}")
    print(f"最后活动 : {info['last_activity']} 东八区（{info['idle_seconds']} 秒前）")
    print(f"事件分布 : {info['roles']}")
    print(f"工具调用 : {info['tool_calls']} 次")
    if info["last_assistant_text"]:
        print("最后一段助手输出:")
        print("  " + info["last_assistant_text"].replace("\n", "\n  "))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
