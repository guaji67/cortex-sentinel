# 哨兵分发现状（COR-7601 调研，2026-09-20）

范围：只读调研 + 本文，未碰 Falcon 的机器，未起真打包炉。所有行号基于本线调研分支（基于 main `2c4d924`，含 COR-7600）。

## 现状

### 1. 源码 → .app：两条链

- **开发链** `scripts/build-app.sh`：`swift build -c release`（build-app.sh:26）拼装 `.build/CortexSentinelBar.app`（build-app.sh:8,27-33），**ad-hoc 签名**（`codesign --force --deep --sign -`，build-app.sh:37），**不公证**。CFBundleVersion 只在产物里戳 `dev`（build-app.sh:10,30），仓里的 `Resources/Info.plist` 本身不改（build-app.sh:2 明文）。这种包拷到别的机器会被 Gatekeeper 拦（INSTALL.md:18-35 专讲这个）。
- **正式链** `scripts/build-release.sh`：swift build + 拼 app（build-release.sh:75-82）→ 戳版本（build-release.sh:84-85）→ 安装器清单并核 commit（build-release.sh:87-94）→ **Developer ID 签名**（identity 是写死的证书 SHA-1，build-release.sh:13；hardened runtime + timestamp，build-release.sh:102）→ app 公证 + staple（build-release.sh:105-132）→ `build-dmg.sh` 出盘（HFS+ ULMO、Finder 摆位，build-dmg.sh:113-222）→ DMG 签名 + 公证 + staple（build-release.sh:143-151）→ spctl / 挂载终验（build-release.sh:153-181）→ 产物落 `dist/Cortex哨兵-$version.dmg` + `.sha256` + `.manifest.json`（build-release.sh:19,185-201）。
- DMG 盘面固定叫 `Cortex哨兵.app`，launchd / 自更新 / 面板全部按 `/Applications/Cortex哨兵.app` 找它（build-dmg.sh:57-59）。

### 2. 装到一台机器：`install-app.sh`

- 两种模式：不带 `--app-source` 就从当前源码现场构建（install-app.sh:618-620）；带 `--app-source` 用预构建 app，**目标机不需要 Swift/Xcode**（install-app.sh:307,492-495）。两条路装出来是同一个 app（INSTALL.md:5-10）。
- 装到 `/Applications/Cortex哨兵.app`（install-app.sh:15）。流程：先把现有 app/plist/重启入口备份到 `~/Library/Application Support/Cortex/SentinelInstallBackups/<时刻>`（install-app.sh:635-652），失败自动回滚（install-app.sh:654-679）→ `launchctl bootout` 停旧托管 + 停旧进程（install-app.sh:682,689）→ 清旧登录项、归档历史遗留 app（install-app.sh:684-688,545-587）→ ditto 新 app（install-app.sh:692-693）→ 签名 / 安装器清单 / arm64 校验（install-app.sh:624-633）→ 写 LaunchAgent `~/Library/LaunchAgents/com.cortex.sentinelbar.plist`（RunAtLoad + KeepAlive，install-app.sh:589-609）→ bootstrap 回来（install-app.sh:702）→ 断言唯一实例（install-app.sh:705-711）。
- **登录项**：不加 System Events 登录项，开机自启走 LaunchAgent；安装器反而会把旧的重复登录项删掉（install-app.sh:145-157,728）。
- 权限与弹窗：全程用户域，**不用 sudo / 管理员密码**；SSH 会话自动跳过可能卡死的 System Events 查询（install-app.sh:36-38）；`--dump-state` 自检在首次换机时可能弹一次文稿权限（install-app.sh:714 注释）。
- 配套：同时放 `/Applications/重启 Cortex 哨兵.command`（install-app.sh:696-698；双击只对 label kickstart，restart-sentinel.command:6-14）；命令行入口 `sentinel-ctl.sh status|restart`（sentinel-ctl.sh:74-88）；卸载 `uninstall-app.sh`（uninstall-app.sh:36-41）。

