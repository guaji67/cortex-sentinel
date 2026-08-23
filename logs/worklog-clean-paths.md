# worklog: clean-paths 线

分支 `codex/sentinel-clean-paths`，基线 `4c711df`，工作树 `/Users/falcon/Documents/Code/cortex-sentinel-worktrees/clean-paths`。

## 第一件: 清公开仓真实用户路径

### 阳性对照（判据 3，两半都有）

改前:
- `grep -rn "/Users/falcon" Sources/ scripts/ Tests/` → **3 命中**
  - SentinelFileReader.swift:45
  - SentinelSettingsView.swift:239
  - Tests/LoginItemPolicyTests.swift:102（任务书没列的漏网第三处）
- `grep -rn "Documents/Code" Sources/ scripts/` → **4 命中**（Sources 1 + scripts/install-app.sh 3）

改后: 两条 grep **0 命中**。backend/ 目录顺手扫出同款泄漏也一并清了（paths.py docstring 示例、README.md 配置示例）。

### 改动明细

| 文件 | 改法 |
|---|---|
| `SentinelFileReader.swift` | 删写死的 `selfHealingRepositoryRoot` 静态属性；新增 `selfHealingLogsDirectory(environment:homeDirectory:) -> URL?`：① CORTEX_SENTINEL_WATCH_DIR ② ~/.cortex-sentinel/logs ③ home 取不到返回 nil 上层走空态。`discover()` 参数从 `selfHealingRepositoryRoot: URL` 换成 `selfHealingLogsDirectory: URL?`，自愈块适配：兜底为 nil 时跳过自愈自然落空态；切换时 repositoryRoot 取兜底日志目录父目录（与既有 defaultHome 分支惯例一致） |
| `SentinelSettingsView.swift` | preview fixture 的 watchPath 复用现成的 `SentinelPaths.defaultWatchDirectory.path`（不造新轮子） |
| `Tests/LoginItemPolicyTests.swift` | 测试夹具环境变量路径换成中性 `/tmp/cortex-repo-fixture`（该字符串只进 plist 字典比对，内容无语义） |
| `scripts/install-app.sh` | 删掉「自动探测 ~/Documents/Code/cortex/logs」整层猜测（定义、usage 行、elif 分支共 6 行）。装法收敛为 WATCH_DIR → CORTEX_REPO_ROOT → ~/.cortex-sentinel/logs 默认，与 INSTALL.md 主体的既定方向对齐 |
| `INSTALL.md` | 删掉「若本机存在 ~/Documents/Code/cortex/logs，交互安装会问要不要用它」——脚本里从来没有交互询问逻辑，这句是描述漂移，删探测层后更不成立 |
| `backend/paths.py` + `backend/README.md` | 示例配置的真实绝对路径换中性占位 `/path/to/cortex`、`/path/to/cortex-data` |

### 自愈逻辑还工作吗（任务书指定确认项）

原来被调用的场景: 用户状态文件在旧仓库 logs、没设环境变量、默认目录空的 → 自愈切到写死的仓根 logs。
改造后推演（7 个场景全部闭合）:
- 生产无显式配置（defaultHome）: 兜底 == 主解析目录 → 条件里目录不等检查挡住，不自愈，空态三行文案正常出。
- 生产设了 WATCH_DIR / REPO_ROOT / UserDefaults: resolved.source 非 defaultHome 且注入值等于生产默认 → 不自愈（显式配置不被劫持，原意图保留）。
- 兜底 nil（home 取不到）: `if let fallbackLogsDirectory` 直接跳过，上层走空态。
- 测试注入自定义兜底: 与默认值不等 → 尝试自愈，原有切换行为原样可触发。
新增两个测试覆盖: `testSelfHealingLogsDirectoryResolutionOrder`（解析顺序 + home nil）、`testDiscoverStaysOnEmptyStateWhenNothingExists`（环境没设+目录不存在 → 不崩/不自愈/不偷换路径/落空态）。

### 能力核对

- `SentinelFileReader.swift`: 基线 160 个成员声明 → 改后 160 个（-1 写死静态属性 +1 动态函数，其余 159 个原样）。
- `install-app.sh` 其余逻辑零改动（diff 复核过）。

## 第二件: 最近完成行补处置结论标记 (COR-502 修改五)

### 接法（按能力接，未整段复制）

底层能力 public 仓已齐: `LineDispositionPresentation.markerText`（SentinelModels.swift:1062，dead+note → 已有处置记录；其他终态+note → 有备注；无 note → nil），语义与 local 参考仓一致，零改动。
只欠 UI 接线，在 public `completedLineRow` 的 HStack 之后、展开详情之前插入折叠态标记块（checkmark.seal.fill + markerText，绿色 metadata 字号，accessibilityIdentifier 带 `completed-note-marker-\(line.slug)`），外加私有方法 `completedDispositionMarker(for:)`。注释按 public 仓语境重写，没有照搬 local 的段落。

