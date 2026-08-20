#!/usr/bin/env python3
"""内存面板读数 + 按 App 聚合 + kernel_task 拆解 + 可选记录仪。

为什么要重写（2026-08-18，Falcon 的 48 GB M5 Max 被没关的 next dev 打爆）：

1. 他看的是 iStat Menus 菜单栏，字段叫 App 内存 / 联动内存 / 已压缩 / 可用 /
   压力 / 已使用的交换，进程榜按 App 聚合。旧工具按单进程和自定义族切，
   数字对不上他的眼睛，他就没法交叉印证。
2. 面板第一名「macOS 17.5 GB」其实是 kernel_task。里面绝大部分是压缩器
   替用户进程站的岗，不是系统自己要 17 G。不拆开就会得出「macOS 坏了」
   这种假结论。
3. 旧监控用 ps 的 RSS。回收站里一个 dev server RSS 130 MB、top MEM 11 G，
   差 86 倍。判据没写错，度量看不见要判的东西，沉默跟一切正常长得一样。
4. 读数必须自校验。求和跟 vm_stat 对不上就明说「读数不可信」，
   不许静默给一个看起来精确的错数。

口径全部借系统自己的数，不发明：
- App 内存 = (vm.page_pageable_internal_count − Pages purgeable) × page
  这是 Activity Monitor / iStat 用的公式（见 Apple StackExchange 与
  rzarajczyk 的对照；本机 iStat 中文把 Wired 译成「联动内存」、
  Free 译成「可用」、Swap 译成「已使用的交换」）
- 联动内存 = Pages wired down
- 已压缩 = Pages occupied by compressor（压缩器此刻占着的 RAM，
  不是被压进去的原始量；原始量是 Pages stored in compressor）
- 可用 = (`Pages free` + `Pages inactive`) × `vm_stat` 动态页大小
  不能拿 `top` 的 PhysMem unused 代替，它不含可立即回收的 inactive 页
- 压力% = 100 − kern.memorystatus_level
  memorystatus_level 是系统说的「还能腾出百分之多少」，越低越紧；
  iStat 的压力是 lower-is-better，所以用补数。等级走
  kern.memorystatus_vm_pressure_level（1 正常 / 2 警告 / 4 紧急）
- 交换 = sysctl vm.swapusage
- 进程真实占用 = top 的 MEM，压缩量 = top 的 CMPRS。不用 RSS。

用法：
    python3 scripts/mem_watch.py                 # 人读面板
    python3 scripts/mem_watch.py --json
    python3 scripts/mem_watch.py --ours          # 我们这边一共占了多少
    python3 scripts/mem_watch.py --ours --json
    python3 scripts/mem_watch.py --breakdown     # 拆开 macOS / 联动 / 压缩器
    python3 scripts/mem_watch.py --watch --out logs/mem-watch.jsonl
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Callable

# 独立版作为包导入。名字避开 ROOT / PROJECT_ROOT，路径闸会当成绕过。

GIB = 1024**3
MIB = 1024**2

# 自校验容差。必须相对和绝对同时越过才报不可信。
# 35% / 8 GB 的理由：压缩器记在 kernel_task 头上、统一内存显卡、共享库，
# 正常差额就能到 15–25%、5–7 GB（本机实测约 19% / 7.5 GB 仍可信）。
# 当年 RSS 失明是 86 倍，那种才会双双越过。收太紧会天天误报，等于没报。
RECONCILE_REL_TOL = 0.35
RECONCILE_ABS_TOL_BYTES = 8 * GIB

# Falcon 2026-08-18 给的口径：48G 机器留 18G 给他自己用。
# 这是预算，用来回答「离 30G 还有多少余量」。不是硬闸，超了不杀进程。
OURS_BUDGET_BYTES = 30 * GIB

# 同一份进程表、同一个函数归出来的类别。拆开扫会互卷。
OURS_CAT_AI_WINDOW = "ai_window"
OURS_CAT_DISPATCH = "dispatch"
OURS_CAT_NEXT_DEV = "next_dev"
OURS_CAT_BROWSER_MCP = "browser_mcp"
OURS_CAT_LANG_SERVER = "lang_server"
OURS_CAT_REPO_SCRIPT = "repo_script"
OURS_CAT_CURSOR_APP = "cursor_app"
OURS_CAT_UNKNOWN = "unknown"
OURS_CAT_NOT_OURS = "not_ours"

# 算进「我们这边」总数的类别。Cursor 应用本体在这里，认不出不在。
OURS_TOTAL_CATS = (
    OURS_CAT_AI_WINDOW,
    OURS_CAT_DISPATCH,
    OURS_CAT_NEXT_DEV,
    OURS_CAT_BROWSER_MCP,
    OURS_CAT_LANG_SERVER,
    OURS_CAT_REPO_SCRIPT,
    OURS_CAT_CURSOR_APP,
)

OURS_BUCKET_LABELS = (
    (OURS_CAT_AI_WINDOW, "AI 窗口"),
    (OURS_CAT_DISPATCH, "派工 / 子代理"),
    (OURS_CAT_NEXT_DEV, "next dev"),
    (OURS_CAT_BROWSER_MCP, "浏览器 / MCP"),
    (OURS_CAT_LANG_SERVER, "语言服务"),
    (OURS_CAT_REPO_SCRIPT, "仓内脚本"),
    (OURS_CAT_CURSOR_APP, "Cursor 应用本体"),
    (OURS_CAT_UNKNOWN, "认不出"),
)

# 占着不用：直接用清理器的判定，不另造。managed_over 是还在用只是太大，不算忘关。
UNUSED_VERDICTS = frozenset({"dead", "orphan_idle", "idle"})

_SCRIPT_RUNTIME = frozenset(
    {
        "node",
        "nodejs",
        "npm",
        "npx",
        "python",
        "python3",
        "python3.12",
        "python3.13",
        "ruby",
        "perl",
        "php",
        "java",
    }
)
_CANDIDATE_COMM = _SCRIPT_RUNTIME | {
    "chromium",
    "chrome",
    "google chrome",
    "google chrome for testing",
    "chrome helper",
    "chromedriver",
}

_SIZE = re.compile(r"^([0-9]+(?:\.[0-9]+)?)([BKMGT])?[+-]?$", re.I)
_APP_PATH = re.compile(r"/Applications/([^/]+)\.app(?:/|$)")
_SYS_APP_PATH = re.compile(r"/System/Applications/([^/]+)\.app(?:/|$)")
_HELPER = re.compile(r"^(.+?) Helper(?: \([^)]+\))?$")
_NEXT_PORT = re.compile(r"-p\s+(\d+)")
_WORKTREE = re.compile(r"cortex-worktrees/([^/]+)")
_PS_LINE = re.compile(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(.*)$")
_ZPRINT_ZONE = re.compile(
    r"^(\S+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+"
)
_ZPRINT_SIZE_K = re.compile(r"(\d+)K\s*$")

Runner = Callable[[list[str]], str]


def parse_top_size(token: str) -> float:
    """把 top 的 8980M / 10G / 546M / 0B / 7888K 换成 MB。

    畸形 token 返回 0，不抛。单行坏了不能让整次采样崩掉——
    2026-08-18 的教训就是度量一瞎，后面全是假安静。
    """
    got = _SIZE.match((token or "").strip())
    if not got:
        return 0.0
    value = float(got.group(1))
    unit = (got.group(2) or "B").upper()
    factor = {"B": 1 / MIB, "K": 1 / 1024, "M": 1.0, "G": 1024.0, "T": 1024.0 * 1024}[unit]
    return value * factor


def parse_top_table(text: str) -> dict[int, dict[str, float | str]]:
    """pid -> {command, mem_mb, cmprs_mb}。跳过表头和残行。"""
    table: dict[int, dict[str, float | str]] = {}
    for line in (text or "").splitlines():
        parts = line.split()
        if len(parts) < 3 or not parts[0].isdigit():
            continue
        try:
            pid = int(parts[0])
            # top -stats pid,command,mem,cmprs ：command 可能被截断但不含空格
            # top -stats pid,mem,cmprs ：没有 command
            if len(parts) >= 4 and not _SIZE.match(parts[1]):
                command = parts[1]
                mem_tok, cmprs_tok = parts[2], parts[3]
            else:
                command = ""
                mem_tok, cmprs_tok = parts[1], parts[2]
            table[pid] = {
                "command": command,
                "mem_mb": round(parse_top_size(mem_tok), 1),
                "cmprs_mb": round(parse_top_size(cmprs_tok), 1),
            }
        except (ValueError, KeyError, IndexError):
            continue
    return table


def parse_vm_stat(text: str) -> dict[str, int]:
    """vm_stat 文本 -> 页计数字典。页大小优先读文件头，读不到就 0 让调用方用 sysctl。"""
    pages: dict[str, int] = {"page_size": 0}
    key_map = {
        "Pages free": "free",
        "Pages active": "active",
        "Pages inactive": "inactive",
        "Pages speculative": "speculative",
        "Pages wired down": "wired",
        "Pages purgeable": "purgeable",
        "File-backed pages": "file",
        "Anonymous pages": "anonymous",
        "Pages stored in compressor": "stored",
        "Pages occupied by compressor": "occupied",
    }
    for line in (text or "").splitlines():
        if "page size of" in line:
            got = re.search(r"page size of (\d+)", line)
            if got:
                pages["page_size"] = int(got.group(1))
            continue
        for needle, name in key_map.items():
            if needle in line:
                got = re.search(r"(\d+)\.?\s*$", line.replace(",", ""))
                if got:
                    pages[name] = int(got.group(1))
                break
    return pages


def parse_swapusage(text: str) -> dict[str, float]:
    """sysctl vm.swapusage -> MB。单位可能是 M，偶发 G。"""
    out = {"total_mb": 0.0, "used_mb": 0.0, "free_mb": 0.0}
    for key, dest in (("total", "total_mb"), ("used", "used_mb"), ("free", "free_mb")):
        got = re.search(rf"{key}\s*=\s*([0-9.]+)([MG])", text or "", re.I)
        if not got:
            continue
        value = float(got.group(1))
        out[dest] = value * (1024.0 if got.group(2).upper() == "G" else 1.0)
    return out


def parse_sysctl_int(text: str) -> int:
    text = (text or "").strip()
    if ":" in text:
        text = text.split(":", 1)[1].strip()
    try:
        return int(text.split()[0])
    except (ValueError, IndexError):
        return 0


def panel_from_sources(
    *,
    hw_mem_bytes: int,
    page_size: int,
    vm_pages: dict[str, int],
    pageable_internal: int,
    swap: dict[str, float],
    memorystatus_level: int,
    pressure_level: int,
) -> dict:
    """从系统计数拼出面板；页大小缺失时拒绝猜测。"""
    page = page_size or vm_pages.get("page_size") or 0
    if page <= 0:
        raise ValueError("vm_stat/sysctl 没给页大小，拒绝按 4096 或 16384 猜")
    purgeable = int(vm_pages.get("purgeable") or 0)
    app = max(0, pageable_internal - purgeable) * page
    wired = int(vm_pages.get("wired") or 0) * page
    compressed = int(vm_pages.get("occupied") or 0) * page
    stored = int(vm_pages.get("stored") or 0) * page
    total = hw_mem_bytes
    used = app + wired + compressed
    available = (int(vm_pages.get("free") or 0) + int(vm_pages.get("inactive") or 0)) * page
    free_pct = max(0, min(100, memorystatus_level))
    pressure_pct = 100 - free_pct
    level = pressure_level if pressure_level in (0, 1, 2, 4) else 1
    level_name = {0: "正常", 1: "正常", 2: "警告", 4: "危急"}.get(level, "未知")
    return {
        "total_bytes": total,
        "app_bytes": app,
        "wired_bytes": wired,
        "compressed_bytes": compressed,
        "available_bytes": available,
        "used_bytes": used,
        "stored_in_compressor_bytes": stored,
        "free_pages_bytes": int(vm_pages.get("free") or 0) * page,
        "file_backed_bytes": int(vm_pages.get("file") or 0) * page,
        "anonymous_bytes": int(vm_pages.get("anonymous") or 0) * page,
        "page_size": page,
        "swap_used_mb": swap.get("used_mb", 0.0),
        "swap_total_mb": swap.get("total_mb", 0.0),
        "swap_free_mb": swap.get("free_mb", 0.0),
        "pressure_pct": pressure_pct,
        "memorystatus_free_pct": free_pct,
        "pressure_level": level,
        "pressure_level_name": level_name,
    }


def reconcile(panel: dict, processes: list[dict]) -> dict:
    """进程 top MEM 求和 vs 面板已用，对一次账。

    调整：sum(所有进程 MEM) − 压缩器现占。
    为什么减一次：kernel_task 的 MEM 已经把压缩器算进去了，
    用户进程的 MEM 有时也含自己的 CMPRS，不减会算两次。
    目标是面板的 App+联动+已压缩。
    """
    kernel = next((p for p in processes if p.get("is_kernel")), None)
    user = [p for p in processes if not p.get("is_kernel")]
    sum_all_mem = sum(float(p.get("mem_mb") or 0) for p in processes) * MIB
    user_mem = sum(float(p.get("mem_mb") or 0) for p in user) * MIB
    user_cmprs = sum(float(p.get("cmprs_mb") or 0) for p in user) * MIB
    kernel_mem = float((kernel or {}).get("mem_mb") or 0) * MIB
    compressed = int(panel.get("compressed_bytes") or 0)
    reconstructed = max(0.0, sum_all_mem - compressed)
    target = int(panel.get("used_bytes") or 0)
    delta = abs(reconstructed - target)
    rel = (delta / target) if target else (0.0 if reconstructed == 0 else 1.0)
    trusted = True
    reason = "对得上"
    if not processes:
        trusted = False
        reason = "进程表是空的，top 没采到任何行"
    elif target <= 0:
        trusted = False
        reason = "vm_stat 推出的已用是 0，面板本身不可信"
    elif delta > RECONCILE_ABS_TOL_BYTES and rel > RECONCILE_REL_TOL:
        trusted = False
        reason = (
            f"进程求和调整后 {_gb(reconstructed)}，"
            f"面板已用 {_gb(target)}，"
            f"差 {_gb(delta)}（{rel:.0%}）。"
            "相对和绝对都越过容差，读数不可信"
        )
    return {
        "trusted": trusted,
        "reason": reason,
        "reconstructed_bytes": int(reconstructed),
        "target_bytes": target,
        "delta_bytes": int(delta),
        "rel": round(rel, 4),
        "sum_all_mem_bytes": int(sum_all_mem),
        "user_mem_bytes": int(user_mem),
        "user_cmprs_bytes": int(user_cmprs),
        "kernel_mem_bytes": int(kernel_mem),
        "rel_tol": RECONCILE_REL_TOL,
        "abs_tol_bytes": RECONCILE_ABS_TOL_BYTES,
    }


def app_label(command: str, comm: str = "", exe_path: str = "") -> dict[str, str]:
    """从路径 / 命令行推出 iStat 那种短标签。推不出就如实用 comm，不猜品牌。"""
    blob = " ".join(x for x in (exe_path, command, comm) if x)
    comm = comm or Path((exe_path or command or "").split()[0] if (exe_path or command) else "unknown").name

    if comm == "kernel_task" or command.startswith("kernel_task"):
        # 只把 kernel_task 标成 macOS。launchd 只有几十 MB，并进去会污染 17 G 那一行。
        return {"label": "macOS", "kind": "macos"}

    for regex in (_APP_PATH, _SYS_APP_PATH):
        got = regex.search(blob)
        if got:
            name = _strip_app_suffix(got.group(1))
            return {"label": name, "kind": "app"}

    helper = _HELPER.match(comm)
    if helper:
        return {"label": helper.group(1), "kind": "app"}

    port = _NEXT_PORT.search(command)
    if is_next_dev_command(command):
        if port:
            return {"label": f"next dev -p {port.group(1)}", "kind": "cli"}
        return {"label": "next-server", "kind": "cli"}

    if _looks_like_cli(comm):
        return {"label": _cli_short_label(command, comm), "kind": "cli"}

    if comm:
        return {"label": comm, "kind": "other"}
    return {"label": "unknown", "kind": "other"}


def _strip_app_suffix(name: str) -> str:
    return re.sub(r"\.app$", "", name)


def is_next_dev_command(command: str) -> bool:
    """必须是真的 next 进程，不能是命令行里恰好写了这两个词的 agent。

    本机 cursor-agent 的 argv 会把整份工单贴进去，里面反复出现 next dev。
    第一版用子串匹配会把它收进 next 名单，--apply 时会误杀自己。
    """
    if not command:
        return False
    if len(command) > 400:
        return False
    if re.search(r"next-server\s+\(v", command):
        return True
    if re.search(r"next/dist/bin/next\s+dev\b", command):
        return True
    if re.search(r"\bnext\s+dev\s+-p\s+\d+", command) and "node" in command:
        return True
    if re.search(r"\bnpm\s+exec\s+next\s+dev\s+-p\s+\d+", command):
        return True
    if re.search(r"\bnpm\s+run\s+dev:next\b", command):
        return True
    return False


def classify_ours(
    command: str,
    cwd: str = "",
    comm: str = "",
    exe_path: str = "",
) -> str:
    """把一条进程归进「我们这边」的类别。同一份表只走这一个函数。

    判据是命令行全文加工作目录，不按可执行文件名猜。
    今天主控靠名字找归属连栽两次（用户模拟实例误判成走查、别人的线误认成泄漏源）。
    推不出就归认不出，不许藏起来装精确。
    """
    command = command or ""
    cwd = cwd or ""
    comm = comm or ""
    exe_path = exe_path or ""

    # 先认 AI 窗口和派工。cursor-agent 会把整份工单贴进 argv，
    # 里面会出现 next dev / playwright / babysitter，按正文搜会归错族。
    if _is_dispatch(command, comm, exe_path, cwd):
        return OURS_CAT_DISPATCH
    if _is_ai_window(command, comm, exe_path, cwd):
        return OURS_CAT_AI_WINDOW
    if _is_cursor_app(command, comm, exe_path, cwd):
        return OURS_CAT_CURSOR_APP
    if is_next_dev_command(command):
        return OURS_CAT_NEXT_DEV
    if _is_lang_server(command, comm, exe_path, cwd):
        return OURS_CAT_LANG_SERVER
    if _is_browser_mcp(command, comm, exe_path, cwd):
        return OURS_CAT_BROWSER_MCP
    if _is_repo_script(command, comm, exe_path, cwd):
        return OURS_CAT_REPO_SCRIPT
    if _is_foreign_app(command, comm, exe_path):
        return OURS_CAT_NOT_OURS
    if _is_ours_candidate(command, comm, exe_path, cwd):
        return OURS_CAT_UNKNOWN
    return OURS_CAT_NOT_OURS


def _proc_basename(command: str, comm: str, exe_path: str) -> str:
    if comm:
        return Path(comm).name
    token = (exe_path or command.split(None, 1)[0] if command else "") or ""
    return Path(token).name


def _argv_prefix(command: str, limit: int = 400) -> str:
    """只看命令行前面，避开 agent 把工单全文贴进 argv 的那段。"""
    return (command or "")[:limit]


def _command_has_token(command: str, token: str, window: int = 8) -> bool:
    parts = (command or "").split()
    return token in parts[1:window]


def _is_dispatch(command: str, comm: str, exe_path: str, cwd: str) -> bool:
    head = _argv_prefix(command, 360)
    blob = f"{exe_path}\n{head}\n{cwd}"
    if "codex_babysitter.py" in blob or "codex_babysitter" in head:
        return True
    if "grok_dispatch.py" in blob:
        return True
    base = _proc_basename(command, comm, exe_path)
    if base == "codex" and _command_has_token(command, "exec"):
        return True
    return False


def _is_ai_window(command: str, comm: str, exe_path: str, cwd: str) -> bool:
    base = _proc_basename(command, comm, exe_path)
    if base in {"cursor-agent", "claude"}:
        return True
    if base == "codex" and not _command_has_token(command, "exec"):
        return True
    path_blob = f"{exe_path} {command.split(None, 1)[0] if command else ''} {cwd}"
    if "/Applications/Claude.app/" in path_blob:
        return True
    if comm == "Claude" or comm.startswith("Claude Helper"):
        return True
    return False


def _is_cursor_app(command: str, comm: str, exe_path: str, cwd: str) -> bool:
    # cursor-agent 有时住在 Cursor.app 里，调用方已经先判过 AI 窗口。
    path_blob = f"{exe_path}\n{command.split(None, 1)[0] if command else ''}\n{cwd}"
    if "/Applications/Cursor.app/" in path_blob:
        return True
    if comm == "Cursor" or comm.startswith("Cursor Helper"):
        return True
    return False


def _is_lang_server(command: str, comm: str, exe_path: str, cwd: str) -> bool:
    head = _argv_prefix(command)
    blob = f"{exe_path}\n{head}\n{cwd}"
    if "typescript-language-server" in blob:
        return True
    if "tsserver" in blob or "typingsinstaller" in blob.lower():
        return True
    return False


def _is_chrome_family(command: str, comm: str, exe_path: str) -> bool:
    blob = f"{exe_path} {comm} {command[:240]}".lower()
    return any(
        n in blob
        for n in (
            "google chrome",
            "chrome helper",
            "chromium",
            "chrome for testing",
            "/chrome",
            "chromedriver",
        )
    )


def _is_browser_mcp(command: str, comm: str, exe_path: str, cwd: str) -> bool:
    head = _argv_prefix(command)
    blob = f"{exe_path}\n{head}\n{cwd}".lower()
    if "chrome-devtools-mcp" in blob or "playwright-mcp" in blob:
        return True
    if "playwright" in blob or "ms-playwright" in blob:
        return True
    if "mcp-server" in blob or re.search(r"[\w-]*mcp[\w-]*(?:$|[\s/@])", head):
        return True
    if "dbhub" in head and ("--dsn" in head or "/.npm/" in head):
        return True
    if not _is_chrome_family(command, comm, exe_path):
        return False
    if re.search(r"--headless(?:[=\s]|$)", head):
        return True
    if "--user-data-dir=/tmp/" in head or "--user-data-dir=/tmp" in head:
        return True
    return False


def _is_repo_script(command: str, comm: str, exe_path: str, cwd: str) -> bool:
    blob = f"{exe_path}\n{cwd}\n{_argv_prefix(command)}"
    runtime = _is_script_runtime(command, comm, exe_path)
    if runtime and "cortex-worktrees/" in blob:
        return True
    if runtime and "/bin/python" in blob and _in_cortex_tree(command, cwd, exe_path):
        return True
    return False


def _is_script_runtime(command: str, comm: str, exe_path: str) -> bool:
    base = _proc_basename(command, comm, exe_path).lower()
    if base in _SCRIPT_RUNTIME or base.startswith("python"):
        return True
    first = (exe_path or (command.split(None, 1)[0] if command else "")).lower()
    return any(name in first for name in ("/python", "/node", "/npm", "/npx"))


def _is_foreign_app(command: str, comm: str, exe_path: str) -> bool:
    blob = f"{exe_path} {command.split(None, 1)[0] if command else ''}"
    for regex in (_APP_PATH, _SYS_APP_PATH):
        got = regex.search(blob)
        if not got:
            continue
        name = got.group(1)
        if name in {"Cursor", "Claude"}:
            return False
        return True
    if comm == "kernel_task" or command.startswith("kernel_task"):
        return True
    return False


def _in_cortex_tree(command: str, cwd: str, exe_path: str) -> bool:
    blob = f"{exe_path}\n{cwd}\n{_argv_prefix(command)}"
    if "cortex-worktrees/" in blob:
        return True
    try:
        from cortex_sentinel.paths import find_project, projects
    except Exception:
        return blob.rstrip().endswith("/cortex")
    if cwd:
        try:
            if find_project(Path(cwd)):
                return True
        except Exception:
            pass
    for row in projects():
        root = str(row.get("root") or "").rstrip("/")
        if root and root in blob:
            return True
    return blob.rstrip().endswith("/cortex")


def _is_ours_candidate(command: str, comm: str, exe_path: str, cwd: str) -> bool:
    # 别的项目的 node/python 不是「认不出」，是别人的。
    # 认不出只留给落在我们树上、却对不上上面那些类的进程。
    return _in_cortex_tree(command, cwd, exe_path)


def attach_ours_categories(processes: list[dict]) -> list[dict]:
    for row in processes:
        row["ours_cat"] = classify_ours(
            str(row.get("command") or ""),
            cwd=str(row.get("cwd") or ""),
            comm=str(row.get("comm") or ""),
            exe_path=str(row.get("exe_path") or ""),
        )
    return processes


def summarize_ours(processes: list[dict]) -> dict:
    """按类别加总。占用一律用 top MEM，不用 RSS。"""
    attach_ours_categories(processes)
    buckets: dict[str, dict] = {
        key: {"cat": key, "label": label, "mem_mb": 0.0, "cmprs_mb": 0.0, "rss_mb": 0.0, "procs": 0, "pids": []}
        for key, label in OURS_BUCKET_LABELS
    }
    for row in processes:
        cat = str(row.get("ours_cat") or OURS_CAT_NOT_OURS)
        if cat not in buckets:
            continue
        slot = buckets[cat]
        slot["mem_mb"] += float(row.get("mem_mb") or 0)
        slot["cmprs_mb"] += float(row.get("cmprs_mb") or 0)
        slot["rss_mb"] += float(row.get("rss_mb") or 0)
        slot["procs"] += 1
        slot["pids"].append(int(row.get("pid") or 0))
    for slot in buckets.values():
        slot["mem_mb"] = round(slot["mem_mb"], 1)
        slot["cmprs_mb"] = round(slot["cmprs_mb"], 1)
        slot["rss_mb"] = round(slot["rss_mb"], 1)
        slot["pids"] = [pid for pid in slot["pids"] if pid][:16]
    total_mb = sum(buckets[cat]["mem_mb"] for cat in OURS_TOTAL_CATS)
    cmprs_mb = sum(buckets[cat]["cmprs_mb"] for cat in OURS_TOTAL_CATS)
    unknown_mb = buckets[OURS_CAT_UNKNOWN]["mem_mb"]
    cursor_mb = buckets[OURS_CAT_CURSOR_APP]["mem_mb"]
    stacked_mb = total_mb + unknown_mb
    remaining = OURS_BUDGET_BYTES - total_mb * MIB
    return {
        "budget_bytes": OURS_BUDGET_BYTES,
        "total_bytes": int(total_mb * MIB),
        "cmprs_bytes": int(cmprs_mb * MIB),
        "cursor_bytes": int(cursor_mb * MIB),
        "unknown_bytes": int(unknown_mb * MIB),
        "stacked_bytes": int(stacked_mb * MIB),
        "remaining_bytes": int(remaining),
        "over_budget": remaining < 0,
        "buckets": [buckets[key] for key, _label in OURS_BUCKET_LABELS],
    }


def unused_servers_from_processes(
    processes: list[dict],
    *,
    now: float,
    state: dict,
    path_exists: Callable[[str], bool],
    has_live_client: Callable[[int], bool],
    offenders: dict | None = None,
) -> list[dict]:
    """占着不用：把同一份表里的 next dev 交给清理器判定，不另写一套。"""
    reaper = _reaper()
    rows: list[dict] = []
    for proc in processes:
        cat = proc.get("ours_cat") or classify_ours(
            str(proc.get("command") or ""),
            cwd=str(proc.get("cwd") or ""),
            comm=str(proc.get("comm") or ""),
            exe_path=str(proc.get("exe_path") or ""),
        )
        if cat != OURS_CAT_NEXT_DEV:
            continue
        command = str(proc.get("command") or "")
        cwd = str(proc.get("cwd") or "")
        label = str(proc.get("label") or "")
        port_match = _NEXT_PORT.search(command) or _NEXT_PORT.search(label)
        port = int(port_match.group(1)) if port_match else proc.get("port")
        owner = reaper.infer_owner(cwd, command)
        rows.append(
            {
                "pid": int(proc.get("pid") or 0),
                "ppid": int(proc.get("ppid") or 0),
                "port": int(port) if port is not None else None,
                "cwd": cwd,
                "mem_mb": float(proc.get("mem_mb") or 0),
                "cmprs_mb": float(proc.get("cmprs_mb") or 0),
                "age_hours": float(proc.get("age_hours") or 0),
                "managed": bool(proc.get("managed")),
                "never_touch": bool(proc.get("never_touch")),
                "protected": bool(proc.get("protected") or proc.get("managed") or proc.get("never_touch")),
                "owner": owner["owner"],
                "worktree": owner["worktree"],
                "command": command[:160],
            }
        )
    reaper.evaluate_rows(
        rows,
        cap_mb=reaper.DEFAULT_CAP_MB,
        orphan_hours=reaper.DEFAULT_ORPHAN_HOURS,
        state=state,
        now=now,
        offenders=offenders or {},
        path_exists=path_exists,
        has_live_client=has_live_client,
    )
    unused = [row for row in rows if row.get("verdict") in UNUSED_VERDICTS]
    unused.sort(key=lambda row: -float(row.get("mem_mb") or 0))
    return unused


def _reaper():
    # 延迟导入：清理器会 import 本文件的 is_next_dev_command，顶层互引会炸。
    from cortex_sentinel import devserver as reaper

    return reaper


def parse_lsof_cwd(text: str) -> dict[int, str]:
    table: dict[int, str] = {}
    pid = 0
    for line in (text or "").splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid = int(line[1:])
            continue
        if pid and line.startswith("n"):
            table[pid] = line[1:]
            pid = 0
    return table


def parse_etime_hours(etime: str) -> float:
    days = 0
    rest = etime or ""
    if "-" in rest:
        head, rest = rest.split("-", 1)
        try:
            days = int(head)
        except ValueError:
            days = 0
    try:
        bits = [int(x) for x in rest.split(":")]
    except ValueError:
        return 0.0
    while len(bits) < 3:
        bits.insert(0, 0)
    hours, minutes, seconds = bits[-3], bits[-2], bits[-1]
    return days * 24 + hours + minutes / 60 + seconds / 3600


def attach_cwds(processes: list[dict], runner: Runner | None = None) -> None:
    need = [
        int(p["pid"])
        for p in processes
        if _needs_cwd(p) and not p.get("cwd")
    ]
    by_pid: dict[int, str] = {}
    for start in range(0, len(need), 40):
        chunk = need[start : start + 40]
        if not chunk:
            continue
        text = _run(
            ["lsof", "-nP", "-a", "-d", "cwd", "-p", ",".join(str(pid) for pid in chunk), "-Fn"],
            timeout=30,
            runner=runner,
        )
        by_pid.update(parse_lsof_cwd(text))
    for row in processes:
        if not row.get("cwd"):
            row["cwd"] = by_pid.get(int(row["pid"]), "")


def _needs_cwd(row: dict) -> bool:
    comm = str(row.get("comm") or "")
    command = str(row.get("command") or "")
    exe_path = str(row.get("exe_path") or "")
    if _is_script_runtime(command, comm, exe_path) or _is_chrome_family(command, comm, exe_path):
        return True
    base = comm.lower()
    return base in _CANDIDATE_COMM or base.startswith("python") or base.startswith("chrome")


def attach_etimes(processes: list[dict], runner: Runner | None = None) -> None:
    text = _run(["ps", "-axo", "pid=,etime="], runner=runner)
    table: dict[int, float] = {}
    for line in (text or "").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].isdigit():
            table[int(parts[0])] = parse_etime_hours(parts[1])
    for row in processes:
        if not row.get("age_hours"):
            row["age_hours"] = table.get(int(row["pid"]), 0.0)


def attach_managed_flags(processes: list[dict], runner: Runner | None = None) -> None:
    reaper = _reaper()
    web_tree = reaper.launchd_tree(reaper.MANAGED_WEB_LABEL, runner=runner)
    never: set[int] = set()
    never_labels: dict[int, str] = {}
    for label in reaper.PROTECTED_NEVER_TOUCH:
        tree = reaper.launchd_tree(label, runner=runner)
        never |= tree
        for pid in tree:
            never_labels[pid] = label
    for row in processes:
        pid = int(row["pid"])
        row.setdefault("managed", pid in web_tree)
        row.setdefault("never_touch", pid in never)
        row.setdefault("protected", bool(row["managed"] or row["never_touch"]))
        if pid in never_labels:
            row.setdefault("protect_label", never_labels[pid])


def _looks_like_cli(comm: str) -> bool:
    return comm.lower() in {
        "node",
        "nodejs",
        "npm",
        "npx",
        "python",
        "python3",
        "python3.12",
        "python3.13",
        "ruby",
        "perl",
        "php",
        "java",
        "go",
        "rustc",
        "cargo",
    }


def _cli_short_label(command: str, comm: str) -> str:
    tokens = command.split()
    useful = [t for t in tokens[1:] if not t.startswith("-") or t.startswith("-p")]
    if comm.lower() in {"npm", "npx"} and any("next" in t for t in tokens):
        port = _NEXT_PORT.search(command)
        if port:
            return f"npm exec next dev -p {port.group(1)}"
    if useful:
        head = Path(useful[0]).name
        extra = []
        for tok in useful[1:3]:
            extra.append(Path(tok).name if "/" in tok else tok)
        label = " ".join([comm, head, *extra]).strip()
        return label[:48]
    return comm


def attach_labels(processes: list[dict]) -> list[dict]:
    for row in processes:
        meta = app_label(
            str(row.get("command") or ""),
            comm=str(row.get("comm") or ""),
            exe_path=str(row.get("exe_path") or ""),
        )
        row["label"] = meta["label"]
        row["kind"] = meta["kind"]
        row["is_kernel"] = meta["kind"] == "macos" and meta["label"] == "macOS"
    _inherit_next_dev_ports(processes)
    return processes


def _inherit_next_dev_ports(processes: list[dict]) -> None:
    """next-server 子进程命令行没有 -p，端口写在父进程上。不继承的话
    三个实例会糊成一行「next-server」，跟 iStat 的 next dev -p 247x 对不上。"""
    by_pid = {int(p["pid"]): p for p in processes}
    for row in processes:
        label = str(row.get("label") or "")
        if label.startswith("next dev -p "):
            continue
        command = str(row.get("command") or "")
        if "next-server" not in command and "next/dist/bin/next" not in command:
            continue
        hop = int(row.get("ppid") or 0)
        for _ in range(4):
            parent = by_pid.get(hop)
            if not parent:
                break
            parent_label = str(parent.get("label") or "")
            if parent_label.startswith("next dev -p "):
                row["label"] = parent_label
                row["kind"] = "cli"
                break
            hop = int(parent.get("ppid") or 0)



def aggregate_apps(processes: list[dict]) -> list[dict]:
    """同一 App 的 helper / GPU / Renderer 合并。CLI 按短标签合并。"""
    buckets: dict[str, dict] = {}
    for row in processes:
        label = str(row.get("label") or "unknown")
        slot = buckets.setdefault(
            label,
            {
                "label": label,
                "kind": row.get("kind") or "other",
                "mem_mb": 0.0,
                "cmprs_mb": 0.0,
                "procs": 0,
                "pids": [],
                "is_kernel": bool(row.get("is_kernel")),
            },
        )
        slot["mem_mb"] += float(row.get("mem_mb") or 0)
        slot["cmprs_mb"] += float(row.get("cmprs_mb") or 0)
        slot["procs"] += 1
        slot["pids"].append(int(row["pid"]))
    ranked = sorted(buckets.values(), key=lambda s: -s["mem_mb"])
    for slot in ranked:
        slot["mem_mb"] = round(slot["mem_mb"], 1)
        slot["cmprs_mb"] = round(slot["cmprs_mb"], 1)
        slot["pids"] = slot["pids"][:12]
    return ranked


def parse_ps_table(text: str) -> dict[int, dict]:
    table: dict[int, dict] = {}
    for line in (text or "").splitlines():
        got = _PS_LINE.match(line)
        if not got:
            continue
        rss_kb, pid_s, ppid_s, command = got.groups()
        pid = int(pid_s)
        first = command.split()[0] if command.split() else ""
        comm = Path(first).name if first else "unknown"
        table[pid] = {
            "pid": pid,
            "ppid": int(ppid_s),
            "rss_kb": int(rss_kb),
            "command": command,
            "comm": comm,
            "exe_path": first if first.startswith("/") else "",
        }
    return table


def merge_top_and_ps(
    top_table: dict[int, dict[str, float | str]],
    ps_table: dict[int, dict],
) -> list[dict]:
    pids = set(top_table) | set(ps_table)
    rows: list[dict] = []
    for pid in pids:
        top = top_table.get(pid, {})
        ps = ps_table.get(pid, {})
        command = str(ps.get("command") or top.get("command") or "")
        comm = str(ps.get("comm") or top.get("command") or "")
        mem_mb = float(top.get("mem_mb") or 0.0)
        if not top and ps:
            # top 没覆盖到的小进程才退回 RSS。大头必须走 top，否则又失明。
            mem_mb = int(ps.get("rss_kb") or 0) / 1024.0
        row = {
            "pid": pid,
            "ppid": int(ps.get("ppid") or 0),
            "command": command,
            "comm": comm,
            "exe_path": str(ps.get("exe_path") or ""),
            "mem_mb": round(mem_mb, 1),
            "cmprs_mb": round(float(top.get("cmprs_mb") or 0.0), 1),
            "rss_mb": round(int(ps.get("rss_kb") or 0) / 1024.0, 1),
        }
        rows.append(row)
    attach_labels(rows)
    return rows


def parse_zprint_wired(text: str) -> list[dict]:
    """zprint 后半段 wired 账。跳过虚拟地址空间那几行（上百 GB，不是 RAM）。"""
    skip = (
        "VM_KERN_COUNT_MAP_",
        "VM_KERN_COUNT_MANAGED",
        "maps",
        "largest",
        "free",
        "zone name",
        "wired memory",
        "----",
    )
    rows: list[dict] = []
    in_wired = False
    for line in (text or "").splitlines():
        if line.startswith("wired memory") or line.startswith("VM_KERN_MEMORY_"):
            in_wired = True
        if not in_wired:
            continue
        if any(line.strip().startswith(s) and "K" not in line for s in ("maps", "largest")):
            continue
        if any(s in line and not line.strip()[0:3].isdigit() for s in skip if s.startswith("----")):
            continue
        got = _ZPRINT_SIZE_K.search(line)
        if not got:
            continue
        kb = int(got.group(1))
        name = line[:56].strip()
        if not name or name in {"total", "zones"}:
            if name == "total":
                rows.append({"name": "zprint_total", "bytes": kb * 1024, "group": "total"})
            continue
        if name.startswith("VM_KERN_COUNT_MAP_") or name.startswith("VM_KERN_COUNT_MANAGED"):
            # 这是内核虚拟映射上限，851 GB 那种，写进报告会吓人且是错的
            continue
        rows.append({"name": name, "bytes": kb * 1024, "group": _wired_group(name)})
    rows.sort(key=lambda r: -r["bytes"])
    return rows


def _wired_group(name: str) -> str:
    n = name.lower()
    if "iogpu" in n or "agx" in n or "iosurface" in n or "graphics" in n or "disp" in n:
        return "gpu"
    if "pte" in n:
        return "pagetable"
    if "skywalk" in n or "mbuf" in n or "tcp" in n:
        return "network"
    if "iokit" in n or "driver" in n or "audio" in n:
        return "iokit"
    if name.startswith("VM_KERN_"):
        return "kernel"
    return "other"


def parse_zprint_zones(text: str) -> list[dict]:
    """zone 段：无 root 时 cur size 经常是 0K，改用 elem × inuse。"""
    rows: list[dict] = []
    for line in (text or "").splitlines():
        if line.startswith("wired memory"):
            break
        got = _ZPRINT_ZONE.match(line)
        if not got:
            continue
        name, elem_s, _cur, _mx, _celts, _melts, inuse_s = got.groups()
        elem = int(elem_s)
        inuse = int(inuse_s)
        rows.append({"name": name, "elem": elem, "inuse": inuse, "bytes": elem * inuse})
    rows.sort(key=lambda r: -r["bytes"])
    return rows


def _run(args: list[str], timeout: float = 60.0, runner: Runner | None = None) -> str:
    if runner is not None:
        return runner(args)
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def collect_snapshot(runner: Runner | None = None) -> dict:
    vm_text = _run(["vm_stat"], runner=runner)
    swap_text = _run(["sysctl", "-n", "vm.swapusage"], runner=runner)
    hw_text = _run(["sysctl", "-n", "hw.memsize"], runner=runner)
    internal_text = _run(["sysctl", "-n", "vm.page_pageable_internal_count"], runner=runner)
    level_text = _run(["sysctl", "-n", "kern.memorystatus_level"], runner=runner)
    pressure_text = _run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], runner=runner)
    # logging 模式下 -n 是采样次数不是进程数；只传 -l 1，把全部进程要过来
    top_text = _run(["top", "-l", "1", "-stats", "pid,command,mem,cmprs"], timeout=90, runner=runner)
    ps_text = _run(["ps", "-axww", "-o", "rss=,pid=,ppid=,command="], runner=runner)

    vm_pages = parse_vm_stat(vm_text)
    page_size = int(vm_pages.get("page_size") or 0)
    panel = panel_from_sources(
        hw_mem_bytes=parse_sysctl_int(hw_text) or 0,
        page_size=page_size,
        vm_pages=vm_pages,
        pageable_internal=parse_sysctl_int(internal_text),
        swap=parse_swapusage(swap_text),
        memorystatus_level=parse_sysctl_int(level_text),
        pressure_level=parse_sysctl_int(pressure_text),
    )
    processes = merge_top_and_ps(parse_top_table(top_text), parse_ps_table(ps_text))
    apps = aggregate_apps(processes)
    check = reconcile(panel, processes)
    kernel = next((p for p in processes if p.get("is_kernel")), None)
    kernel_mem = float((kernel or {}).get("mem_mb") or 0) * MIB
    compressor = int(panel["compressed_bytes"])
    kernel_own = max(0.0, kernel_mem - compressor)
    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "panel": panel,
        "apps": apps,
        "processes": processes,
        "reconcile": check,
        "kernel": {
            "mem_bytes": int(kernel_mem),
            "compressor_bytes": compressor,
            "own_bytes": int(kernel_own),
            "stored_bytes": int(panel["stored_in_compressor_bytes"]),
            "ratio_compressor": round(compressor / kernel_mem, 3) if kernel_mem else 0.0,
        },
        "proc_count": len(processes),
    }


def collect_ours(
    snapshot: dict | None = None,
    runner: Runner | None = None,
    *,
    live: bool = True,
    now: float | None = None,
    idle_state: dict | None = None,
    offenders: dict | None = None,
    path_exists: Callable[[str], bool] | None = None,
    has_live_client: Callable[[int], bool] | None = None,
) -> dict:
    """同一份采样上归类。live=False 时不碰 lsof / launchctl，测试用构造表。"""
    snap = snapshot or collect_snapshot(runner=runner)
    processes = snap["processes"]
    if live:
        attach_cwds(processes, runner=runner)
        attach_etimes(processes, runner=runner)
        attach_managed_flags(processes, runner=runner)
    attach_ours_categories(processes)
    ours = summarize_ours(processes)
    reaper = _reaper()
    if idle_state is None and live:
        raw_state = reaper.load_json(reaper.STATE_PATH)
        idle_state = {k: v for k, v in raw_state.items() if isinstance(v, (int, float))}
    if offenders is None and live:
        offenders = reaper.load_json(reaper.OFFENDER_PATH)
    if path_exists is None:
        path_exists = reaper._path_exists
    if has_live_client is None:
        has_live_client = lambda port: reaper.port_has_live_client(port, runner=runner)
    unused = unused_servers_from_processes(
        processes,
        now=now if now is not None else time.time(),
        state=idle_state or {},
        path_exists=path_exists,
        has_live_client=has_live_client,
        offenders=offenders or {},
    )
    return {**snap, "ours": ours, "unused": unused}


def collect_breakdown(snapshot: dict | None = None, runner: Runner | None = None) -> dict:
    """拆开 macOS / 联动 / 压缩器。命令失败就空着，不编数字。"""
    snap = snapshot or collect_snapshot(runner=runner)
    zprint_text = _run(["zprint"], timeout=30, runner=runner)
    ioreg_text = _run(
        ["ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"],
        timeout=20,
        runner=runner,
    )
    wired_rows = parse_zprint_wired(zprint_text)
    zones = parse_zprint_zones(zprint_text)
    gpu_bytes = _gpu_in_use_bytes(ioreg_text)
    services = _service_footprints(snap["processes"])
    cmprs_rank = sorted(snap["processes"], key=lambda p: -float(p.get("cmprs_mb") or 0))[:20]
    wired_groups: dict[str, int] = defaultdict(int)
    for row in wired_rows:
        if row["name"] in {"zprint_total", "VM_KERN_COUNT_WIRED", "VM_KERN_COUNT_WIRED_MANAGED"}:
            continue
        wired_groups[row["group"]] += int(row["bytes"])
    return {
        **snap,
        "wired_rows": wired_rows[:30],
        "wired_groups": dict(wired_groups),
        "zones": zones[:20],
        "gpu_in_use_bytes": gpu_bytes,
        "services": services,
        "cmprs_rank": [
            {
                "pid": p["pid"],
                "label": p.get("label"),
                "comm": p.get("comm"),
                "mem_mb": p.get("mem_mb"),
                "cmprs_mb": p.get("cmprs_mb"),
                "command": (p.get("command") or "")[:120],
            }
            for p in cmprs_rank
            if float(p.get("cmprs_mb") or 0) > 0
        ],
    }


def _gpu_in_use_bytes(ioreg_text: str) -> int:
    got = re.search(r'"In use system memory"\s*=\s*(\d+)', ioreg_text or "")
    return int(got.group(1)) if got else 0


def _service_footprints(processes: list[dict]) -> list[dict]:
    needles = {
        "Spotlight": ("mds", "mds_stores", "mdworker", "mdbulkimport"),
        "时间机器": ("backupd", "backupd-helper"),
        "云盘": ("bird", "cloudd", "fileproviderd"),
        "窗口服务": ("WindowServer",),
        "查找": ("Finder",),
    }
    out = []
    for title, names in needles.items():
        matched = [p for p in processes if p.get("comm") in names or any(n == p.get("comm") for n in names)]
        out.append(
            {
                "name": title,
                "procs": len(matched),
                "mem_mb": round(sum(float(p.get("mem_mb") or 0) for p in matched), 1),
                "cmprs_mb": round(sum(float(p.get("cmprs_mb") or 0) for p in matched), 1),
                "rss_mb": round(sum(float(p.get("rss_mb") or 0) for p in matched), 1),
            }
        )
    return out


def _gb(num: float | int) -> str:
    return f"{float(num) / GIB:.1f} GB"


def format_snapshot(snap: dict) -> str:
    panel = snap["panel"]
    check = snap["reconcile"]
    kernel = snap["kernel"]
    lines = [
        f"内存面板  {snap['ts']}  这台 {_gb(panel['total_bytes'])}",
        f"  App 内存          {_gb(panel['app_bytes'])}",
        f"  联动内存          {_gb(panel['wired_bytes'])}",
        f"  已压缩            {_gb(panel['compressed_bytes'])}",
        f"  可用              {_gb(panel['available_bytes'])}",
        (
            f"  压力              {panel['pressure_pct']}% "
            f"（系统判定还能腾出 {panel['memorystatus_free_pct']}%；"
            f"等级 {panel['pressure_level']} {panel['pressure_level_name']}）"
        ),
        (
            f"  已使用的交换      {panel['swap_used_mb'] / 1024:.1f} / "
            f"{panel['swap_total_mb'] / 1024:.1f} GB"
        ),
        "",
    ]
    if check["trusted"]:
        lines.append(
            f"读数自校验：可信（调整后 {_gb(check['reconstructed_bytes'])}，"
            f"面板已用 {_gb(check['target_bytes'])}，"
            f"差 {_gb(check['delta_bytes'])} / {check['rel']:.0%}）"
        )
        lines.append(
            f"  容差：相对 {int(RECONCILE_REL_TOL * 100)}% 且绝对 "
            f"{int(RECONCILE_ABS_TOL_BYTES / GIB)} GB 同时越过才报不可信。"
            "差额来自压缩器记在 kernel_task 头上、显卡统一内存、共享库。"
        )
    else:
        lines.append("读数不可信")
        lines.append(f"  {check['reason']}")
        lines.append("  下面的数字仅供排查，不要当精确值用。")
    lines += [
        "",
        f"kernel_task / macOS 拆开   面板上那一行 {_gb(kernel['mem_bytes'])}",
        (
            f"  压缩器现占      {_gb(kernel['compressor_bytes'])}   "
            f"装着用户进程被压扁的页（原始量 {_gb(kernel['stored_bytes'])}）"
        ),
        (
            f"  内核自己大约    {_gb(kernel['own_bytes'])}   "
            f"kernel_task {_gb(kernel['mem_bytes'])} − 压缩器 {_gb(kernel['compressor_bytes'])}"
        ),
    ]
    if kernel["mem_bytes"] and kernel["ratio_compressor"] >= 0.5:
        lines.append(
            f"  所以这 {_gb(kernel['mem_bytes'])} 里大约 "
            f"{kernel['ratio_compressor']:.0%} 不是系统开销，是有人在泄漏或没关。"
        )
    lines += ["", f"进程榜（按 App 聚合，占用是 top MEM；共 {snap['proc_count']} 个进程）"]
    for app in snap["apps"][:16]:
        tag = ""
        if app.get("is_kernel"):
            tag = "  ← 压缩器替别人站岗，见上面拆开"
        elif app["kind"] == "cli" and app["mem_mb"] >= 1024:
            tag = "  ← 命令行，忘关就会一直站着"
        lines.append(
            f"  {app['label']:<28} {_gb(app['mem_mb'] * MIB):>8}  "
            f"压缩 {_gb(app['cmprs_mb'] * MIB)}  {app['procs']} 个进程{tag}"
        )
    return "\n".join(lines) + "\n"


def format_ours(snap: dict) -> str:
    """一屏回答三问：一共占了多少、离 30G 还有多少、有没有占着不用的。"""
    panel = snap["panel"]
    check = snap["reconcile"]
    kernel = snap["kernel"]
    ours = snap["ours"]
    unused = snap.get("unused") or []
    remaining = int(ours["remaining_bytes"])
    if remaining >= 0:
        remain_text = f"{_gb(remaining)}"
    else:
        remain_text = f"超了 {_gb(-remaining)}"
    lines = [
        f"我们这边  {snap['ts']}  这台 {_gb(panel['total_bytes'])}",
        f"一共占了            {_gb(ours['total_bytes'])}",
        (
            f"离 30G 预算还剩      {remain_text}"
            "    （48G 机器留 18G 给你自己用；超了不杀，是要把没用的关掉）"
        ),
        "",
        "分类（占用是 top MEM，含被压缩的部分；Cursor 单列，不混进上面几行）",
    ]
    for bucket in ours["buckets"]:
        tag = ""
        if bucket["cat"] == OURS_CAT_CURSOR_APP:
            tag = "  ← 单列，算进总数"
        elif bucket["cat"] == OURS_CAT_UNKNOWN:
            tag = "  ← 判不出来，不进上面的合计"
        if (
            bucket["procs"] == 0
            and bucket["cat"] not in {OURS_CAT_UNKNOWN, OURS_CAT_CURSOR_APP}
        ):
            continue
        lines.append(
            f"  {bucket['label']:<18} {_gb(bucket['mem_mb'] * MIB):>8}  "
            f"压缩 {_gb(bucket['cmprs_mb'] * MIB)}  {bucket['procs']} 个进程{tag}"
        )
    if ours["unknown_bytes"]:
        lines.append(
            f"若把认不出也算进来  {_gb(ours['stacked_bytes'])}    "
            f"合计会变成这个数，说明判据还漏了 {_gb(ours['unknown_bytes'])}"
        )
    lines += [
        "",
        f"压缩器替我们站岗    {_gb(ours['cmprs_bytes'])}",
        (
            "  这些页记在 macOS / kernel_task 头上，本质是我们的进程被压扁，"
            "不是系统开销。"
        ),
        (
            f"  整机压缩器现占 {_gb(kernel['compressor_bytes'])}，"
            f"kernel_task 那一行 {_gb(kernel['mem_bytes'])}。"
        ),
        "",
    ]
    if unused:
        lines.append("占着不用（清理器的判定，这里只报不杀）")
        for row in unused:
            idle = row.get("idle_minutes")
            idle_txt = f"  闲 {idle:.0f} 分钟" if idle is not None else ""
            port = row.get("port")
            port_txt = f"port={port}" if port is not None else "port=?"
            lines.append(
                f"  [{row.get('verdict')}] pid={row.get('pid')}  {port_txt}  "
                f"{_gb(float(row.get('mem_mb') or 0) * MIB)}{idle_txt}"
            )
            lines.append(f"         {row.get('cwd') or '(cwd 取不到)'}")
    else:
        lines.append("占着不用：没有。清理器没扫到忘关的 next dev。")
    lines.append("")
    if check["trusted"]:
        lines.append(
            f"读数自校验：可信（调整后 {_gb(check['reconstructed_bytes'])}，"
            f"面板已用 {_gb(check['target_bytes'])}，"
            f"差 {_gb(check['delta_bytes'])} / {check['rel']:.0%}）"
        )
    else:
        lines.append("读数不可信")
        lines.append(f"  {check['reason']}")
        lines.append("  下面的数字仅供排查，不要当精确值用。")
    return "\n".join(lines) + "\n"


def format_breakdown(data: dict) -> str:
    lines = [format_snapshot(data).rstrip(), "", "—— 拆解（每项都能用旁边的命令复现）——", ""]
    lines.append("联动内存（wired）是谁")
    lines.append("  命令：zprint   （后半段 wired memory；MAP_* 那几行是虚拟地址，不是 RAM）")
    groups = data.get("wired_groups") or {}
    names = {
        "gpu": "显卡 / IOSurface / 显示",
        "pagetable": "页表（进程多、虚拟地址巨大时涨）",
        "iokit": "IOKit / 驱动 / 音频",
        "network": "网络缓冲",
        "kernel": "内核自己的标记桶",
        "other": "其余",
    }
    for key, title in names.items():
        if groups.get(key):
            lines.append(f"  {title:<28} {_gb(groups[key])}")
    if data.get("gpu_in_use_bytes"):
        lines.append(
            f"  显卡此刻在用（ioreg IOAccelerator）{_gb(data['gpu_in_use_bytes'])}"
        )
        lines.append('  命令：ioreg -r -d 1 -w 0 -c IOAccelerator | grep "In use system memory"')
    lines.append("  wired 排前面的条目：")
    for row in (data.get("wired_rows") or [])[:12]:
        if row["name"] in {"zprint_total"}:
            lines.append(f"    合计（zprint total）     {_gb(row['bytes'])}")
            continue
        lines.append(f"    {row['name']:<42} {_gb(row['bytes'])}")

    lines += ["", "内核 zone 按 elem×inuse（无 root 时 cur size 经常是 0K，所以用个数反推）"]
    lines.append("  命令：zprint")
    for zone in (data.get("zones") or [])[:8]:
        lines.append(
            f"  {zone['name']:<28} {_gb(zone['bytes'])}  "
            f"({zone['inuse']} × {zone['elem']} 字节)"
        )

    lines += ["", "后台服务（Spotlight / 时间机器 / 云盘 / 窗口）"]
    lines.append("  命令：top -l 1 -stats pid,command,mem,cmprs  再按进程名归类")
    for svc in data.get("services") or []:
        lines.append(
            f"  {svc['name']:<10} {svc['procs']:>3} 个进程  "
            f"MEM {_gb(svc['mem_mb'] * MIB)}  压缩 {_gb(svc['cmprs_mb'] * MIB)}  "
            f"RSS {_gb(svc['rss_mb'] * MIB)}"
        )

    lines += ["", "压缩器在替谁存（top CMPRS 从大到小）"]
    lines.append("  命令：top -l 1 -stats pid,command,mem,cmprs")
    for row in (data.get("cmprs_rank") or [])[:12]:
        lines.append(
            f"  {row['cmprs_mb'] / 1024:6.2f} GB 压缩  "
            f"MEM {float(row['mem_mb']) / 1024:5.2f} GB  "
            f"{row.get('label') or row.get('comm')}  pid={row['pid']}"
        )

    lines += [
        "",
        "怎么读「重启就没了」",
        "  压缩器会在重启后清空，kernel_task 那十几 G 会掉下去。",
        "  联动内存里的显卡和页表，开机用一会儿还会长回来，那是正常开销。",
        "  要找没关的东西：看压缩器排名和 next dev 进程榜，不要看 macOS 这一行的总数。",
    ]
    return "\n".join(lines) + "\n"


def snapshot_json(snap: dict) -> dict:
    """给机器读的精简结构，不丢进程全文（那是隐私+噪音）。"""
    panel = snap["panel"]
    return {
        "ts": snap["ts"],
        "trusted": snap["reconcile"]["trusted"],
        "reconcile": snap["reconcile"],
        "panel": {
            "total_gb": round(panel["total_bytes"] / GIB, 2),
            "app_gb": round(panel["app_bytes"] / GIB, 2),
            "wired_gb": round(panel["wired_bytes"] / GIB, 2),
            "compressed_gb": round(panel["compressed_bytes"] / GIB, 2),
            "available_gb": round(panel["available_bytes"] / GIB, 2),
            "pressure_pct": panel["pressure_pct"],
            "memorystatus_free_pct": panel["memorystatus_free_pct"],
            "pressure_level": panel["pressure_level"],
            "swap_used_gb": round(panel["swap_used_mb"] / 1024, 2),
            "swap_total_gb": round(panel["swap_total_mb"] / 1024, 2),
        },
        "kernel": {
            "mem_gb": round(snap["kernel"]["mem_bytes"] / GIB, 2),
            "compressor_gb": round(snap["kernel"]["compressor_bytes"] / GIB, 2),
            "own_gb": round(snap["kernel"]["own_bytes"] / GIB, 2),
            "stored_gb": round(snap["kernel"]["stored_bytes"] / GIB, 2),
        },
        "apps": [
            {
                "label": a["label"],
                "kind": a["kind"],
                "gb": round(a["mem_mb"] / 1024, 2),
                "cmprs_gb": round(a["cmprs_mb"] / 1024, 2),
                "procs": a["procs"],
            }
            for a in snap["apps"][:24]
        ],
        "proc_count": snap["proc_count"],
    }


def ours_json(snap: dict) -> dict:
    payload = snapshot_json(snap)
    ours = snap["ours"]
    payload["ours"] = {
        "budget_gb": round(ours["budget_bytes"] / GIB, 2),
        "total_gb": round(ours["total_bytes"] / GIB, 2),
        "cmprs_gb": round(ours["cmprs_bytes"] / GIB, 2),
        "cursor_app_gb": round(ours["cursor_bytes"] / GIB, 2),
        "unknown_gb": round(ours["unknown_bytes"] / GIB, 2),
        "stacked_gb": round(ours["stacked_bytes"] / GIB, 2),
        "remaining_gb": round(ours["remaining_bytes"] / GIB, 2),
        "over_budget": ours["over_budget"],
        "buckets": [
            {
                "cat": b["cat"],
                "label": b["label"],
                "gb": round(b["mem_mb"] / 1024, 2),
                "cmprs_gb": round(b["cmprs_mb"] / 1024, 2),
                "rss_gb": round(b["rss_mb"] / 1024, 2),
                "procs": b["procs"],
            }
            for b in ours["buckets"]
        ],
        "unused": [
            {
                "verdict": row.get("verdict"),
                "pid": row.get("pid"),
                "port": row.get("port"),
                "cwd": row.get("cwd") or "",
                "gb": round(float(row.get("mem_mb") or 0) / 1024, 2),
                "idle_minutes": row.get("idle_minutes"),
                "owner": row.get("owner"),
            }
            for row in (snap.get("unused") or [])
        ],
    }
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Cortex 内存面板 / 拆解 / 记录仪")
    parser.add_argument("--json", action="store_true", help="机器可读")
    parser.add_argument("--ours", action="store_true", help="我们这边一共占了多少")
    parser.add_argument("--breakdown", action="store_true", help="拆开 macOS / 联动 / 压缩器")
    parser.add_argument("--watch", action="store_true", help="循环采样，旧记录仪模式")
    parser.add_argument("--out", help="记录仪输出 JSONL；带了就进入 --watch")
    parser.add_argument("--interval", type=float, default=30.0)
    parser.add_argument("--max-minutes", type=float, default=240.0)
    args = parser.parse_args()

    if args.out or args.watch:
        if not args.out:
            print("记录仪模式需要 --out", file=sys.stderr)
            return 2
        path = Path(args.out)
        path.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.time() + args.max_minutes * 60
        with path.open("a", encoding="utf-8") as handle:
            while time.time() < deadline:
                try:
                    row = snapshot_json(collect_snapshot())
                except Exception as exc:  # 采样失败不许把记录仪弄死
                    row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "error": repr(exc)}
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                handle.flush()
                time.sleep(args.interval)
        return 0

    try:
        if args.ours:
            data = collect_ours()
        elif args.breakdown:
            data = collect_breakdown()
        else:
            data = collect_snapshot()
    except Exception as exc:
        print(f"采样失败：{exc}")
        return 1

    if args.json:
        if args.ours:
            payload = ours_json(data)
        else:
            payload = snapshot_json(data)
            if args.breakdown:
                payload["wired_groups_gb"] = {
                    k: round(v / GIB, 2) for k, v in (data.get("wired_groups") or {}).items()
                }
                payload["gpu_in_use_gb"] = round(int(data.get("gpu_in_use_bytes") or 0) / GIB, 2)
                payload["services"] = data.get("services")
                payload["cmprs_rank"] = data.get("cmprs_rank")
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0 if data["reconcile"]["trusted"] else 3

    if args.ours:
        text = format_ours(data)
    elif args.breakdown:
        text = format_breakdown(data)
    else:
        text = format_snapshot(data)
    print(text, end="")
    return 0 if data["reconcile"]["trusted"] else 3


if __name__ == "__main__":
    raise SystemExit(main())
