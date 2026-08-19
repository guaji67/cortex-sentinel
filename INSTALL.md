# 安装 Cortex 哨兵

macOS 菜单栏应用。装好后菜单栏出现「Cortex 哨兵」图标；面板宽度 380pt。需要 macOS 14 或更高，目前构建目标是 arm64。

## 两种装法，先选一种

- **只想用**：拿一份编好的安装盘（`.dmg`），拖进「应用程序」。目标机不需要 Swift，不需要 Xcode。往下看这一节。
- **手上有源码、机器上装了 Swift**：跑安装脚本，它会顺带把开机自启配好。跳到「从源码安装」。

两条路装出来的是同一个 app。区别只有一个：**重启之后会不会自己回来**。见下面「重启之后」。

## 装法一：拖进「应用程序」

打开安装盘，一侧是应用、一侧是「应用程序」快捷方式，把应用拖过去。

本仓库不附带编好的包。只有源码、机器上又没有编译工具时装不上，得先在一台装了 Swift 的机器上编一份（见「自己构建 app」），再把包拷过来。

### 第一次打开会被系统拦住

这个包是 ad-hoc 签名，没有经过 Apple 公证。**从网页下载的包，第一次打开一定会被 macOS 拦下来。** 它会说无法验证开发者、无法确认是否包含恶意软件，按钮通常只有「移到废纸篓」和「完成」，没有「仍要打开」。

这不是包坏了，是没有花钱买 Apple 的开发者签名。

macOS 15 起，老办法（在 Finder 里右键选「打开」）已经不管用了。现在的路径是：

1. 先正常双击一次这个应用，让它被拦一次。**这一步不能跳**，系统要先记下你想开它。
2. 打开「系统设置」→「隐私与安全性」。
3. 往下拉到底部，会看到一行写着「Cortex哨兵」已被阻止使用，旁边有「仍要打开」。
4. 点它，再确认一次，输入这台电脑的登录密码。

之后再打开就不拦了。

**这一步只有你本人能做。** 它是系统级确认，没法代劳，也没法用脚本跳过——能跳过的写法都是在关掉整台机器的安全防线，不要用。如果你对这个包的来源没把握，那就先别装，去问给你包的人。

（长期该走的路是用 Apple Developer ID 签名并做公证，那样这一整节都不需要。当前脚本还做不到。）

### 装好之后应该看到什么

菜单栏右上角出现哨兵图标。点开面板，第一次多半是空的，写着三行：

> 还没有可盯的线
>
> 哨兵盯一个目录，里面是派工工具写的状态文件。这个目录现在还不存在。
>
> 默认位置 ~/.cortex-sentinel/logs，把状态文件放进去就能看到。要换地方，设 CORTEX_SENTINEL_WATCH_DIR。

**看到这三行就是装成功了**，不是出错。哨兵自己不产生任何数据，它只是盯着一个目录，看别人往里写的状态文件；那个目录还是空的，所以面板也是空的。

监视目录默认在 `~/.cortex-sentinel/logs`。要换成别处，看最后一节「数据与环境变量」。如果换到「文稿」「下载」这类目录下，系统会再问一次文件夹访问权限，同意就好；只需要授权 `/Applications/Cortex哨兵.app` 这一条。安装器不改任何隐私授权，也不会替你绕过。

### 重启之后

会自己回来。第一次打开时哨兵会向系统申请一个登录项，之后每次开机它自动出现在菜单栏。macOS 会弹一条「已添加登录项」的通知，这是正常的，不用管。

不想让它开机自启，在设置里关掉（见下一节）。

### 设置

面板底部那排图标里有个齿轮，点开是一个独立的设置窗口，四样：

- **开机时自动启动** —— 不想要就关掉。如果这台机器是用下面「装法二」装的，这一项会置灰并写着由系统服务托管，改这里没用。
- **历史最多保留 ＿＿ 条** —— 默认 500。超出的旧记录会自动清掉，正在跑的线不会被清。
- **任务结束时通知我** —— 默认开。关掉之后不再弹 macOS 通知。
- **盯这个文件夹** —— 换监视目录，选完立刻生效，不用重启。如果启动时用环境变量指定过目录，这一项也会置灰并写着由启动配置指定。

设置存在本机，不会跟着安装包走。

## 装法二：从源码安装

这条路会配好开机自启。本机需要 Swift（随 Xcode 或 Command Line Tools）。在仓库根目录：

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
