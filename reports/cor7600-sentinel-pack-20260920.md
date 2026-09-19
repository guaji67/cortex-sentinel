# COR-7600 回执：菜单栏哨兵读稳定落点并显示打包三态

- 分支：`codex/cor7600-pack-stable-mirror`（哨兵仓，origin `guaji67/cortex-sentinel`）
- 完成时刻：`TZ=Asia/Shanghai date` = 2026-09-20 01:01 CST
- 本线只改哨兵仓，未碰 Cortex 主仓（主仓仅在只读方式下查看了 COR-7589 提交 `5bf8493c7ab9` 以确认写方 schema），未碰 Falcon 的机器（cortex-pro-tunnel），未起任何真打包炉。

## 第零步：量出来的值与两条来源

本机量取（工单原命令）：

```text
SENTINEL=/Users/falcon/Documents/Code/cortex-sentinel
DATA_ROOT=[]   # CORTEX_DATA_ROOT 未设置 → 按本仓 SentinelFileReader 的解析顺序走
git remote -v | head -1 → origin git@github.com:guaji67/cortex-sentinel.git   # 哨兵仓 ✓
ls Sources/CortexSentinelBar/PackagingProgress.swift → 存在 ✓
```

**来源一：本仓怎么解析数据根。** 照 `Sources/CortexSentinelBar/SentinelFileReader.swift:118-145` 的 `SentinelPaths.backgroundJobsHealthURL(logsDirectory:environment:fileManager:)`：`:130` 是 `CORTEX_DATA_ROOT` 分支，`:200-203` 是「CORTEX_DATA_ROOT 是测试/沙盒显式数据根时，不能被本机默认日志目录自愈劫持」的注释。解析顺序 = 显式专用 env → 监视目录 → `CORTEX_DATA_ROOT` → XCTest 护栏 → home 默认（`~/CortexData`）。本线没有新写解析、没有在 Swift 里写死任何本机绝对路径，新增的 `SentinelPaths.packProgressHealthURL(environment:homeDirectory:)`（`SentinelFileReader.swift:157-186`）照同一套顺序：`CORTEX_PACK_PROGRESS_MIRROR_DIR`（写方 `packaging_progress.py` 的显式覆盖，压过一切）→ `CORTEX_DATA_ROOT` → XCTest 护栏 → `~/CortexData/health/pack-progress.json`；home 取不到返回 nil。与被照对象唯一的差别是 XCTest 护栏补了 `NSClassFromString("XCTestCase")` 检测——这台机的 swift test 进程不带 `XCTestConfigurationFilePath`，原两键检测实测定不住（红测拦住了这一点），补检测的意图与原护栏注释一致：XCTest 默认不摸本机 `~/CortexData`。

**来源二：本仓怎么读 JSON 状态文件并画成面板一节。** 照 `Sources/CortexSentinelBar/BackgroundJobs.swift:359-381` 的 `BackgroundJobsReader`（文件不在 → missing，`(try? Data) + JSONDecoder` 解析失败 → invalid）加 `BackgroundJobs.swift:285-333` 的 `BackgroundJobsPresentation`（无数据 / 读不出 / 可用三态在展示层分开、不同色调）。选它而不是 `AIODataReader.swift` 一族，因为后台任务健康快照与打包登记是同一形状：数据根 `health/` 下的一份状态 JSON、读侧三态、面板独立分区。活线判定没有新写：沿用 `Sources/CortexSentinelBar/PackagingProgress.swift:143-166` 的 `isActive` 四道闸（status=running + PID 探活 + process_started_at 一致 + updated_at 在 30 分钟窗口），与主仓 `progress_run_is_active()` 同一套。

**工单「二选一」的选择：Swift 侧实现同一套。** 读主仓 COR-7589 提交确认：稳定落点文件 `_write_mirror()` 写的就是 v1 载荷 + `progress_file` 指针，**文件里没有 `state` 字段**（三态只存在于遥测载荷 `pack` 段），「直接信任文件里的 state 字段」这条路不存在。Swift 侧投影 `PackagingProgressReader.read(stableURL:legacyRoot:)`（`PackagingProgress.swift`）判活只调 `isActive` 这一套，reason 文案与主仓 `pack_telemetry_section()` 逐字一致（`PackagingProgressReader.Reasons`）。

