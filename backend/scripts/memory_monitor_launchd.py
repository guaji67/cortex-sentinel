#!/usr/bin/env python3
"""launchd 入口：起 memory_monitor.sh。

为什么要这么绕一层（2026-08-18 实测换来的，别改回直接跑 bash）：

仓住在 `~/Documents` 下面，那是 macOS TCC 保护目录。launchd 上下文里
**权限是按可执行文件给的**，实测结果：

| launchd 里执行谁 | 访问仓内文件 |
|---|---|
| `/bin/bash` / `/bin/ls` / `/usr/bin/head` | `Operation not permitted` |
| 仓内 `venv/bin/python3` | 通 |
| 上面那个 python **spawn 出来的** `/bin/bash` | 通（权限继承） |

所以 `com.falcon.cortex.memory-monitor.plist` 原来直接写
`ProgramArguments = [/bin/bash, .../memory_monitor.sh]`，挂上去 `launchctl list`
看得见、但每次都是 exit 126，日志里只有一行
`/bin/bash: .../memory_monitor.sh: Operation not permitted`
—— 也就是「挂上了」和「在跑」是两件事，而这一层差别在 `launchctl list` 上看不出来。
这就是那条「每 10 分钟自动收一次残留 dev server」写在文档里、实际一次都没发生过的原因：
不是谁忘了挂，是挂了也跑不起来。

改成先起仓内 venv 的 python（有权限），再由它 spawn bash 跑那个脚本，权限就继承过去了。

维护提示：`com.falcon.cortex.web-guard.plist` 也是 `/bin/bash` 直跑仓内脚本的形状，
如果哪天要挂它，同一堵墙会再撞一次，照这里的形状改。
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

INSTALL_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = INSTALL_ROOT / "scripts" / "memory_monitor.sh"


def main() -> int:
    if not SCRIPT.exists():
        print(f"memory_monitor.sh 不在: {SCRIPT}", file=sys.stderr)
        return 2
    # 永不因为监控自己出错而崩：launchd 会无脑重试，跟 memory_monitor.sh 的 fail-soft 口径一致
    try:
        r = subprocess.run(["/bin/bash", str(SCRIPT)], cwd=str(INSTALL_ROOT), timeout=300)
        return r.returncode
    except subprocess.TimeoutExpired:
        print("memory_monitor.sh 超过 300 秒未退出，本轮放弃", file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 - 监控入口不许把自己炸掉
        print(f"起 memory_monitor.sh 失败: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
