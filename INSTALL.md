# 安装 Cortex 哨兵

macOS 菜单栏应用。装好后菜单栏出现「Cortex 哨兵」图标；面板宽度 380pt。需要 macOS 14 或更高，目前构建目标是 arm64。

## 没有开发环境

需要一份已经编好的 `Cortex哨兵.app`。若你拿到的是安装盘，打开后一侧是应用、一侧是「应用程序」快捷方式，把应用拖进「应用程序」即可。目标机不需要 Swift 或 Xcode。

本仓库源码本身不附带预编译包。只有 Mac、没有编译工具时，不能单靠 clone 源码装上；要先在一台装了 Swift 的机器上构建（见下一节），再把 app 拷过去，或用 `scripts/build-dmg.sh` 打安装盘。

当前构建是 ad-hoc 签名，没有公证。第一次打开时，系统可能拦截，需要在 Finder 里右键该 app 选打开，并确认。安装器不会改 TCC，也不会绕过隐私授权。监视目录若落在「文稿」下，系统可能再问一次文件夹权限，只授权 `/Applications/Cortex哨兵.app` 这一条。

## 从源码安装

本机需要 Swift（随 Xcode 或 Command Line Tools）。在仓库根目录：

```bash
bash scripts/install-app.sh
```

Finder 里也可以双击 `Install-Cortex-Sentinel.command`；若同目录没有预构建 app，它会走上面这条构建路径。

安装器会：构建（或使用 `--app-source` 指定的预构建包）→ 备份当前安装 → 停掉旧的 launchd 托管 → 清掉迁移残留登录项 → 把 app 放到 `/Applications/Cortex哨兵.app` → 写 launchd plist → 重新托管 → 断言只有一个实例 → 跑一次 `--dump-state`。中途失败会把上一版 app 和 plist 装回去。

更新版本也用这一条，不要手动 `pkill`。plist 开了 KeepAlive：进程被杀后会马上拉起，若那时文件还没覆盖完，跑起来的仍是旧二进制。

自启配置在 `~/Library/LaunchAgents/com.cortex.sentinelbar.plist`（RunAtLoad + KeepAlive）。入口：启动台、应用程序文件夹，或 Spotlight 搜 Cortex。

经 SSH 执行时，安装器会跳过可能卡住的 System Events 登录项查询，但仍会停掉并归档旧路径上的 app。

可选参数：

```bash
bash scripts/install-app.sh --app-source /path/to/Cortex哨兵.app
bash scripts/install-app.sh --cortex-root /path/to/repo
```

`--cortex-root` 和环境变量 `CORTEX_REPO_ROOT` 是旧装法：监视 `<该路径>/logs`。新装法用 `CORTEX_SENTINEL_WATCH_DIR` 直接指向日志目录。两者都没有时，安装器创建并使用 `~/.cortex-sentinel/logs`。若本机存在 `~/Documents/Code/cortex/logs`，交互安装会问要不要用它，不会自动替你选。

## 自己构建 app

```bash
swift build
swift test
bash scripts/build-app.sh
codesign --verify --deep --strict .build/CortexSentinelBar.app
```

`build-app.sh` 生成 `.build/CortexSentinelBar.app`，ad-hoc 签名。不要把这份 `.build` 里的 app 当成正式入口长期跑；正式入口是 `/Applications` 加 launchd。

打安装盘（需要源码干净、本机有 Swift）：

```bash
bash scripts/build-dmg.sh
```

产出 `dist/cortex-sentinel-<version>-arm64.dmg`：打开后拖到「应用程序」即可安装。外发给不认识的机器前应改用 Developer ID、Hardened Runtime、公证和 stapling；当前脚本做不到这些。

## 开发调试（不装系统）

```bash
open .build/CortexSentinelBar.app
```

窗口模式（和菜单栏面板共用同一套视图）：

```bash
.build/CortexSentinelBar.app/Contents/MacOS/CortexSentinelBar --smoke-window
.build/CortexSentinelBar.app/Contents/MacOS/CortexSentinelBar --smoke-window --smoke-lines
```

只打印当前读到的状态、不改菜单栏常驻实例：

```bash
CORTEX_SENTINEL_WATCH_DIR=/path/to/logs \
  .build/release/CortexSentinelBar --dump-state
```

不要对已经在 `/Applications` 里跑着的那一份做实验。

## 数据与环境变量

派工线读取监视目录（见 README 的格式说明）：

- `codex-babysitter-*.status.json` / `grok-*.status.json`：任务状态；按文件修改时间判断约 10 分钟的活跃窗口
- `codex-line-registry.json`：可选登记表，用来显示中文任务名和来源

其它本机数据，都不是 Cortex 仓库：

- `~/.aio-coding-hub/`：AIO 密钥池与路由
- `~/.codex/config.toml`、`~/.codex/auth.json`：Codex 配置和登录态
- `https://status.input.im/api/status`：Input 探针，60 秒轮询、15 秒超时

覆盖路径示例：

```bash
export CORTEX_SENTINEL_WATCH_DIR=/path/to/logs
export CORTEX_REPO_ROOT=/path/to/repo
export CORTEX_AIO_DB_PATH=/tmp/aio-coding-hub.db
export CORTEX_AIO_CODEX_MANIFEST_PATH=/tmp/codex-manifest.json
export CORTEX_CODEX_CONFIG_PATH=/tmp/config.toml
export CORTEX_INPUT_STATUS_URL=https://status.example.test/api/status
```

`CORTEX_SENTINEL_WATCH_DIR` 优先于 `CORTEX_REPO_ROOT`。