## 第一件：数据源换稳定落点（已落）

| | 坐标 | 内容 |
|---|---|---|
| 改动前 | `SentinelFileReader.swift:46-58` `defaultPackagingProgressRoot`；`PackagingProgress.swift:5` 注释 | 唯一来源 `$TMPDIR/cortex-pack-progress`（`CORTEX_PACK_PROGRESS_DIR` 可覆盖） |
| 改动后 | `SentinelFileReader.swift:157-186` `packProgressHealthURL`；`SentinelFileReader.swift` `discover()` 接线 + `SentinelPaths.packProgressHealthURL` 字段；`PackagingProgress.swift` `read(stableURL:legacyRoot:)` | 先读 `<数据根>/health/pack-progress.json`，读不到再退回旧 `$TMPDIR/cortex-pack-progress` |

**旧 `$TMPDIR` 路径保留为兜底，顺序是「先稳定后旧路径」。** 理由：主仓 COR-7589 落地前的炉只写旧落点，Falcon 两台机器上若有升级前残留的活线记录，退回旧路径能接住；`PackagingProgressTests.testMissingStableMirrorFallsBackToLegacyRunning` 钉住顺序，`testUnreadableStableMirrorProjectsToErrorAndNeverFallsBack` 钉住另一条边界——稳定落点**在但读不了**时不退回兜底（error 不许被兜底洗成 idle，与遥测读侧一致），数据根解析不出来时旧落点若还有活线也照样显示 running（不让解析失败把在跑的炉藏成 error，`testUnresolvableStableRootReportsErrorUnlessLegacyIsRunning`）。

快照解码新增 `version`、`progress_file` 两个可选字段（v1 schema 本来就带 version，镜像文件多 progress_file 指针），现有解析没动。

## 第二件：三态分开显示（已落）

- `running`：警告色调块，「Cortex 打包 / 当前步标题 / 详情 / 版本 · 第 N/M 步 · HH:mm 起算 / 更新于 HH:mm」，右上角预计还要多久（`SentinelMenuSections.swift` `runningBlock`）。版本（`furnaceText`）与步次（`stepProgressText`）是新增快照计算属性。
- `idle`：中性色调块，显示读侧 reason（「当前没有在跑的炉」/「当前没有在跑的炉（稳定落点还没有登记文件）」），有上一炉残留时附「上一炉 HH:mm」（`idleBlock`）。
- `error`：警告色调块，单独显示 reason（「登记文件读不了或不是 JSON」/「解析不了稳定落点（数据根与显式覆盖都不可用）」），与 idle 不同色调、不同 accessibilityIdentifier（`packaging-error` vs `packaging-idle`），界面上不可能合成一句。
- 挂载：父 body 改读 `packagingReading` 在不在（`SentinelMenuView.swift:24-41`），首轮刷新落定后分区常驻——这正是病根的解法：Falcon 任何时候打开面板都能分辨「没在打包」和「没拿到数据」。
- 发布去重：`SentinelStore` 新增 `packagingReading` 三态面（Equatable 相同不发）；`packagingProgress`（只收活线快照）与 `packagingActive` 语义原样保留，状态栏「打包」段仍然只在 running 时出现。
- `--dump-state` 打三态原话 + 两个落点路径（`CortexSentinelBarApp.swift:241-269`）。

## 第三件：跨机 pack 段（没落，差什么写在这里）

跨机链路是主仓 `scripts/sentry_telemetry.py` 把 `pack` 段写进 Multica 票 metadata（键 `machine.<token>`，票默认 COR-6761），读侧要 `multica issue metadata get <票> --key machine.<token>`。本仓拿不到的东西：

1. **Swift 面板侧没有任何 multica 通道**：全仓 `multica` 只出现在 `backend/cortex_sentinel/bridges/multica.py`（Python 桥，把 Multica run 终态翻译成 status.json，不读 metadata）。菜单栏 app 只读本地文件，唯一的进程外调用是判活的 `ps`。
2. **凭据假设没着落**：metadata 读写要求面板所在机器装好并登录 multica CLI、还要拿到票 token（`CORTEX_SENTRY_TELEMETRY_TICKET`）。这两样在哨兵仓既没有配置入口也没有既定轮询节奏；往菜单栏 app 里硬塞一个带凭据的外部 CLI 依赖是产品决策，本线不硬凑。

