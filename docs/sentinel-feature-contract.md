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

打包读取端的 `isActive` 与主仓 `scripts/packaging_progress.py:148` 的 `progress_run_is_active()` 共用四道判活闸：状态为 `running`、`pid` 仍存活、当前进程启动标识与 `process_started_at` 一致、`updated_at` 距当前不超过主仓 `RUNNING_STALE_AFTER_SECONDS` 的 30 分钟窗口。缺任一条件，Store 丢弃该快照，菜单栏和状态栏都不显示「打包中」。启动标识在 macOS 上等价执行 `ps -p <pid> -o lstart=`；`kill(pid, 0)` 返回权限拒绝时按进程仍存活处理。窗口常量锚定主仓 `scripts/packaging_progress.py:61`，Swift 测试有契约断言和同一组跨语言 fixture。

## 维护规矩

1. 改状态栏或面板任一分区，先过本文对应行，再补或改守卫。
2. `swift test` 必须绿。打包相关至少上面三条在。
3. 父 body 不要再读线列表 / 余额等高频面。打包从无到有只能走 `packagingActive` 挂载，不要把分区永远留在树里靠 EmptyView。
4. 状态栏不要再自己订 Optional 的 `packagingProgress`；只订 `statusBarRenderState`。
5. 改了必须行为，同一提交改本文。丢了就再丢一次显示。

## 余额口径（2026-09-11 定，反了就是回归）

数字一律剩余口径，像电量：GLM 的 `remainingPercentage` 已经是剩余，显示时禁止再 `100 - $0`（0.1.15 曾双重反转成已用口径）。横条一律已流逝方向，正向走：重置时 0 起步绿条，快到重置点变黄（>=0.6），压线变红（>=0.85）。函数入口 `timeElapsedFraction` / `periodElapsedFraction`。守卫：`CommandCodeUsageTests.testTimeAndPeriodFractions`。

GLM 钥匙自动识别多认 ZCode CLI 的两份配置（`~/.zcode/cli/config.json` 与 `config.<名>.json`，字段 `provider.bigmodel.options.apiKey`）。`--glm-usage-json` 是给程序读的接口，`percent_used` 是已用口径、直接取 `percentUsed`；面板显示照旧剩余口径，别按本段把接口改反。守卫：`GLMUsageTests.testUsageJSONKeepsUsedPercentageNotRemaining`。

## 状态点与排序（2026-09-11 定）

余额区 GLM / Command Code 行首的点 = 额度状态，综合判定取最严重一档：5 小时窗剩余 ≤20% 黄、≤1% 红；周窗剩余 ≤10% 黄、≤1% 红；余额类（现金/月余）<10 黄、<1 红；stale 至少黄；没数据灰。Cursor / AIO / 官方不参与这套。守卫：`CommandCodeUsageTests.testProviderDotSignalThresholds`。

按住状态点上下拖 = 同组内排序（GLM 一组、CC 一组，互不混排），顺序持久化到 `com.falcon.cortex.sentinelbar.providerOrder.*`。Cursor / AIO 行的点无手势。守卫：`CommandCodeUsageTests.testProviderOrderingPureLogic`。

组与组之间不许再放无含义的小圆点分隔符（已随 0.1.17 删除，别加回来）。改名：点行名编辑，回车或点任意空白处提交，Esc 取消。详情卡：标签/数值/重置时间三列，重置时间越近越醒目（≥60% 流逝黄、≥85% 红）。GLM 窗口数值不带「积分」字样——卡宽 296 里带着它重置时间必截（量宽实锤），CC 卡口径本就没带。标签列 76、卡宽 304：执行者短名「M1Max ZCode」75pt、58 列放不下（量宽实锤），列宽一起抬，值列最长组合仍有余量。「免费时段」标签已带词，值里 cortex 文案若含「免费时段 / 现在是」要去掉重复；套餐冷却中时「派工」行写「冷却到 HH:MM，暂不派工」，跟行上冷却文案一致。卡片必须盖在余额区所有行上面：行级 zIndex 只在分支内兄弟间排序，GLM/CC 两分支的卡显示状态经 `BalanceCardBranchKey` 上报、分支容器按此抬 zIndex。

## 悬浮详情卡交互（2026-09-11 定）

详情卡淡入淡出 0.18 秒；卡片必须 `allowsHitTesting(false)`——不然卡片弹出压住鼠标位置，onHover 立刻退出，忽隐忽现。悬浮热区 = 整行一长条（行高 46，contentShape(Rectangle())），不是只有文字。

拖拽排序手感：过程只动本地预览（弹簧动画换位 + 0.3 点距死区防手抖），松手才落库；中途写库必抽搐（0.1.18 实踩）。拖拽中和鼠标压在点上时详情卡不出现。

详情卡挂面板右侧（trailing + x -10、宽 296），左边状态点列任何时候不许被卡片视觉盖住——盖住了就没法瞄准拖拽。

## 余额行列网格（2026-09-11 定）

三列等宽 80、列距 8、横条宽 = 列宽 - 12（右缘留白），条与条间隔恒定；面板宽 400、块宽 256。别再回到不等宽列 + 定长条的组合——条距会忽大忽小（0.1.23 实踩，Falcon 点名马虎）。

GLM 状态点分场景，一处写全：有订阅（5h / 周窗任一存在）只看订阅窗口，现金余额不参与；被 cortex 派工侧认成套餐的行（钥匙指纹对上套餐清单）无论有没有订阅窗都不看现金——套餐派工走套餐额度不花现金，冷却中至少黄；没订阅只剩余额的（非套餐行）才按余额判定（CC 的月余是订阅量不走这条）。套餐数据过时后冷却判不了，只看订阅窗口。横条约列宽九成。守卫：`CommandCodeUsageTests.testGLMDotSignalScenes`、`CortexPlanStatusTests.testPlanRowDotIgnoresCashBalance`。

套餐行的第三列（原现金格）换在跑/冷却文案：冷却中写「冷却到 HH:MM」（放不下自动换「冷却 HH:MM」，不出图截断为准）、在跑写「在跑 n/上限」、读不到写「在跑 —」；这列不画横条（横条一律是时间流逝，这列不是时间）、不加 `.help`（会和详情卡双弹）。套餐数据由 cortex 仓 `scripts/glm_plan_status.py --json` 提供（按 origin/main 清单导出缓存后运行），失败时最近一次成功的整份留在内存当套餐身份（指纹/名/上限，不落盘，下次成功整份换新）：30 分钟内数照用，详情卡末尾加「派工状态：HH:MM 读到的，这次没读到（原因）」；超过 30 分钟数判过时——行名仍用套餐名，第三列固定「在跑 —」不显示冷却，状态点只看订阅窗口，详情卡只留在跑「— / 上限 n」、现金余额、「派工状态：没读到（原因）」三行，执行者/派工/免费时段不显示；开 App 以来一次都没成功过则行照旧，`--dump-state` 现场跑一轮打一行排查。指纹/套餐 id/错误 code 不进界面。守卫：`CortexPlanStatusTests.testThirdColumnCooldownRunningAndUnknown`、`testFreshFailureKeepsNumbersAndAddsNote`、`testStaleFailureShowsIdentityOnly`、`testNeverSucceededKeepsRowsUntouched`、`testGitSubcommandsAreReadOnlyWhitelist`。