### 阳性对照（双方向）

项目无 ViewInspector 等 UI 渲染测试设施（查过 Package.swift 和两仓 Tests），标记渲染条件就是一行 `if let markerText`，所以对照落在数据层:
新增 `testCompletedRowMarkerAppearsOnlyWhenNoteExists`:
- done + note → markerText = 有备注（标记出现）
- killed + note → markerText = 有备注（标记出现）
- done 无 note → nil（不出现）
- killed 无 note → nil（不出现）
dead+note → 已有处置记录 的方向已有 `testHandledDeadStillShowsHungLabelNotAReplacementWord` 盖着。
`grep -n "completed-note-marker" Sources/CortexSentinelBar/SentinelMenuView.swift` → 有命中（1 处）。

### 能力核对

`SentinelMenuView.swift`: 基线 119 个成员声明 → 改后 120 个（+1 新私有方法，原有 119 个全在）。

## 编译与测试

- `swift build`：0 error，退出码 **0**。
- `swift test --no-parallel`：308 tests，0 failures，退出码 **0**。
- 按任务书原命令再次执行 `swift test`：`Executed 308 tests, with 0 failures (0 unexpected)`，退出码 **0**（63.96 秒）。
- 本仓没有需要刷新的 pre-commit 生成物或登记锚点；提交未使用 `--no-verify`。

## 收工清点

- 本线未起任何常驻进程；测试临时目录均在系统临时区并由测试清理。
- `.cortex-session/checklist-subagent-clean-paths.md` 为本线清单，保持未暂存且不纳入提交。
- `logs/worklog-clean-paths.md` 已作为交付物纳入提交。

## 本轮红线诊断与修复（2026-08-23）

### 先复现再判断

- `PanelPNGRendererTests/testFixtureRawValuesMatchCLINames`：1 test，0 failures，退出码 0；该类代表性用例本身不读磁盘线数据。
- `StatusPublishDedupTests/testLinesChangePublishesOnceAndKeepsNewValue`：修复前退出码 1，断言实际读到 5 条本机线（包括 `case-harness-needs` 等），期望夹具只有 1 条 `alpha`；状态也从期望 `running` 变成了本机 `done`。这确认红线来自错误触发本机日志兜底，不是断言数字或面板能力本身。
- `StackedRefreshGateTests/testWritingRunningStatusAppearsAsRunning`：修复后 1 test，0 failures，退出码 0。

### 根因和修复

`SentinelPaths.discover` 的默认 `selfHealingLogsDirectory` 在进程环境中解析；测试把临时 `environment`（显式 `CORTEX_SENTINEL_WATCH_DIR`）传入时，旧判定拿这份临时 environment 再解析一次，因路径不同而把 `shouldAttemptSelfHealing` 置为真，于是空的临时目录被本机 `~/.cortex-sentinel/logs` 的真实状态文件劫持。修复为只与调用进程的默认兜底目录比较；只有显式注入另一份兜底目录或当前来源确实是默认 home 才尝试自愈。显式兜底测试仍验证切换，空态测试仍验证不偷换路径。

测试造数没有改成“把 12 改 1”：Status/Stacked/Panel 的夹具仍由各自 `setUp` 创建的临时目录和显式环境传入；只修正了空态诊断测试原先错误的文案断言，改为核对诊断包含当前缺失目录路径。

### 真实验证结果

- `swift build`：0 error，退出码 **0**。
- `swift test --no-parallel`：`Executed 308 tests, with 0 failures (0 unexpected)`，退出码 **0**。
- `grep -rn "/Users/falcon" Sources scripts Tests`：**0 命中**。
- `grep -c "completed-note-marker" Sources/CortexSentinelBar/SentinelMenuView.swift`：**1**。
- 阳性对照：临时追加 `// positive-control /Users/falcon` 后 grep **1**，恢复文件后再次 grep **0**；源文件恢复前后字节内容一致。

### 成员核对

本线改动的 10 个文件中，基线和改后均无 `public` 声明被删除（逐文件 grep 计数均为 0）；Swift 内部成员核对沿用前段记录：`SentinelFileReader.swift` 原有成员 160 个仍在（删写死属性并以动态解析函数替代），`SentinelMenuView.swift` 原有 119 个仍在并新增 1 个私有方法。

### 交付状态

- 代码和测试改动均保留在本工作树；`.cortex-session/` 只保留本线清单，不纳入提交。
- `logs/worklog-clean-paths.md` 作为交付物一并提交（该目录被 `.gitignore` 忽略，提交时需对该路径使用 `git add -f`）。

