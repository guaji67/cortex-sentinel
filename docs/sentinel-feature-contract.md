# 哨兵功能契约

短清单。改 UI 先对照本文，再改守卫测试。行为变了就改这一页。

## 状态栏

数据源：`SentinelStore.statusBarRenderState`（Input 探针 + AIO 余额 + 打包）。控制器只观察这一份。

| 状态 | 必须行为 | 守卫 |
|---|---|---|
| 空闲 | 左侧 Input 三点 + 两个余额数字（不足补 `--`） | `PackagingProgressTests.testStatusBarGetsAnExplicitPackagingSegmentOnlyWhileRunning`（无打包时更窄） |
| 告警 | 余额低或探针异常用警告色；不靠改文案 | 现有 Input / 余额渲染测试 |
| 打包中 | `packagingProgress.isActive` 时最前加「打包」二字 | `PackagingDisplayRegressionTests.testNilToRunningProducesPanelSnapshotAndStatusBarPackagingText` |

面板关着也要刷。关面板默认 120 秒心跳（设置可改），定时器必须进 `RunLoop.common`。打开面板每次都刷磁盘状态（含打包），不跟余额新鲜度闸绑死。

## 面板（上到下）

父 `SentinelMenuView` 只读两个低频开关：`packagingActive`（要不要挂打包分区）、`panelPresentationGeneration`（每次打开强制按当前 store 重挂）。其它分区各读各的属性。

| 分区 | 数据 | 必须行为 | 守卫 |
|---|---|---|---|
| 标题 | `paths` / `lineGroups` / `boardWindow` / `localHost` | 本机活跃、最近、外机计数 | `PanelSectionIsolationTests` header |
| 打包进度块 | `packagingProgress`，仅 `running` | 无则整块不占位；从无到有必须出现 | `PackagingDisplayRegressionTests` 全组 |
| 通道 | `channelStatus` + 本机引擎计数 | 三卡 Codex / Grok / ox-alpha | `ChannelSectionPresentationTests` |
| Input 服务 | `inputStatus` | 全好时收成一行，有问题展开 | `InputStatusTests` + isolation service |
| 余额 | `aio` + `officialUsage` | 冷开尽快填数，刷新不塌陷 | isolation balances；`PanelBalanceRefreshTests` |
| 已登记派工 | `lineGroups.activeRegistered` | 空态「当前没有活跃派工」；行上有强制开始 | isolation dispatch；`SentinelLineControlsTests` |
| 最近完成 | `boardWindow.recentShown` | 在派工区内，可折叠 | isolation dispatch |
| 未登记活跃 | `lineGroups.activeUnregistered` | 自动识别区；有一键恢复 | isolation automatic |
| 历史 | `boardWindow` 历史窗 | 默认收起 | isolation history |
| 后台任务 | `backgroundJobs` / `backgroundJobRows` | 默认收起，不占派工位 | isolation backgroundJobs；`BackgroundJobsTests` |
| 底栏 | `aio` 路由摘要 | 打开日志 / 刷新 / 设置 / 退出 | `SentinelSettingsTests` |

登记派工：`logs/codex-line-registry.json`（监视目录，通常是 Cortex 仓 `logs/`）。状态文件同目录 `*.status.json`。打包进度是 `$TMPDIR/cortex-pack-progress`（可用 `CORTEX_PACK_PROGRESS_DIR` 覆盖），由主仓 `scripts/packaging_progress.py` 写，哨兵只读。

## 打包面专用守卫

1. `testNilToRunningProducesPanelSnapshotAndStatusBarPackagingText` — nil→running 时面板模型有打包块，状态栏图含打包字。
2. `testPackagingUpdateInvalidatesOnlyPackagingSectionAndStatusBarInputs` — 只失效打包分区和状态栏。
3. `testPackagingRefreshesWhilePanelStaysClosed` — 面板关闭仍刷新。

附：`testOpeningPanelStillPicksUpPackagingWhenBalanceRefreshIsSkipped`、`testObservationLoopFiresForPackagingNilToRunning`、`testHostedMenuMountsPackagingSectionOnNilToRunning`。截图 fixture：`--panel-fixture packaging`。

## 维护规矩

1. 改状态栏或面板任一分区，先过本文对应行，再补或改守卫。
2. `swift test` 必须绿。打包相关至少上面三条在。
3. 父 body 不要再读线列表 / 余额等高频面。打包从无到有只能走 `packagingActive` 挂载，不要把分区永远留在树里靠 EmptyView。
4. 状态栏不要再自己订 Optional 的 `packagingProgress`；只订 `statusBarRenderState`。
5. 改了必须行为，同一提交改本文。丢了就再丢一次显示。
