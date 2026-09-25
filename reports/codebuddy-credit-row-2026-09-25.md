# 回执：余额区加 CodeBuddy 行，三个 Buddy 号剩余积分并排显示（COR-8647）

分支 `feat/codebuddy-credit-row`（基于哨兵仓 origin/main 66f99f2），工作树 `/Users/falcon/Documents/Code/cortex-sentinel-wt/buddy-credit`。

## 改了哪些文件

新增：

- `Sources/CortexSentinelBar/CodeBuddyCredit.swift`：账号模型（key / label / credits / todayUsed / totalUsed / totalRecharged / expiresAt 三态 / banned / checkedAt / stale / errorMessage）、快照（含 payBase1000 现价，读不到保留旧值）、抓取器（多号并发、单请求 10 秒超时、封禁号在抓取层剔除、失败保留旧数标过期）、颜色三档与取整 / 人民币折算 / 格子拆分常量、`~/.codebuddy/models.json` 的 `bc_` key 识别、键池（手加在前、本机识别在后、同 key 手加名字优先、删除名单）、`--codebuddy-credit-json` CLI。
- `Tests/CortexSentinelBarTests/CodeBuddyCreditTests.swift`：24 条测试，全用夹具，不读真实 `~/.codebuddy`。

修改：

- `Sources/CortexSentinelBar/SentinelSettings.swift`：`codeBuddyUserKeys` / `codeBuddyRemovedKeys` 两个 UserDefaults 键 + 一组存取函数；设置文案（CodeBuddy Key 组）。
- `Sources/CortexSentinelBar/SentinelSettingsView.swift`：设置模型加 `cbEntries` / `cbNewLabel` / `cbNewKey` 与 `applyCodeBuddyKeys` 回调；`addCodeBuddyKey`（校验 `bc_` 前缀 + 最短 20 位）、`removeCodeBuddyKey`；设置窗加 CodeBuddy key 管理组（列表 + 删除 + 添加行）。
- `Sources/CortexSentinelBar/SentinelStore.swift`：`codeBuddyCredit` 快照状态、刷新闸与时间戳、`refreshCodeBuddyCredit`（复查间隔同 GLM/Cursor，开面板 bypass 立拉，现价与账号同轮并发抓）、`reloadCodeBuddyKeys`、`codeBuddyKeysDidChange`（保存后立刻重查）；启动 / 定时 / 开面板 / 手动刷新 / 打开设置五个时机全部挂上；`injectPreviewData` 加 `codeBuddy` 参数。
- `Sources/CortexSentinelBar/SentinelMenuSections.swift`：余额区 `glmUsageRows` 之后、`cursorUsageRow` 之前插入 `codeBuddyUsageRow`；行照 Cursor 行写法（状态点 + 行名 + 三格等宽网格 `quotaSegmentWithBar(barFraction: nil)`，列宽同 Cursor，无横条）；状态点取三格最坏档；悬停详情卡每号三行（余额+人民币 / key 头尾+到期 / 今日+累计），超三个的号全进悬停，失败原因写在余额行备注。
- `Sources/CortexSentinelBar/PanelPNGRenderer.swift`：演示余额加 CodeBuddy 一行（Pro 10200 / Max 9200 / mini 8000，payBase1000=3）。
- `Sources/CortexSentinelBar/CortexSentinelBarApp.swift`：新命令行参数 `--codebuddy-credit-json`，打印 JSON 后退出，不占哨兵实例。

## PR

PR 链接：https://github.com/guaji67/cortex-sentinel/pull/53

## 验证真数字

1. `swift build`：Build complete!（15.99s，无 error；仅仓里原有的 onChange 弃用警告，与本次改动无关）。
2. `swift test --filter CodeBuddyCredit`：`Executed 24 tests, with 0 failures (0 unexpected) in 0.025 (0.028) seconds`。覆盖：正常返回解析、封禁解析且不进格子（bannedCount=1）、expiresAt 三态（缺失 / null / 有值）、非 200 带 error 与不带 error 兜底、models.json 夹具识别 `bc_` key 并去重跳过非 `bc_`、手加名字顺序压过「本机」、删除名单生效、超三个只取前三、取整（15199.13→15199、9960.51→9960）、颜色三档边界（2000/500/499/50/49/0）、到期不影响颜色、人民币读 payBase1000 读不到不显示、刷新失败保留旧数标过期、设置持久化往返、CLI JSON 只露头尾且完整 key 不出现。
3. 全量 `swift test`（最终代码上跑）：`Executed 554 tests, with 0 failures (0 unexpected) in 81.654 (81.713) seconds`。
4. `--codebuddy-credit-json` 真机输出（本机 `~/.codebuddy/models.json` 有两把 key：一把正常、一把封禁；key 只露头尾）：