**建议接法**（另开票）：由常驻侧代拉——backend（devserver 或新增 launchd 任务）定期 `multica issue metadata list <票>`，把各机 `pack` 段落成 `<数据根>/health/pack-telemetry-<token>.json`（带采集时间戳），面板按本线同款读文件套路加一个「外机炉」小节。面板侧零新增凭据面，跨机新鲜度由落盘时间戳表达。

## 验收

**测试**（照 `PackagingProgressTests` / `PackagingDisplayRegressionTests` 既有形状）：

- 新增 11 条：读层 7 条（running 压过残留并带炉身份 / 稳定缺文件退旧落点 running / completed→idle 带 last_run / 两处全缺→idle 带文件 reason / 登记读不了→error 且不退兜底 / 数据根解不出来→error（旧落点活线例外）/ 数据根解析顺序 4 断言），显示层 4 条（idle reason+上一炉 / error 与 idle 分开 / 稳定落点活线翻 running 且状态栏点亮 / 无文件 idle 的文件 reason）。
- 契约同步：`PanelSectionIsolationTests` 打包分区读集换成 `packagingReading`（冷开恰好 1 次 nil→idle 落定，热开 0），`PanelPNGRendererTests` fixture 名单补三个新 fixture，`PanelSectionIsolationTests.makeStore` 把打包旧落点钉进隔离目录。
- `swift test`（隔离 `TMPDIR` 跑，`out=$(swift test 2>&1); rc=$?` 取 rc，不在管道尾取）：**rc=0，369 tests，0 failures**（基线 305 + 各线新增）。

**界面证据**（假 `pack-progress.json`，`--render-panel-png` 离屏渲染，未起真炉；PNG 收进本仓 `reports/cor7600-assets/`，理由：人事后查要有实图，删了临时目录后仓里是唯一副本）：

| 态 | 文件 | 画面（亲眼验过） |
|---|---|---|
| running | `reports/cor7600-assets/panel-pack-stable-running.png`（760×1060） | 「Cortex 打包 · 大约还要 12 分钟 / 打 DMG / Electron 打包 / **1.2.3 · 第 3/3 步 · 09:34:34 起算** / 更新于 09:59:34」 |
| idle | `reports/cor7600-assets/panel-pack-stable-idle.png`（760×983） | 「Cortex 打包 / 当前没有在跑的炉 / 上一炉 07:59:34」（中性色调） |
| error | `reports/cor7600-assets/panel-pack-stable-error.png`（760×952） | 「Cortex 打包 / 登记文件读不了或不是 JSON」（警告色调，与 idle 截然可辨） |

`--dump-state` 三态文字证据（假数据根，同一次收工已删）：

```text
打包进度：running · 3.1.4 · 第 2/2 步 · 打 DMG · 大约还要 6 分钟
打包进度：idle · 当前没有在跑的炉 · 上一炉 09:55:00          （假 pid/lstart 判非活线 → idle，顺带证明四道闸经投影生效）
打包进度：error · 登记文件读不了或不是 JSON
打包进度：idle · 当前没有在跑的炉（稳定落点还没有登记文件）
```

**契约文档**：`docs/sentinel-feature-contract.md` 同提交更新（面板分区表、数据源、挂载规矩、截图 fixture 名单、三态投影语义）。

## 红线自查

- 未起真打包炉（全部夹具是手写 JSON / `--render-panel-png` 离屏渲染）；未碰主仓工作区；未碰 cortex-pro-tunnel。
- 走分支 + PR，不直推 main；无强推、无裸 `git commit`（一律 `git commit -m … -- <明确路径>`）、无 stash、无 --no-verify、无新建 remote。
- 代码与注释无本机绝对路径（夹具里的 `/tmp/fixture/...` 是测试假数据非本机路径，`progress_file` 夹具运行期拼）；无参考产品品牌名。

## 收工清理