### 3. 更新通道：有，而且跑到过 0.1.49

- 检查地址：`https://api.github.com/repos/guaji67/cortex-sentinel/releases/latest`（SentinelUpdater.swift:10-15）。节奏：**启动查一次 + 每小时一次**（SentinelUpdater.swift:17 checkInterval=3600；挂在官方额度定时器上 10 分钟拍一次、最短 1 小时真查，SentinelStore.swift:356-364 与 :1258 注释；面板打开也会补查 SentinelStore.swift:522）。已知短板：失败的检查同样锁一小时（docs/sentinel-ops-pitfalls.md:14）。
- 只认正式版（draft / prerelease 天然排除，SentinelUpdater.swift:5；docs/sentinel-ops-pitfalls.md:70）；只接受**严格更新**的 x.y.z tag（SentinelUpdater.swift:104-116）；本机当前版本读自已装 app 的 CFBundleShortVersionString（SentinelUpdater.swift:210-213）。
- 发现新版：发一次系统通知 + 后台静默下载 + sha256 校验（SentinelStore.swift:1299-1312；SentinelUpdater.swift:414-432），面板顶部出「重启更新」按钮；**设置里「自动下载并安装更新」开着才全自动**（SentinelStore.swift:1304-1306），该开关默认关（SentinelSettings.swift:516-517，`defaults.bool` 未设即 false；开关文案 SentinelSettings.swift:44-45）。
- 替换方式：先过 spctl 安全闸（不是 Developer ID 且系统认可的包一个字节都不换，SentinelUpdater.swift:313-317）→ 写一次性 LaunchAgent `com.cortex.sentinelbar.update` 执行「bootout 主任务 → rm 旧 app → ditto 新 app → 挂回主任务，没有主任务就 open」（SentinelUpdater.swift:321-371，脚本原文 :327-341）。为什么绕 launchd：install-app 会 bootout，直接当子进程跑会被连坐打死（SentinelUpdater.swift:241-245 注释；docs/sentinel-ops-pitfalls.md:16）。
- 资产名硬约束：`Cortex.-x.y.z.dmg` / `.dmg.sha256`（SentinelUpdater.swift:22-24），publish 脚本负责把中文名改 ASCII（publish-release.sh:8,25-30；docs/sentinel-ops-pitfalls.md:69）。
- 弹窗：同签名更新全程无弹窗；只有换签名那一次会出 App Management TCC（docs/sentinel-ops-pitfalls.md:17）。

### 4. 版本号在哪管

- 仓里 `Resources/Info.plist` 的 1.0/1 **不是版本源**，发布时才戳进产物（build-release.sh:84-85：CFBundleShortVersionString=$RELEASE_VERSION、CFBundleVersion=$RELEASE_BUILD_NUMBER，后者默认当天 Asia/Shanghai 日期，build-release.sh:11）。
- **谁改**：跑 `build-release.sh` 的人用环境变量 `RELEASE_VERSION` 现场定（build-release.sh:10）；仓里没有任何文件记录它，默认值 0.1.7 已是陈旧兜底。tag `v$version` 由 `publish-release.sh` 发 Release 时才创建（publish-release.sh:33-37）。
- **有没有跟构建绑定**：没有硬绑定。仅有的两道软约束：出包时校验清单 commit == HEAD（build-release.sh:89-94,166-170）；更新器要求 tag 形如 x.y.z 才认（SentinelUpdater.swift:74-102）。设置面板显示「版本 x.y.z」，dev 构建显示「开发版」（SentinelSettings.swift:51-52）。

### 5. 他那两台现在装的是哪一版——只有到机器上才知道

