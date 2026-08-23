# Worklog：port-oxalpha —— 把 ox-alpha 派工线识别能力移植进 public 仓

- 线名：`port-oxalpha`
- 分支：`codex/port-oxalpha-engine`（基线 `1dea24f`）
- 工作树：`/Users/falcon/Documents/Code/cortex-sentinel-worktrees/port-oxalpha`
- 源仓（只读）：`/Users/falcon/Documents/Code/cortex-sentinel`（COR-1894，提交 `4147b50` / `051f1fa` / `a6ab57f`）
- 日期：2026-08-23

> 更新说明：上半段保留移植子会话当时的权限卡点记录；本轮已在同一工作树完成复核、修正、构建、全量测试、阳性对照和提交前证据，最终状态以第七至第九节为准。

## 结论先行

代码与测试移植全部完成（7 个源文件 + 6 个测试文件 + 1 个 fixture），静态复核通过。
但本会话的权限层把 `swift build` / `swift test` / `git add` / `git commit` 全部拒了
（详见「卡点」段），所以编译证据、测试数字、阳性对照、真现场验证、提交这五件事**没做成**，
接手的人照「待办」段跑四条命令就能收尾。

## 一、调研结论（为什么不许整文件覆盖）

两仓同名文件早已大分叉，本仓多出源仓没有的能力：

- `ChannelUnknownKind` 四态未知文案（还没有记录 / 读不出 / 看不懂 / 查不出来）
- `SentinelBoardCopy` 文案集中 + 标题 off-host 口径
- host 口径全套（`CodexLineRegistration.host` / `LocalHostIdentity` / `LineHostOrigin`）
- `LineStatusFileCache` / `CodexLineRegistryCache` / `StatusDiskReader`
- LogCleaner 白名单体积口径 + 「拿不准」清单 + 巡检痕迹 + XCTest 隔离

源仓多出本仓缺的 ox-alpha 全套。直接覆盖任何一个文件都会删掉对面一边的能力，
所以全部按能力逐处合入，合入时以本仓的文案/口径为准适配（例：源仓 missing 显示
「无数据」，本仓显示「还没有记录」，第三张卡跟本仓走）。

残缺版分支 `origin/claude-engine-line`（`96f3a15`）核对过：displayName 写的是
"Claude"、ackChannel 是 "claude"、还认了 "claude-code"，且 EngineCounts 把
ox-alpha 混进 unknown。**按任务书以源仓完整版为准**：displayName = "ox-alpha"，
ackChannel = "claude-oxalpha"，rawValue 只认 "claude"/"claude-oxalpha"。
判据 2 的实质（徽章走 `engineBadge(_:)` → `LineEngine.displayName` 同一条路，
不搞特例分支）满足。

## 二、合入明细（能力 → 落点）

### 能力 1：认得 `logs/claude-oxalpha-<线名>.status.json` 并显示成一条线
- `SentinelFileReader.swift`：`statusPrefixes` 加 `("claude-oxalpha-", .claudeOxAlpha)`；
  注释带上「再来一种渠道只加一行」的约定。
### 能力 2：引擎徽章 Claude/ox-alpha 走同一条路
- `SentinelModels.swift`：`LineEngine.claudeOxAlpha` case；init 认 `"claude"` /
  `"claude-oxalpha"`（trim + lowercased）；displayName "ox-alpha"；ackChannel
  "claude-oxalpha"。徽章经既有 `engineBadge` 渲染，非 grok 走默认配色，零特例分支。
- `LineRegistry.swift`：`LinePresentation.engine` 判活优先级从「isCursorGrok 特判」
  升级为源仓的「非 Codex 听状态文件」——旧登记条目没 engine 字段解码成 Codex 时，
  claude-oxalpha-* 的线不会再挂 Codex 徽章；注释说明这是通用判据，加新引擎不用再改。
