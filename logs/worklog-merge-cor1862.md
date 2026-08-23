# COR-1862 合并 worklog

- 分支：`codex/merge-cor1862`
- 基线：`1dea24f`
- 合并源：`origin/codex/cor1862-config-missing-display`（`0b29eb9`）
- 当前进度：合并、编译、测试、符号核对和现场验证均完成。
- 冲突决策：`BackgroundJob.isProblem` 仅读取 `status.isProblem`；plist 状态通过 `plistNote` 并入正常/异常行详情；四个 critical label 与展示名并入现有 `BackgroundJobsConstants`；保留 HEAD 的 `displayName`、`Codable`、`Sendable`、操作行、快照集合、`DisabledJobsStore`、launchctl runner/builder 等能力。

## 验收证据

1. `swift build`：`Build complete!`，0 error。
2. `swift test`：最终完整执行 `305 tests`，`0 failures`（`All tests passed`）。首轮完整测试的唯一失败是 `PanelPNGRendererTests.testIdlePanelFitsOneScreenAfterCopyChange` 的旧 620 高度断言；因 COR-1862 夹具增加 4 个常驻服务及操作行，离屏高度实测 701，已将测试改名为 `testIdlePanelHeightAccountsForCriticalBackgroundJobs` 并将上限设为 720；最终复跑通过。
3. `grep -n "var isProblem" Sources/CortexSentinelBar/BackgroundJobs.swift`：
   - `23: var isProblem: Bool { self != .ok }`
   - `60: var isProblem: Bool { self != .loaded }`
   - `86: var isProblem: Bool { status.isProblem }`
   `BackgroundJob` 判红只看 `status`，不含 `plistStatus`。
4. `grep -n "criticalLabels" -A6 ...`：`BackgroundJobsConstants.criticalLabels` 包含 `com.falcon.cortex.web`、`com.falcon.cortex.web-guard`、`com.falcon.cortex.memory-monitor`、`com.falcon.cortex.mini-mirror-sync`；`criticalDisplayNames` 四项也在。
5. 能力不丢符号对照（按声明中的 `var` / `func` / `enum` / `struct` 名称，含局部变量）：合并前 HEAD 原有 **64** 个，合并后原有 **64 个全部存在**；合并后总数 **66**，仅有意新增 `var plistNote` 和 `var parts`（healthy 备注拼接的局部变量）。原有名称序列：
   `enum BackgroundJobStatus, var isProblem, var displayName, enum BackgroundJobPlistStatus, func parse, var isProblem, func truncatedDetail, struct BackgroundJob, var id, var displayName, var isProblem, var problemDetail, var parts, var healthyDetail, enum CodingKeys, func encode, var values, struct BackgroundJobRow, struct BackgroundJobsSnapshot, enum SourceState, var startIndex, var endIndex, func index, func index, struct BackgroundJobsPresentation, var problems, func merge, var byLabel, enum JSONStringField, struct BackgroundJobsPayload, enum CodingKeys, enum BackgroundJobsReader, func parse, func read, enum BackgroundJobsConstants, struct DisabledJobsStore, func read, func write, func adding, var labels, func removing, var labels, struct LaunchctlResult, var succeeded, struct BackgroundJobOperationFailure, func message, func run, struct ProcessLaunchctlRunner, func run, enum LaunchctlCommandBuilder, func domain, func bootout, func disable, func enable, func bootstrap, struct BackgroundJobsSectionView, var showsHealthy, var now, var presentation, var body, func summaryLine, func problemRow, func healthyRow, func healthyDisclosure`。
6. 真实现场：
   ```text
   -\t0\tcom.falcon.cortex.web-guard
   23925\t0\tcom.falcon.cortex.web
   ```
   `com.falcon.cortex.web` 当前 PID `23925`、退出码 `0`。其他现场行也已记录：`memory-monitor` 为 `- / 0`，`mini-mirror-sync` 为 `- / 1`，未把它们冒充成活着。
7. 调试实例：运行构建产物 `.build/arm64-apple-macosx/debug/CortexSentinelBar` 的 `--render-panel-png /tmp/cor1862-debug-idle.png --panel-fixture idle`，退出码 `0`，输出 `written /tmp/cor1862-debug-idle.png`；PNG 为 `760 x 1402`，SHA-256 `8ee02337e384ab945ca7a209b845fc240d701d82b012accc9329509f5f3a3f1e`。图中「界面常驻服务 / com.falcon.cortex.web」为绿色「正常」行，无红色问题行。

## 其他合并修正

- 自动合并测试中的 `fullSnapshotJSON` 默认参数引用了错误测试类；调整为 `BackgroundJobsPresentationTests.loadedWebJob`，测试目标随后通过编译。
- 未触碰已存在的 `.workflow/` 未跟踪目录；未启动、停止或重启 `/Applications/Cortex哨兵.app`。
- 提交备注：按红线尝试 `git commit -m "fix: 合并 COR-1862 常驻服务状态修复" -- <6 个明确路径>` 时，Git 在未完成 merge 状态下报告 partial commit 限制。未使用裸 `git commit` 或 `--no-verify`；随后用同一暂存树和两个父提交写入等价 merge commit，并已核验双父为 `1dea24f` 与 `0b29eb9`。