- **仓侧可确定**：更新源最新正式版 = **v0.1.49**（GitHub Latest；发布于 2026-09-18T03:25:54Z，即 2026-09-18 11:25:54 +0800；资产 `Cortex.-0.1.49.dmg/.dmg.sha256/.manifest.json`）。其 manifest 构建 commit `254c148`、generated_at 2026-09-18T11:24:59+0800；`254c148` 是现 main `2c4d924`（COR-7600 合并，2026-09-20 01:28 +0800 落）的祖先，`git rev-list --count 254c148..2c4d924` = 7。**结论：COR-7600 的打包三态不在任何一个已发布版本里。**
- **仓侧推不出**：每台机器实际装到哪一版、有没有开「自动下载并安装更新」，全是机器本机状态，仓里零记录（红线未 ssh）。机器侧唯一读法：哨兵设置面板的版本行，或读 `/Applications/Cortex哨兵.app/Contents/Info.plist`。
- 间接线索（不作判据）：Releases 在 2026-09-17~18 当天连发 0.1.40→0.1.49，说明至少一台机器的自更新链在那个窗口还是通的；但这推不出「现在」装的是哪版。

## 最小动作（把 COR-7600 送到他两台机器上）

通道是现成的，最小动作 = **出一版并发布**，他两台机器零操作或一键：

1. **出包**（在持有签名/公证钥匙串的那台构建机上跑——脚本写死读 `$HOME/.cortex-build/devid.keychain-db`、`notary.keychain-db` 及配套密码文件，build-release.sh:13-18,49-64，没有这两串的机器跑不了）：
   ```
   RELEASE_VERSION=0.1.50 bash scripts/build-release.sh
   bash scripts/publish-release.sh 0.1.50 dist/Cortex哨兵-0.1.50.notes.md
   ```
   前提与体感：机器有 Swift；脚本自己解锁钥匙串（密码从文件 stdin 进，build-release.sh:66-72），全程不要管理员密码、不弹窗；`build-dmg.sh` 用 osascript 摆 Finder 版式，宿主没给「自动化」授权会以 78 退出并提示去勾选 Finder（build-dmg.sh:161-164）。**本票没有替跑**——真出包属于起新炉，须另行授权或由他本人执行。
2. **他那边**，二选一、都轮不到我们动手：
   - 「自动下载并安装更新」开着：发布后至多一小时内自动换装重启，全程静默。
   - 关着：至多一小时（或哨兵下次启动）弹一条通知 + 面板顶部「重启更新」按钮，**他本人点**；点之前只是下载 + 校验，不换任何东西。
3. 例外：若某台停在 ≤0.1.27（0.1.28 换装方式断层的旧版），自更新永远失败，只能手动换装——bootout 主任务 → rm 旧 app → ditto 新盘里的 app → bootstrap 主任务（docs/sentinel-ops-pitfalls.md:84-85），或他用 `install-app.sh --app-source` 装挂载盘里的 app。是否在断层之下，同样只有到机器上才知道。

## 缺口

**「最后一跳」（装好的哨兵 ← 更新源）是通的，真正缺的是「第一跳」（main ← 更新源）：合进 main 不等于出了版，出版全靠人手。**

- 实证：COR-7600 在 main 已落（2026-09-20 01:28 +0800），更新源还停在 0.1.49（2026-09-18 出）——期间没有任何人跑 `build-release.sh` + `publish-release.sh`，他的机器就永远收不到。这与「打包状态等包只能靠问人」同族：东西做好了，没有一条自动的路把它送到他眼前。
- 手工耦合点（坐标）：版本号靠人赋 env（build-release.sh:10）；出包必须在持钥匙串的那台机器上手跑（build-release.sh:13-18）；发布靠人手跑 publish-release.sh（publish-release.sh:33）。本仓无 CI，没有「merge 即发布」，也没有从 tag/commit 自动编号、自动出 notes 的机制。
- 次要断层：开发链（ad-hoc）与正式链（Developer ID + 公证）签名形态不同，ad-hoc 包跨机会被 Gatekeeper 拦（INSTALL.md:16-35）。只要机器都装着正式版，这不构成日常障碍；但要防止有人图快把 `.build` 里的 app 直拷过去，那等于绕开更新通道重演手动时代。