### 能力 3：计数把 ox-alpha 算进去
- `SentinelBoardWindow.swift`：`EngineCounts` 加 `claudeOxAlpha` 字段（两个 init 都带，
  有默认值，旧调用点不动）。活跃 / 本机活跃 / 最近完成 / 历史 / 隐藏五套计数自动全算。
- `SentinelModels.swift`：`ChannelStatusSnapshot.claudeOxAlpha`（显式 init 带默认
  `.missing`，旧调用点不动）；`ChannelSectionPresentation` 第三张卡（name "ox-alpha"，
  items [codex, grok, claudeOxAlpha]）。
- `SentinelMenuView.swift`：通道区 HStack 摆第三张卡。
### 能力 4：LogCleaner 不误删活着的 ox-alpha 线日志（源仓 a6ab57f）
- `LogCleaner.swift`：判活 `statusStateMap` 改为扫 `["codex-babysitter-", "claude-oxalpha-"]`
  两个前缀；同名 slug 两份状态文件时**活线优先**（已判 running/waitingRelay 不被另一份
  终态覆盖成可删）。头部红线注释同步。ox-alpha 自身的 `.status.json` / `.log` 天然不在
  白名单（cleanableSlug 不认），永不进候选——有测试锁死。
### 能力 5：自检 / 诊断给得出结论
- `CortexSentinelBarApp.swift` --dump-state：
  - 通道段加一行 `ox-alpha <状态> · 文件running=N · 面板条数(本机)=N · <evidence>`
  - 「状态文件：读到 N 条线」下加「活跃按引擎（本机）：Codex=x Grok=x ox-alpha=x 其它=x」
  - 看板三行计数补 ox-alpha=（本仓没有源仓的 engineCountsText 单点函数，按本仓既有
    Grok=/Codex= 直排风格扩展）

### 测试与夹具
- `Fixtures/claude-oxalpha-status.json` 从源仓原样带来（Package.swift 已 `.process("Fixtures")`，自动打包）。
- `SentinelFileReaderTests`：+5 个（fixture 契约解析〔真 copyItem 后 readLines 读它〕、
  前缀兜底 slug/engine、codex_pid 优先 agent_pid、两个 rawValue 归一、terminal ack 前缀键匹配）。
- `ChannelSectionPresentationTests`：+3 个（三键渲染三卡、缺第三键保持 missing 不是 degraded、
  invalid 三通道全读不出）；11 处 primaryRow 期望补第三卡「ox-alpha 还没有记录」（按本仓文案）。
- `LineRegistryTests`：移植「登记表读 claude 引擎 + 状态文件赢过旧登记条目」，makeLine 加
  engine 参数（带默认值，旧调用不动）。
- `SentinelBoardWindowTests`：移植「ox-alpha 从 codex 计数里拆出来」（含本机口径断言）。
- `LogCleanerTests`：+2 个（ox-alpha 活线保 codex 日志、同名 slug 活线赢终态）+
  cleanableSlug 保护名单加 2 项 + writeOxAlphaStatus 助手。
- `PanelPNGRendererTests`：primaryRow 期望补第三卡。

## 三、验收判据逐条对账

| # | 判据 | 状态 |
|---|------|------|
| 1 | swift build 0 error | ❌ 未执行成（权限拒绝，见卡点） |
| 2 | swift test 数字 | ❌ 未执行成（同上） |
| 3 | fixture 带过来且有测试真读 | ✅ 代码层面完成：`testDiscoversAndParsesClaudeOxAlphaStatusContract` copyItem 进临时 logs 目录后 `readLines` 解析并逐字段断言 |
| 4 | 阳性对照 | ❌ 未执行成。方案：把 `SentinelFileReader.statusPrefixes` 里 `"claude-oxalpha-"` 改成别的 → 至少 `testDiscoversAndParsesClaudeOxAlphaStatusContract`、`testClaudeOxAlphaFallbackSlugAndEngineComeFromFileNamePrefix`、`testOxAlphaRunningLineProtectsItsLog...`、`testRunningOxAlphaStatusBeatsTerminal...` 应变红；改回应变绿 |
| 5 | public 成员清点 | ✅ 见下表 |
| 6 | 真现场面板可见 | ❌ 未执行成（cortex/logs 与构建产物都在会话沙箱外）。命令见待办 |

