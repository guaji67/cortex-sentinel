# Cortex 哨兵

macOS 菜单栏应用。给需要盯着 AI 编码任务是否还在跑、中转通道是否通、各家订阅额度和余额还剩多少的人用。装上之后菜单栏会出现一个「Cortex 哨兵」图标，点开是一块固定宽度的状态面板。

Swift + SwiftUI 写成，单二进制，没有第三方依赖。

## 功能

### 面板（点开菜单栏图标）

- **通道**：Codex / Grok 两条通道的通断红绿灯，附最近一条报错摘录。
- **Input 服务**：三个监控模型（gpt-5.6-sol / gpt-5.6-terra / gpt-5.5）各一行 60 格历史条，绿=通、橙=高延迟（≥3s）、红=失败；可用率和样本数并排。数据来自公开的 Input 状态接口。
- **余额**：
  - **智谱 GLM**：每把 key 一行，探测到什么显示什么——有 Coding Plan 订阅显 5 小时窗 / 周窗剩余百分比，有按量计费现金余额显「余 ¥xx.xx」，都有就并排；什么都查不到显示「未知」。悬停看积分用量、重置时间和累计消费。key 从本机自动识别（键池、网关 .env、环境变量），设置窗里可以增删。
  - **Cursor**：模式 / API / Bot 三组剩余百分比一行。读本机 Cursor 登录态查官方接口，token 失效自动用 refresh token 续。
  - **GPT 官方**：读本机 `~/.codex/auth.json` 的 Codex 登录态查官方 usage，周额度一行。
  - **AIO 密钥池**：读本机 AIO 聚合网关的数据库和清单，一把钥匙一行，余额、到期日、熔断状态，低余额橙色示警。没装 AIO 时不占位。
- **派工线**：扫描监视目录里的状态文件，每条编码任务一行：名称、来源、运行状态（工作中 / 一段时间没动静 / 卡住后被守护进程重拉）、重拉次数、通道，最近的完成可展开看起止时间。面板上可以对单条线写控制文件（详见下文状态文件约定）。
- **通知**：任务收工、出问题、通道断或余额吃紧时发 macOS 通知，提醒频率可调。
- **日志清理**：启动时和每小时各扫一次监视目录，按约定文件名清理派工日志（正在跑的不删），目录超过 500MB 时从最旧删到 400MB 以下，可 dry-run。

### 状态栏

菜单栏图标本身可以带彩色状态点：Input 探针、打包进度、密钥池低余额都会反映上去，不用点开面板也能扫一眼。

## 我没有 Cortex，这东西对我有用吗

有用，但只在按它的目录约定提供数据时，派工线才会出现。它不绑定某个叫 Cortex 的代码仓库，监视目录可以是任意文件夹。没有那些文件时应用照常启动，面板会写明监视目录不存在，并指出该设哪个环境变量。Input 探针只要网络通就能用；GLM、Cursor、GPT 官方、AIO 各自取决于本机有没有对应的登录态或 key，互相独立，缺哪个少哪一块。

最小示例：把下面两个文件放到监视目录（默认 `~/.cortex-sentinel/logs`）。

`codex-babysitter-demo.status.json`：

```json
{
  "slug": "demo",
  "state": "running",
  "workdir": "/tmp/demo",
  "branch": "main",
  "updated_at": "2026-08-20T00:00:00Z",
  "restarts": 0
}
```

`codex-line-registry.json`（可选，用来显示中文名和来源；也可以是带 `version` / `lines` 的信封对象）：

```json
[
  {
    "slug": "demo",
    "label_zh": "示例任务",
    "dispatcher_zh": "手动写入",
    "registered_at": "2026-08-20T00:00:00Z"
  }
]
```

文件名规则：Codex 线是 `codex-babysitter-<slug>.status.json`，Grok 线是 `grok-<slug>.status.json`。只认这两种前缀加 `.status.json` 后缀。必填字段是 `state`；`slug` 缺了会用文件名里的那段。

可选文件：

- `channel-status.json`：通道通断摘要
- `codex-babysitter-<slug>.control.json`：给守护进程看的控制指令（由面板按钮写出）

## 监视目录怎么指定

解析顺序：

1. `CORTEX_SENTINEL_WATCH_DIR`：直接就是日志目录
2. `CORTEX_REPO_ROOT`：兼容旧装法，读取 `<该路径>/logs`
3. 都没设时：`~/.cortex-sentinel/logs`

launchd 安装时会把选中的那一项写进 `~/Library/LaunchAgents/com.cortex.sentinelbar.plist`。

## 安装

见 [INSTALL.md](INSTALL.md)。最快的路：到 [Releases](../../releases) 下载打过公证的 `.dmg`，把「Cortex哨兵」拖进「应用程序」，再跑安装盘里的 `Install-Cortex-Sentinel.command` 配好开机自启。从源码装：

```bash
bash scripts/install-app.sh
```

本机需要能跑 `swift`。

## 构建、测试与开发

```bash
swift build                # 编译
swift test                 # 全量单元测试
bash scripts/build-release.sh   # 签名 + 公证 + DMG（需要本机证书配置）
```

改面板后的真机验收可以离屏出一张带真实数据的面板图，不用对屏幕截图：

```bash
.build/debug/CortexSentinelBar --render-live-panel-png /tmp/panel.png --settle-seconds 20
```

其他开发辅助入口：`--dump-state`（把此刻从磁盘读到的东西原样打印）、`--render-panel-png`（按 fixture 出图）、`--smoke-popover`（交互验收）、`--cleanup-dry-run`（日志清理演练）。

## 仓库里有什么

- `Sources/` — 应用本体
- `Tests/` — 单元测试，`swift test` 跑
- `scripts/` — 构建、打安装盘、装到系统
- `Resources/` — Info.plist 与应用图标
- `backend/` — Python 后端（盯线、通道和机器健康），系统自带 Python 3.9+ 即可跑，无需 pip：

```bash
cd backend
/usr/bin/python3 -m cortex_sentinel doctor
/usr/bin/python3 -m cortex_sentinel status
```