```json
{
  "accounts": [
    {
      "credits": 14414.45,
      "error": null,
      "expires_at": "2026-12-31T15:59:59Z",
      "key_masked": "bc_dac…ed21",
      "label": "本机",
      "source": "local",
      "today_used": 5379.19,
      "total_recharged": 100000,
      "total_used": 87585.55
    }
  ],
  "banned_count": 1,
  "checked_at": "2026-09-25T01:00:47Z",
  "pay_base_1000": 3,
  "schema": 1
}
```

   正常号带余额，封禁号（bc_740f…68a0）不出现在账号列表、只计进 banned_count；现价 payBase1000=3 从站点 /api/settings 现读。

5. 面板图：
   - `reports/codebuddy-credit-row-2026-09-25-panel.png`（--render-panel-png --demo-balances）：CodeBuddy 行在 GLM 行之后、Cursor 行之前，`Pro 10200 / Max 9200 / mini 8000` 三格并排，五位数不截断，与 Cursor 行 Grok/API/Bot 同列对齐，无横条，三格全绿（≥500）。
   - `reports/codebuddy-credit-row-2026-09-25-hover.png`（加 --preview-hover-card --preview-hover-row CodeBuddy）：悬停卡标题、按站点现价 1000 积分 = 3 元、每号三行（余额+≈¥ / key 头尾+到期 / 今日+累+充）、页脚更新时间，无截断。
   - 五位数在默认格子字号下放得下，没有降字号。

## 手加 key 的存取（主控预置用）

- UserDefaults 域名：`com.cortex.sentinelbar`（生产 app 的 bundle id；键名里带的 `com.falcon.cortex.sentinelbar.` 前缀是历史命名，与 GLM / Command Code 键同前缀，实测生产域里现有 glmUserKeys 等键同住此域）。
- 键名：
  - 手加 key 列表：`com.falcon.cortex.sentinelbar.codeBuddyUserKeys`
  - 删除名单（防自动识别的 key 删后又被认回来）：`com.falcon.cortex.sentinelbar.codeBuddyRemovedKeys`
- 数据格式：JSON 数组，元素为 `{"label": "<短名>", "key": "bc_…"}`（`source` 字段可省，保存路径会写 `"user"`；删除名单元素 label 为空串）。格子顺序即数组顺序，封禁的号不显示。
- 预置三个号的例子：

```bash
defaults write com.cortex.sentinelbar com.falcon.cortex.sentinelbar.codeBuddyUserKeys '[{"label":"Pro","key":"bc_xxx1","source":"user"},{"label":"Max","key":"bc_xxx2","source":"user"},{"label":"mini","key":"bc_xxx3","source":"user"}]'
```

- 注意：本机 models.json 里已有的那把正常 key 会以「本机」短名自动出现在手加 key 之后；同一把 key 若手加并用短名命名，以手加的名字和位置为准。不想让「本机」那把出现，就用删除名单或让它保持封禁（封禁号不显示）。

## 没做完或拿不准的地方

- 工单第 8 条的面板落点：没有做余额区引导行（工单第 2 条明确一个 key 都没有时整行不占位，跟 Cursor 一样，引导行没有触发点），key 的添加 / 删除放在设置窗 CodeBuddy Key 组里（短名 + key 两个框、`bc_` 前缀 + 至少 20 位校验、保存立刻重查、已加能删），行为与 Command Code 那套一致。
- 现价请求失败与字段缺失两种情况都返回 nil，界面保留上一轮现价；若站点真的下线了 payBase1000 字段，旧价会一直保留（人民币标注是悬停里的参考信息，不影响颜色与格子数值）。
- expiresAt 字段有值但格式解析失败时按永久有效兜底显示（到期只是悬停信息，不为格式抖动报错）。
- 悬停卡里的查询时间用整轮的快照时间（同一轮并发查，各号差异亚秒级），没有按号单列。

## 收工清理

- 本线未起任何常驻进程；出图与 JSON 验证都是一次性命令，跑完即退。pgrep 原样输出：

```
$ pgrep -fl "codebuddy-credit-json|render-panel-png"
（无输出，退出码 1）
```

- 删掉的东西：测试夹具写在系统临时目录且测试内 defer 自删，仓库内无临时文件残留。留了两个交付物：`reports/codebuddy-credit-row-2026-09-25-panel.png`（工单要求的验收图）和 `reports/codebuddy-credit-row-2026-09-25-hover.png`（悬停卡布局证据），随 PR 提交。本工作树与 `.build` 未删（主控验收还要用）。
- 收工清理：已核无残留进程。

## 出机器核验

```
$ git ls-remote --heads origin | awk '{print $2}' | grep -i 8647
（零命中：本线分支名 feat/codebuddy-credit-row 不含票号数字，按票号 grep 分支命中不了是预期。
  换分支名本体再核：）

$ git ls-remote --heads origin | awk '{print $2}' | grep -i codebuddy-credit-row
refs/heads/feat/codebuddy-credit-row

$ gh pr list --search "COR-8647 in:title" --state all --json number,url
[{"number":53,"url":"https://github.com/guaji67/cortex-sentinel/pull/53"}]
```

两条都核过：远端分支在（证有），PR #53 记录在（主判据）。东西已出机器。
