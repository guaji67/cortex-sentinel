# 2026-08-24 面板卡顿架构级修复 worklog

任务：面板刷新与滚动打架（Falcon：「前端在刷新的时候我想上下滑，它就会卡」）。
前一轮只治了症状（1834068 / 3b1e241：查询中不露面、余额块不塌陷、结果攒批上屏），
这一轮从架构层解决。交接文档原件归档在同目录 `2026-08-24-panel-arch-refactor-handoff.txt`。

## 改前基线（真机 Instruments，attach 到在跑的 3b1e241 构建，pid 28621）

采样方法：`xcrun xctrace record --template SwiftUI --attach <pid> --time-limit 50s`，
录制期间用 `open -a` 真打开面板 + CGEvent 注入 32 秒连续滚轮事件（1693 条），
中途 screencapture 留证。SwiftUI 模板的 View Body instrument 在 attach 和 launch
两种模式下都是 0 行（Instruments 16.0 + macOS 26.5.1，本仓 app 拿不到 SwiftUI
signpost），body 耗时改用同一份 trace 里的 Time Profiler 栈归因，前后同口径。

- potential-hangs：主线程 hang 16 次 = 1 次 515ms Hang + 15 次 324-389ms Microhang，
  节奏与 5 秒状态刷新周期严格对齐（09.4s / 14.7s / 19.7s / 24.8s / 29.7s / 34.7s …）
- hitches：36 条共 3667ms；≥100ms 的 9 条，最大 500ms
- 主线程 Running 5037ms / 51.3s 窗口，归因：
  - NSView.hitTest 1409ms（28.0%，滚轮事件逐个在巨型视图树上命中测试）
  - SwiftUI 整图更新（NSHostingView.beginTransaction → AG::Graph）779ms（15.5%）
  - AutoLayout（NSISEngine，来自 NSHostingView minSize/updateConstraints 链）369ms（7.3%）
  - LocalHostIdentity.current 77ms + SCPreferences/ComputerName 71ms —— 铁证栈：
    body → headerSubtitle → LocalHostIdentity.current → -[NSHost localizedName] →
    SCDynamicStoreCopyComputerName → SCPreferences → 主线程读盘解析 XML plist
- hang 窗口内 226ms 主线程 Running 样本里 189ms 在
  ViewGraphRootValueUpdater.updateGraph → AG::Graph::UpdateStack::update，
  即整面板 body 重算风暴本体

结论：Falcon 的架构诊断成立。23 个 @Published × 单个 1798 行 body 68 处读 store =
任何一路刷新都全面板失效；另有两处他没点名的实锤：
1. `registry.registration(for:)` 是线性扫，502 条状态 × 661 条登记 ≈ 33 万次字符串
   比较——这就是「重新分组一轮 72.73ms」的真身（不是分组本身贵）
2. LineStatus.rolloutAgeSeconds 是解析时算的「距今秒数」，活跃线每轮必变 →
   相等短路必失败 → 每 5 秒必发全面板失效，正好压在滑动的手指底下

## 改造（7 笔提交）

- 36061a2 refactor: 分组时登记表按 slug 字典化（33 万次比较 → 502 次查表）
- d3791be refactor: SentinelStore 迁 @Observable；LocalHostIdentity 缓存进 store、
  每轮磁盘刷新在后台线程复核；ScrollPublishGate（滚动挂起发布，手停 220ms 合并
  上屏，四个面 latest-wins、跨面数据执行时现读）；状态栏 Combine 订阅改
  withObservationTracking 循环；NSHostingController.sizingOptions = [] 掐掉
  minSize/updateConstraints 重算链；测试计数从 objectWillChange 迁到
  withObservationTracking 同步重挂计数（ObservationCounting.swift）
- 6603eac refactor: 面板拆 10 个分区 View（SentinelMenuSections.swift）各读各的
  属性，父 body 生产路径零 store 读取；行拆成 6 种独立行视图
  （SentinelLineRowViews.swift）；RelayAttributionContext 切片让线区不随
  aio.readAt 每轮变化失效；smoke 截图钩子按构造参数显式挂载
- e1741a3 feat: rolloutAgeSeconds 显示档位归一化（<60s→0 / 分钟档 / >600s→601），
  lineGroups / boardWindow 按显示指纹门控发布（同档抖动一个像素都不变，不发布；
  raw lines 照常更新给通知器等内部消费者）；六种行视图挂 Equatable + .equatable()
- 8011c89 test: PanelSectionIsolationTests——冷开/热开逐分区失效计数回归 +
  滚动闸行为回归（滚动期间 0 发布 / 数据攒闸 / 手停自动放行 / 关面板立即放行）