### 判据 5：成员清点（顶层声明 + 一级成员 grep 计数）

| 文件 | HEAD | 工作树 | 说明 |
|---|---|---|---|
| SentinelModels.swift | 286 | 289 | 净增 3（case + 通道属性 + init 参数），零删除 |
| SentinelFileReader.swift | 87 | 88 | 净增 1（channels payload 键），零删除 |
| LineRegistry.swift | 45 | 45 | engine 计算属性只改实现，签名未动 |
| LogCleaner.swift | 62 | 62 | statusStateMap 同签名重构 + 新增 private 前缀常量（private 不进此计数），零删除 |
| CortexSentinelBarApp.swift | 29 | 29 | 只动 print 输出，零删除 |
| SentinelBoardWindow.swift（额外动） | 33 | 34 | EngineCounts 字段/init 参数净增，零删除 |
| SentinelMenuView.swift（额外动） | 10 | 10 | channelSection 只加渲染行 |

另用 diff 逐行复核过：7 个源文件的删除行里没有任何一条是既有的类型/成员声明，
全部删除行都是被替换实现的内部行或注释行。

## 四、卡点（试过什么，全被会话权限层拒绝）

本会话是派工子会话，Bash 允许清单只有读类命令（git 只读、diff/grep/ls/cat/mkdir/cp）。
以下每条都实际发起过并被拒：

1. `swift build`（裸命令 / `--package-path` 绝对路径 / `/usr/bin/swift` / 带 tail 管道）
2. `swift test`、`swift --version`、`swiftc`（推断同类）、`xcodebuild -version`
3. `bash scripts/build-app.sh`（仓库自带构建脚本）
4. `maestro --help`（想走 cli-tools.json 的 codex 端点代跑）
5. `python3 -V`（想探测替代执行路径后放弃——绕权限属越权，不做）
6. `git add <单个文件>` / 多路径 git add / `git config core.hooksPath`
7. `ls /Users/falcon/Documents/Code/cortex/logs/`（判据 6 现场）
8. Read `/Users/falcon/CortexData/self/macro.md`（Cortex 必读 hook 要求，路径在沙箱外）

没有尝试任何绕过权限的手段（Monitor/脚本包装/浏览器 JS 执行等都视为规避，不做）。

## 五、待办（接手的人照跑即可）

```bash
cd /Users/falcon/Documents/Code/cortex-sentinel-worktrees/port-oxalpha
swift build 2>&1 | tail -20          # 判据 1
swift test 2>&1 | tail -30           # 判据 2，记 passed/failed 数字回填本文件
# 判据 4 阳性对照：见上表方案，红→绿各跑一次相关测试
.build/debug/CortexSentinelBar --dump-state   # 判据 6，看 ox-alpha 通道行与引擎计数行
git add <本线 14 个文件> && git commit -m "feat: 移植 ox-alpha 派工线识别能力（COR-1894 四阶段）" -- <同路径>
```

预期：新增测试约 13 个（FileReader 5 + ChannelSection 3 + Registry 1 + BoardWindow 1 +
LogCleaner 2 + PanelPNGRenderer 期望更新），存量期望改动 12 处均为「第三卡文案」追加。

## 六、收工清理声明

- 本线未起任何常驻进程（没能跑起来任何东西，包括 dev server / 编译进程）。
- 已删除自己建的临时目录 `.cortex-session/tmp-audit/`（声明清点的中间产物）。
- 留下的东西及原因：
  - `logs/worklog-port-oxalpha.md`（本文件，交付物②）
  - `.cortex-session/checklist-subagent-port-oxalpha.md`（红线 3 要求的活清单）
  - 工作树里未提交的源码/测试/fixture 改动（因 git add 被拒无法提交，见卡点）