- 本线未起任何常驻进程：三条 `--render-panel-png` 与四条 `--dump-state` 都是短命 CLI，跑完即退。收工 `pgrep -fl CortexSentinelBar` 只命中一行 `1791 /Applications/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar`——那是 Falcon 的生产哨兵（launchd 常驻，本线开工前就在跑），不是本线起的，照红线不动它。
- 删掉的临时物（命令与结果原样贴）：`rm -rf /tmp/cor7600-render /tmp/cor7600-dumpstate /tmp/cor7600-test-*` 后 `ls -d /tmp/cor7600-*` 无匹配（zsh「no matches found」）——三张 PNG 的临时副本（已收进仓）、假数据根、swift test 的隔离 TMPDIR 全部删净；另删 `.build/`（构建产物，本仓 `.gitignore` 已忽略，删掉留净树）。
- 本线直接在 `$SENTINEL` 分支上做，未建 worktree。`git worktree list` 里列出的 `cortex-sentinel-worktrees/sentinellive`、`cortex-worktrees/sentinel-*` 全是其它线的既有工作树（多数带 lock），本线一个没建、一个不删。
- 留给人事后查的：`reports/cor7600-assets/` 三张三态渲染 PNG（理由如上），此外没留下任何其它目录或文件；数据根 `repo-evidence-archive/` 未动、本线也没往里写过东西。
- `git status --porcelain` 干净证据：实现与回执分两笔提交后原样贴在本节末尾（追加提交只补这三样证据，内容零改动）。

收工三样证据（2026-09-20 01:05 CST 原样输出）：

```text
$ git status --porcelain
（无输出，工作区干净）

$ pgrep -fl CortexSentinelBar
1791 /Applications/Cortex哨兵.app/Contents/MacOS/CortexSentinelBar
（唯一命中是生产哨兵，launchd 常驻、本线开工前就在，非本线所起，未动）

$ git worktree list | grep -i cor7600
/Users/falcon/Documents/Code/cortex-sentinel   067a340 [codex/cor7600-pack-stable-mirror]
（唯一命中是本线所在的主检出，未建任何 worktree）
```

## 换基重开（2026-09-20，主控返工）

**返工原因（主控原话：问题在我不在你）**：本线第一轮所基的本地 `main` 是 09-02 的旧树——实测 `git rev-list --count` 落后 origin/main **136** 笔、本地多 **79** 笔旧提交，导致 PR #44 变成 118 files / CONFLICTING。本线已关 PR #44（评论注明基错原因），换基重开。

| 项 | 值 |
|---|---|
| 新 PR | **#45**（changed_files=16，commits=3，OPEN，base main） |
| 新分支 | `codex/cor7600-pack-stable-mirror-v2`（基于 `origin/main`，tip `cd47865`） |
| `git rev-list --count origin/main..HEAD` | **3**（= 本线自己的三笔：cf77f38 功能、77a9f1d 回执证据、7ea795c 新基渲染证据） |
| `git rev-list --count HEAD..origin/main` | **0** |

**冲突按上游重写了哪几处：没有需要重写的——cherry-pick 两笔均零文本冲突**（git 三方自动并入）。上游 136 笔对本线触点的大改（`SentinelMenuSections.swift` +2060 行、`SentinelStore.swift` +725、`PanelPNGRenderer.swift` +432、`CortexSentinelBarApp.swift` ±124）与我的编辑区不重叠，逐点核过：

- 主控给的新基坐标核过：`SentinelFileReader.swift:55-63` 仍是 `defaultPackagingProgressRoot` 拼 `$TMPDIR/cortex-pack-progress`（我的 `packProgressHealthURL` 解析器落在同文件 :157 起）；「退到数据根 health/」先例注释在新基 `:121`（旧基 :113，行号漂移，语义同位）。
- `PackagingProgressTests` / `PackagingDisplayRegressionTests` / `PanelSectionIsolationTests` / `PackagingProgress.swift` 上游没动，原样落位。
- `PanelPreviewFixture` 名单测试（`PanelPNGRendererTests.testFixtureRawValuesMatchCLINames`）在新基上含本线三个新 fixture 仍精确匹配——上游没往这个枚举加东西。
- 没把任何旧结构搬回去：面板通道区已是上游新的 Codex / CodeBuddy / Grok 三卡与新版余额区，本线打包分区原样坐在其上（新基渲染 PNG 为证）。