- （worklog 本笔）docs: 交接文档归档 + 本 worklog

一个迁移中的实证发现：这台 macOS 26.5 的 Observation 运行时对**同值赋值不发通知**
（实测计数 0），旧 `emitStatusRefreshPublicationsForTests`（同值重发一遍）在新架构下
是空操作，已删；唯一消费者（设置窗对照测试）改用真实数据变化驱动。

## 失效次数：旧口径 → 新口径

旧口径 = objectWillChange 次数，且每一次都等于整面板 body 重算一次。
新口径 = 逐分区 withObservationTracking 计数（读集与各分区 body 实际读的属性一致，
willSet 同步重挂，与旧口径逐笔对齐；见 PanelSectionIsolationTests）。

| 场景 | 旧世界（Falcon 真机实测） | 新世界（回归测试，3 账号 fixture） |
|---|---|---|
| 冷开 | 整面板重算 22 次（aio=15 + 7 个面各 1） | 整面板重算 0 次；余额分区 4 次（基础快照+逐账号，设计保留）；线列表分区 2 次（分组+归因切片各一次，与账号数无关）；历史/后台任务/打包 0 次 |
| 热开 | 整面板重算 3 次 | 整面板重算 0 次；线列表分区 0 次；余额分区 2 次（aio 读取时间戳+官方额度）；legacy 总量 2 |
| 每 5 秒刷新（心跳同档抖动） | 整面板重算 1 次 | 所有分区 0 次（指纹门控拦下），跨档才发布且只到线区 |

按 Falcon 机器约 14 个账号折算：冷开线列表分区 22 → 2，热开 3 → 0；
余额分区冷开仍逐账号上屏（他要的冷启动尽快填数保留）。

## 改后复测（同口径：装机后 attach pid 1737，同滚动脚本 1685 条事件）

| 指标 | 改前 | 改后 |
|---|---|---|
| 主线程 hang（>250ms） | 16 次（最大 515ms） | **0 次** |
| hitch 总时长 | 36 条 / 3667ms | 19 条 / 433ms（-88%） |
| ≥100ms 的 hitch | 9 条（最大 500ms） | **0 条**（最大 66.7ms） |
| 主机名解析上主线程 | ~148ms | 0 |
| SwiftUI 整图更新 | 779ms | 432ms |
| 根 body 重算 | 每次发布一次 | 0（生产路径父 body 不读 store） |
| NSView.hitTest | 1409ms | 1235ms（逐滚轮事件的固有成本，帧预算内，未动） |

注：改后窗口主线程总忙 4136ms vs 改前 5037ms 不能直接比——改前有 16 段冻结期
掉帧不干活，改后每一帧都在真滚动。帧交付质量看 hang/hitch 两表。
改后 trace 里第二忙的线程是 LogCleaner.surveyUncertainVolume（刚装完的启动日志
清扫，既有设计，utility 优先级后台线程），与本次改动无关。

## 测试

swift test 全量（改造后）：
Executed 338 tests, with 0 failures (0 unexpected)
（基线 331 条 + 新增 7 条：指纹 3 + 分区隔离/滚动闸 4；0 failures 硬指标达成。
testRefreshWithExistingNumbersKeepsThemAndPublishesAtMostOnce 按令保留并迁移到
新计数口径，断言语义不变。）

## 证据

- 改前 trace：/tmp/sentinel-baseline-swiftui.trace
- 改后 trace：/tmp/sentinel-after-swiftui.trace
- 滚动中截图（全屏含真实数据，不进 git）：
  logs/2026-08-24-panel-arch-before-scroll.png / logs/2026-08-24-panel-arch-after-scroll.png
- 安装日志：/tmp/sentinel-install.log（== 已运行唯一正式实例 pid=1737 ==）

## pid 台账

- 28621 改前哨兵：本线未杀；install-app.sh 按精确可执行路径 TERM 替换（授权路径）
- 1737 改后哨兵：launchd 托管，保持运行
- 79306 xctrace --launch 起的临时第二实例（View Body 尝试）：xctrace 到时限自行收掉

## 遗留

- SwiftUI View Body instrument 对本 app 采不到 signpost 数据（attach/launch 都 0 行），
  body 次数用分区隔离回归测试口径长期回归；耗时用 Time Profiler 栈口径
- hitTest 的逐事件成本（~1.2s/32s 滚动）没动：树深 + .help()/手势区域多，帧预算内；
  若以后还要抠，方向是减少 .help 数量或收缩 contentShape
- 最终手感由 Falcon 亲手验收
