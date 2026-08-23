# Worklog — port-packprogress：打包进度移植与重复发布修复

- 分支：`codex/port-packaging-progress`
- 基线：`1dea24f`
- 工作树：`/Users/falcon/Documents/Code/cortex-sentinel-worktrees/port-packprogress`
- 只读源仓：`/Users/falcon/Documents/Code/cortex-sentinel`
- 目标：保留打包进度菜单栏/面板能力，同时遵守哨兵按数据源去重的发布契约。

## 根因与修复

上一版把 `packagingProgress` 接入 `SentinelStore` 的 `@Published` 与菜单栏控制器订阅链，但 `refreshStatuses()` 直接把 Reader 返回的快照赋给属性。机器上的 `$TMPDIR/cortex-pack-progress` 有历史 `failed` 快照；它虽不应显示（`isActive == false`），第一次刷新仍会把 `nil` 变成该残留快照，触发一次额外 `objectWillChange`。因此 6 条既有红测都精确多 1；重复刷新本身没有数据变化。

修复落点是 `Sources/CortexSentinelBar/SentinelStore.swift`：

```swift
let nextPackagingProgress = snapshot.packagingProgress?.isActive == true
    ? snapshot.packagingProgress
    : nil
if packagingProgress != nextPackagingProgress {
    packagingProgress = nextPackagingProgress
}
```

- Reader 仍完整解码 `completed/failed`，保留原有 `PackagingProgressTests` 的 Reader 契约；Store 只发布活跃的 `running` 快照。
- 活跃快照使用现有 `Equatable` 比较，环节、ETA、更新时间及其它快照字段不变时不赋值、不发布；环节/ETA/更新时间变化时仍会发布并重绘。
- `emitStatusRefreshPublicationsForTests()` 的强制发布语义保留，仅供既有设置窗重绘对照测试使用，不是运行时刷新路径。
- `SentinelPaths.defaultPackagingProgressRoot` 优先读取进程的 `TMPDIR` 环境变量，再回退到 `NSTemporaryDirectory()`；这样测试可使用隔离临时根目录，不会读到别的本地运行快照，生产默认路径仍是 `$TMPDIR/cortex-pack-progress`。

## 编译与测试证据

```text
$ swift build 2>&1 | tail -20
Build complete! (1.97s)

$ TMPDIR=/tmp/port-packprogress-test-clean-20260823/ swift test 2>&1 | tail -30
Test Suite 'CortexSentinelBarPackageTests.xctest' passed
    Executed 305 tests, with 0 failures (0 unexpected)
Test Suite 'All tests' passed
    Executed 305 tests, with 0 failures (0 unexpected) in 64.387 (64.407) seconds
```

说明：未隔离的本机重跑曾读到另一条线正在写入的全局 `running` 快照，产生 7 条环境伪红（另含面板高度受打包段影响的 1 条）；没有改测试断言。随后用上面的 `TMPDIR` 隔离命令重跑，RC=0 且 305/0。

重点套件：

- `PackagingProgressTests`：3 tests，0 failures。
- `StatusPublishDedupTests`：10 tests，0 failures。
- `PanelBalanceRefreshTests`：6 tests，0 failures。

额外阳性去重对照（临时测试文件已删除，未进入提交）：先刷一次建立相同的 active `running` 快照，再不改文件连续刷新 5 次，实测输出：

```text
PACKAGING_DEDUP repeated_refreshes=5 publications=0
```

## UI 阳性对照

在 `$TMPDIR/cortex-pack-progress/demo-run-port-packprogress/progress.json` 写入：

- `status=running`
- `current_step_id=build`
- `current_detail=Electron 打包`
- `steps[build].title=构建 App 与 zip`
- `eta_label=大约还要 12 分钟`

通过调试构建的 `--dump-state` 读到：

```text
打包进度：running · 构建 App 与 zip · 大约还要 12 分钟
```

真实离屏渲染也已验证：

- 菜单栏：`$TMPDIR/cortex-pack-progress/demo-run-port-packprogress/statusbar.png`，PNG 1700×360；图中橙色 `打包` 段位于余额段之前。
- 面板：`$TMPDIR/cortex-pack-progress/demo-run-port-packprogress/panel.png`，PNG 760×1270；图中实际出现 `Cortex 打包`、`构建 App 与 zip`、`Electron 打包`、`大约还要 12 分钟` 和更新时间。

进度 JSON 已从该目录移除，避免污染后续测试；两张 PNG 证据保留在上述绝对路径。

## 能力保留核对

使用基线 `git show HEAD:<path>` 与工作区声明清单逐文件比对，原有声明均保留：

| 文件 | 原有成员 | 改后成员 | 结果 |
|---|---:|---:|---|
| `Sources/CortexSentinelBar/CortexSentinelBarApp.swift` | 112 | 113 | 原有 112 个，改后 112 个都在（新增局部绑定 1） |
| `Sources/CortexSentinelBar/SentinelFileReader.swift` | 160 | 165 | 原有 160 个，改后 160 个都在（新增 5） |
| `Sources/CortexSentinelBar/SentinelMenuView.swift` | 127 | 128 | 原有 127 个，改后 127 个都在（新增 1） |
| `Sources/CortexSentinelBar/SentinelStatusBarController.swift` | 23 | 23 | 原有 23 个，改后 23 个都在 |
| `Sources/CortexSentinelBar/SentinelStore.swift` | 146 | 150 | 原有 146 个，改后 146 个都在（新增 4） |
| `Sources/CortexSentinelBar/StatusBarRenderer.swift` | 32 | 34 | 原有 32 个，改后 32 个都在（新增 2） |

功能文件仍在且被真实引用：`Sources/CortexSentinelBar/PackagingProgress.swift` 存在；`grep -rn "PackagingProgress" Sources/` 命中 24 处，包含 Store、Reader、Renderer、Controller、菜单栏与 CLI 的实际调用，不止定义处。

## 交付与边界

- 提交只包含本线的 6 个既有源文件、`PackagingProgress.swift`、`PackagingProgressTests.swift` 与本 worklog；`.cortex-session/`、`.workflow/` 不提交。
- 未触碰源仓 `/Users/falcon/Documents/Code/cortex-sentinel`，未启动或停止 `/Applications/Cortex哨兵.app`，未 push 或创建 remote。
- 提交命令使用明确路径：

```bash
git add Sources/CortexSentinelBar/CortexSentinelBarApp.swift \
  Sources/CortexSentinelBar/SentinelFileReader.swift \
  Sources/CortexSentinelBar/SentinelMenuView.swift \
  Sources/CortexSentinelBar/SentinelStatusBarController.swift \
  Sources/CortexSentinelBar/SentinelStore.swift \
  Sources/CortexSentinelBar/StatusBarRenderer.swift \
  Sources/CortexSentinelBar/PackagingProgress.swift \
  Tests/CortexSentinelBarTests/PackagingProgressTests.swift \
  logs/worklog-port-packprogress.md

git commit -m "feat: 移植打包进度显示并修好重复发布" -- \
  Sources/CortexSentinelBar/CortexSentinelBarApp.swift \
  Sources/CortexSentinelBar/SentinelFileReader.swift \
  Sources/CortexSentinelBar/SentinelMenuView.swift \
  Sources/CortexSentinelBar/SentinelStatusBarController.swift \
  Sources/CortexSentinelBar/SentinelStore.swift \
  Sources/CortexSentinelBar/StatusBarRenderer.swift \
  Sources/CortexSentinelBar/PackagingProgress.swift \
  Tests/CortexSentinelBarTests/PackagingProgressTests.swift \
  logs/worklog-port-packprogress.md
```