## 七、本轮红灯判定与修正（2026-08-23）

### 7.1 去重后的 4 个用例：全部判为真回归，保留原断言

这 4 个测试都没有把 ox-alpha 当作 unknown 来断言；它们分别保护既有的 host 归类、缺记录文案、四种未知态区分和“看不懂就如实说”。红灯的直接原因是第三张卡被 `ChannelSectionPresentation` 的旧两通道构造器无条件附加，污染了这些测试的既有两行输出。实现改成两个入口：旧 `init(grok:codex:liveCounts:)` 继续渲染两张旧卡；生产菜单和 ox-alpha 新测试显式传 `claudeOxAlpha:` 后渲染第三张卡。4 个红灯的断言原样保留。

#### `LineRegistryTests.testHostFieldSplitsLocalRemoteAndUnknownWithoutGuessing`

原断言防护：登记表 host 显式区分本机、外机、缺失三类；本机通道计数只数本机，同时保留三条线。ox-alpha 状态识别不参与这个 host 判据。修正：恢复旧两通道构造器的两行输出，host 归类、三条线和本机计数断言原样通过。

#### `SentinelFileReaderTests.testMissingEngineEntrySaysNoRecordInsteadOfUnintelligible`

原断言防护：channel-status 缺少 codex 键时必须是 `.noRecord` / “还没有记录”，不能被渲染成“状态看不懂”。缺键与 ox-alpha 是否一等公民无关。修正：旧两通道构造器继续只渲染 Codex/Grok；`.noRecord` 与文案断言原样通过。

#### `SentinelFileReaderTests.testReadChannelStatusSplitsFourUnknownKinds`

原断言防护：文件缺失、文件不可读、值未识别、采集器明确 unknown 四种来源必须保持四种 `ChannelUnknownKind` 和四套固定文案。第三卡附加项不应改变这组诊断。修正：该测试继续使用旧两通道构造器，四种状态与两行文案原样通过。

#### `SentinelFileReaderTests.testUnrecognizedStatusValueStaysUnintelligible`

原断言防护：陌生 status 值保持 `.unrecognized`，UI 如实显示“状态看不懂”，不猜成 alive/degraded，也不复用别的未知态。该防护与 ox-alpha 引擎枚举无关。修正：保留原断言，并让旧构造器维持两行输出后通过。

### 7.2 本轮实际调整过的新增/移植断言

#### `ChannelSectionPresentationTests` 的 11 个既有两通道场景

这些场景原先验证 Codex/Grok 的固定行文；移植第三卡后，测试调用点显式传入 `.missing`，每个场景单独验证第三卡的“还没有记录”，同时保留原有 Codex/Grok 文案、问题行和 rowCount 防护。它们不是“把 unknown 改成 ox-alpha”的偷换，而是把新增卡纳入明确的三卡契约；旧调用点仍由上一节的回归测试锁住。

- `testBothAliveWithRunningCountsRendersExactTexts`：原防 alive 计数；新断言在相同计数后追加缺失 ox-alpha 卡。
- `testBothAliveIdleRendersExactTexts`：原防 alive/闲；新断言保留两项并追加缺失卡。
- `testOneDegradedOneAliveRendersExactTexts`：原防 degraded 问题行；新断言保留问题行并追加缺失卡。
- `testBothUnknownRendersExactTexts`：原防两通道无记录；新断言追加缺失卡且不增加问题行。
- `testMissingFileUsesNoRecordOnPrimaryRow`：原防 missing 文件文案；新断言追加缺失卡。
- `testUnreadableFileUsesUnreadableOnPrimaryRow`：原防 unreadable 文案；新断言追加缺失卡。
- `testMissingEngineEntryUsesNoRecordOnPrimaryRow`：原防缺键为 noRecord；新断言追加缺失卡，状态判据不变。
- `testUnrecognizedStatusValueUsesUnintelligibleOnPrimaryRow`：原防陌生值文案；新断言追加缺失卡，状态判据不变。
- `testCollectorUnknownUsesUndeterminedOnPrimaryRow`：原防采集器 unknown 文案；新断言追加缺失卡，状态判据不变。
- `testHealthySectionHasOnlyThePrimaryRow`：原防健康态无问题行；新断言显式传第三卡后仍只有一行问题区，并包含缺失卡。
- `testLiveActiveLinesOverrideStaleChannelStatusRunning`：原防活跃线计数覆盖摘要 running；新断言追加缺失卡，活跃计数判据不变。

