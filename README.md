# Cortex 哨兵

这是一个 macOS 菜单栏应用。给需要盯着 AI 编码任务是否还在跑、中转是否通、密钥余额还剩多少的人用。装上之后菜单栏会出现一个叫「Cortex 哨兵」的图标，点开是一块固定宽度的状态面板。

Swift + SwiftUI 写成，单二进制，没有第三方依赖。

## 产品结构

Cortex 哨兵是一个产品，前端和后端放在同一个仓库中，各自占一个目录层级。

### 前端

这是一个 macOS 菜单栏应用。给需要盯着 AI 编码任务是否还在跑、中转是否通、密钥余额还剩多少的人用。装上之后菜单栏会出现一个叫「Cortex 哨兵」的图标，点开是一块固定宽度的状态面板。

Swift + SwiftUI 写成，单二进制，没有第三方依赖。

从源码安装：

```bash
bash scripts/install-app.sh
```

本机需要能跑 `swift`。

### 后端

`backend/` 是 Python 后端，负责盯线、通道和机器健康。它只需要系统自带的 Python 3.9+，不需要虚拟环境或 `pip`。从仓库根目录运行：

```bash
cd backend
/usr/bin/python3 -m cortex_sentinel doctor
/usr/bin/python3 -m cortex_sentinel status
/usr/bin/python3 -m cortex_sentinel watch list
/usr/bin/python3 -m cortex_sentinel lines
/usr/bin/python3 -m cortex_sentinel reap
/usr/bin/python3 -m cortex_sentinel dispatch grok --help
```

也可以使用可执行入口：

```bash
cd backend
./bin/cortex-sentinel doctor
```

## 功能

- **Input 服务探针**：三个监控模型（gpt-5.6-sol / gpt-5.6-terra / gpt-5.5）各一行 60 格历史条，绿=通、橙=高延迟（≥3s）、红=失败；状态栏三个彩点与面板同一套颜色口径。数据来自公开的 Input 状态接口，不依赖本仓库以外的代码。
- **GPT 官方额度**：只读本机 `~/.codex/auth.json` 的 Codex 登录态，查询 GPT 官方 usage；每 10 分钟自动校对，菜单内可立即刷新。失败时保留上次成功值并标记过期。没有这份登录文件时，这一块没有数据。
- **密钥池余额**：读取本机 AIO 聚合网关的数据库和清单，一把钥匙一行，显示余额、到期日、熔断状态，低余额橙色示警。没有装 AIO 时显示未配置，不会崩溃。
- **派工线监控**：扫描监视目录里的状态文件，显示每条编码任务的名称、来源、运行状态（工作中 / 一段时间没动静 / 卡住后被守护进程重拉）、重拉次数、通道。完成的线可以点开看起止时间。状态文件通常由派工守护进程写入；格式见下文，可以自己写。
- **日志自动清理**：启动时和每小时各扫一次监视目录，只处理约定文件名的派工日志（正在跑的不删）。目录超过 500MB 时从最旧删到 400MB 以下。可用命令行做 dry-run。
- 任务进入收工 / 求助 / 失联时发 macOS 通知。

做不到的事：它不代替派工守护进程去拉起或杀掉模型进程；面板上的线控按钮只是往监视目录写控制文件，需要有进程按同一约定来读。它也不打包、不上传、不提供云端账号。

## 我没有 Cortex，这东西对我有用吗

有用，但只在你按它约定的目录格式提供数据时，派工线才会出现。它不绑定某个叫 Cortex 的代码仓库。监视目录可以是任意文件夹，里面放 JSON 即可。

没有那些文件时，应用仍会启动。面板会写明监视目录不存在或为空，并指出该设哪个环境变量。Input 探针只要网络通就能用。GPT 额度和 AIO 余额分别取决于本机有没有 Codex 登录态和 AIO 数据，与 Cortex 无关。

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

## 构建与安装

见 [INSTALL.md](INSTALL.md)。没有开发环境时，打开安装盘，把「Cortex哨兵」拖到「应用程序」——这个包没有经过 Apple 公证，第一次打开会被系统拦一次，INSTALL.md 里写了怎么过。从源码安装：

```bash
bash scripts/install-app.sh
```

本机需要能跑 `swift`。

## 仓库里有什么

- `Sources/` — 应用本体
- `Tests/` — 单元测试，`swift test` 跑
- `scripts/` — 构建、打安装盘、装到系统
- `Resources/` — Info.plist 与应用图标
- `backend/` — Python 后端、测试、launchd 模板与运维脚本

这个仓库是从一个内部开发仓整理出来的，只带了程序本身。历版工单、设计文档、开发期的运行数据都没有带过来，所以这里看不到它们，提交历史也是从整理那天重新开始的。