**新基重跑测试**（隔离 `TMPDIR`，`out=$(swift test 2>&1); rc=$?`）：**rc=0，499 tests，0 failures**（旧基 369 → 新基 499，上游新增 130 条一并通过）。

**新基重出三态渲染证据**：`reports/cor7600-assets/` 三张 PNG 已替换为新基版本（面板 760→828 宽，running/idle/error 内容同前：版本·步次·起算·ETA / reason+上一炉 / error 单独成态），running 态亲眼复核，打包分区与上游新版布局共存正常。`--dump-state` 行为与旧基一致（同一段代码，未受上游影响）。

**旧分支清理**：新 PR 开好后已删——`git branch -D codex/cor7600-pack-stable-mirror`（was 76c656e）+ `git push origin --delete codex/cor7600-pack-stable-mirror`，本地与远端均已不存在；PR #44 已补评论注明新 PR 号（#45）。

## 返工第二节：error 人话上屏、与 running 视觉分档、ETA 带钟点（2026-09-20，主控审 PR #45 后）

**改后的三段上屏文案原文**（机器口径 reason 保留在读层与 `--dump-state`，与主仓遥测逐字一致那套不动；上屏走固定人话映射）：

- running：标题「Cortex 打包」+「打 DMG」详情 +「1.2.3 · 第 3/3 步 · 09:56:13 起算」+ 右上角「**大约还要 12 分钟 · 预计 10:33:13**」+「更新于 10:21:13」
- idle：标题「Cortex 打包」+「**当前没有在跑的炉**」（可带「上一炉 07:59:34」）
- error：标题「Cortex 打包」+「**读不到打包状态**」+「**下一炉起来会自己恢复**」——两种 error（文件读不了 / 位置定不出来）对用户是同一件事，合成同一句人话；读屏 label 同步改

**running 与 error 各自的样式**（`SentinelPackagingSectionMood` 三档，收在 `SentinelMenuSections.swift`）：

| 档 | 图标 | 行档位（背景/描边） | 前景色 |
|---|---|---|---|
| running | `shippingbox.fill` | `.warning`（橙） | `Colors.warning`（0xFB923C 橙） |
| idle | `shippingbox` | `.normal` | `Colors.secondaryForeground` |
| error | `exclamationmark.triangle.fill` | `.danger`（红） | `Colors.danger`（0xF87171 红） |

**新加的断言**（`PackagingDisplayRegressionTests`）：

- `testErrorMoodDiffersFromRunningInIconColorAndTone` —— 钉住 running 与 error 的图标、前景色、行档位三样全不同（idle 也不许跟 error 撞色）
- `testOnScreenPackagingCopySpeaksHumanWithoutInternalJargon` —— 守卫上屏四句文案不含内部词（JSON/数据根/稳定落点/登记/解析/镜像/schema/文件），并钉住 error 两句原文
- `testEtaDisplayCarriesArrivalClockFromEtaMilliseconds`（`PackagingProgressTests`）—— 「预计 HH:mm」钟点来自 eta_ms；没有 eta_ms 只剩时长不硬造钟点

**重跑 `swift test`**（隔离 `TMPDIR`，`out=$(swift test 2>&1); rc=$?`）：**rc=0，502 tests，0 failures**（499 + 返工新增 3 条；夹具补 eta_ms 后复跑仍全绿）。

**三张 PNG 重出**（`reports/cor7600-assets/` 已替换，error 那张就是改后的红色档）：

- `panel-pack-stable-running.png`：橙框 + 「大约还要 12 分钟 · 预计 10:33:13」（时长和钟点都在，宽度无压力）
- `panel-pack-stable-idle.png`：灰档 +「当前没有在跑的炉 / 上一炉 07:59:34」
- `panel-pack-stable-error.png`：**红框红三角 +「读不到打包状态 / 下一炉起来会自己恢复」**——不读字也能跟 running 分开

夹具顺带修正：`writeStablePackProgress` 的 running 载荷补了 `eta_ms`（真实炉写方本就带，首轮夹具漏了导致首版渲染没出钟点）。契约文档「打包进度块」行同步改写。