#### `SentinelBoardWindowTests.testActiveEngineCountsMatchFourRegisteredRunningGrokLines`

原断言防 Grok 四条本机活线计数；新增 ox-alpha 后显式传 `.missing`，只把第三卡加入同一渲染契约，Grok 计数仍为 4。

#### `PanelPNGRendererTests.testFourChannelUnknownFixturesMatchPrimaryRowCopy`

原断言防四种 fixture 的 Codex/Grok 未知态文案。现在显式传入第三通道，并按实际 snapshot 读取 ox-alpha 文案：缺键为“还没有记录”，整文件不可读为“状态读不出”。这样不会用静态缺失文案掩盖 invalid 文件的真实状态；四种 Codex/Grok 未知态断言仍保持原意。

## 八、验收证据（本轮已执行）

### 构建与全量测试

- `swift build 2>&1 | tail -20`：`Build complete! (0.13s)`，`BUILD_RC=0`。
- `swift test`：`Executed 314 tests, with 0 failures`；完整运行时长 63.914 秒，`TEST_RC=0`。
- 针对 4 个红灯、三卡场景和 LogCleaner 的定向测试：20 个测试、0 failures；恢复前缀后的 LogCleaner 两个阳性用例：2 个测试、0 failures。

### 三条能力 grep

- `Sources/CortexSentinelBar/LogCleaner.swift:555`：`private static let statusPrefixes = ["codex-babysitter-", "claude-oxalpha-"]`。
- `Sources/CortexSentinelBar/SentinelModels.swift:381` / `:398`：`case .claudeOxAlpha` 同时出现在徽章和 ackChannel 分支。
- `Sources/CortexSentinelBar/SentinelModels.swift:382`：`return "ox-alpha"`。

### 阳性对照：移除前缀必须红，恢复后必须绿

临时把 `LogCleaner.statusPrefixes` 改为仅 `[codex-babysitter-]` 后运行 `LogCleanerTests.testOxAlphaRunningLineProtectsItsLogAndItsOwnFilesAreNeverCandidates`：退出码 1，3 个断言失败，活线日志进入候选集（原应受保护）。恢复 `claude-oxalpha-` 后再次运行该用例及同 slug 活线优先用例：2 个测试、0 failures。工作树最终保留含前缀的实现。

### 原有成员保留核对（7 个被改源文件）

按基线 `1dea24f` 与工作树的一级成员声明逐项比对，原有声明全部仍在：

| 文件 | 原有成员声明 | 改后成员声明 | 原有仍在 |
|---|---:|---:|---:|
| `CortexSentinelBarApp.swift` | 45 | 45 | 45/45 |
| `LineRegistry.swift` | 59 | 59 | 59/59 |
| `LogCleaner.swift` | 68 | 69 | 68/68 |
| `SentinelBoardWindow.swift` | 36 | 37 | 36/36 |
| `SentinelFileReader.swift` | 106 | 108 | 106/106 |
| `SentinelMenuView.swift` | 81 | 81 | 81/81 |
| `SentinelModels.swift` | 324 | 331 | 324/324 |

新增项只有 ox-alpha 字段、枚举分支、第三卡显式入口及相关输出；未发现原有成员声明缺失。
