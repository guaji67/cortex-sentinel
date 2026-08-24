# 哨兵面板手动接管与一键恢复 worklog

- 记录时间：2026-08-24 20:08:30 +0800（`TZ=Asia/Shanghai date`）
- 仓库：`/Users/falcon/Documents/Code/cortex-sentinel-public`
- 范围：只改 public 仓面板；没有改 cortex 守护脚本、旧哨兵仓或 `/Applications`

## 交付落点

### 1. 播放按钮是真开始

- `Sources/CortexSentinelBar/SentinelControlFile.swift`
  - 新增 `requestForceStart`。
  - 写入 `action=force_start`、`requested_at`、`requested_by=cortex_sentinel_panel`。
  - 沿用已有原子合并写入，保留同一控制文件里的设置字段。
  - 原有 `requestProbe` / `probe_now` 保留，供自动恢复探测使用。
- `Sources/CortexSentinelBar/SentinelLineControls.swift`
  - 播放按钮改调 `requestForceStart`。
  - 点击后行内显示“已发出”；失败则显示“失败”并在 help 中给出错误。

### 2. 一键恢复

- `Sources/CortexSentinelBar/SentinelMenuView.swift`
  - 活跃派工区标题右侧新增常驻“一键恢复 N”按钮。
  - 操作完成后保留可见反馈：`已发出 N 条`；部分失败则同时显示成功数和失败数。
- `Sources/CortexSentinelBar/SentinelLineControls.swift`
  - `SentinelForceStartAction` 统一逐线与批量的候选判据和控制文件写入。

选取范围：本轮面板活跃分组 `activeRegistered + activeUnregistered` 中，引擎解析为
Codex、状态非 `done/killed`、状态不为 `running` 的线。由此覆盖
`waiting_relay`、`retrying`、`backoff`、`help`、`dead` 和未知等待态；明确排除
真正 `running`、两个终态、历史/陈旧线和 Grok/ox-alpha，避免给不消费 Codex
控制协议的引擎写文件。

### 3. 强制模式可见

- `Sources/CortexSentinelBar/SentinelModels.swift`
  - 新增 `LineForceStart`，读取 `active`、`activated_at`、`activated_by`。
- `Sources/CortexSentinelBar/SentinelFileReader.swift`
  - 从状态文件的 `force_start` 块填入 `LineStatus.forceStart`。
- `Sources/CortexSentinelBar/SentinelMenuView.swift`
  - `force_start.active=true` 时，在状态列显示蓝色“强制模式”标记。
  - hover help 显示来源和生效时间。

## 自动验证

- `swift build`：通过。
- `swift test --filter 'Sentinel(ControlFile|LineControls|FileReader)Tests'`：
  60 tests / 0 failures。
- `swift test`：330 tests / 0 failures，耗时 74.318 秒。
- 新增覆盖：
  - `force_start` 控制文件三字段和原有设置字段保留；
  - 一键恢复选中 6 种非运行 Codex 状态，不选 `running`、终态或 Grok；
  - `force_start` 状态块解码及“强制模式”显示判据。

## 独立窗口点击验证

- 临时目录：`/tmp/cortex-sentinel-force-start.2dyNwc`
- 启动体：`.build/debug/CortexSentinelBar --smoke-window --smoke-lines`
- 自测 PID：`39849`；结束时只执行 `kill -TERM 39849`，退出码 143。
- 生产 PID `68553` 在自测结束后仍在运行。
- 实际点击逐线播放按钮：行内显示“已发出”，生成：

```json
{
  "action": "force_start",
  "requested_at": "2026-08-24T12:05:14Z",
  "requested_by": "cortex_sentinel_panel"
}
```

- 实际点击“一键恢复 1”：面板显示“已发出 1 条”，控制文件仍是相同三字段契约，
  `requested_at` 更新为 `2026-08-24T12:05:31Z`。
- 随后只在临时状态文件写入
  `force_start={active:true, activated_at:..., activated_by:cortex_sentinel_panel}`；
  面板刷新后该线实际显示“强制模式”。

## 尚未执行

- 没有把构建产物安装到 `/Applications`；按任务边界留给装机主控。
- 没有用真实 `logs/` 或真实 Codex 线做演练，因此没有触发、重派或清理现有 8 条任务。
- 面板侧三项需求没有已知遗留；守护侧持续重试语义沿用已完成的 `e4461770d`。
