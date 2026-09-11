# 哨兵运维与踩坑记录

一次踩坑升级成一条长期规则。改运维流程前先读这页。

## 进程与重启

- 进程名是 `CortexSentinelBar`，不是中文名。`killall Cortex哨兵` 静默失败（stderr 一行 No matching processes，退出码 1），应用根本没重启，后面全白等。2026-09-11 实踩两次。
- 正确重启：`killall CortexSentinelBar`，launchd job `com.cortex.sentinelbar`（KeepAlive）几秒内拉起。
- 找进程：`ps aux | grep "Cortex哨兵.app/Contents/MacOS"`。
- 版本看 `/Applications/Cortex哨兵.app/Contents/Info.plist` 的 `CFBundleShortVersionString`。

## 自更新

- 检查节奏：启动查一次 + 每小时一次（`SentinelUpdateConstants.checkInterval` 3600）。`lastUpdateCheckAt` 在发起 fetch 前就写入，所以失败的检查同样锁一小时。网络抖动时更新最多晚到一小时，面板无提示。已知短板，待改：失败和成功分开节流，失败短间隔重试。
- 自动装开关：defaults 域 `com.cortex.sentinelbar`，键 `com.falcon.cortex.sentinelbar.updateAutoInstall`（bool，默认关）。
- 安装走一次性 LaunchAgent（`com.cortex.sentinelbar.update`）：写 plist → bash 跑 install-app.sh → 自删 plist → bootout 自己。不能从哨兵进程里直接跑安装脚本，bootout 会杀整个进程组，脚本会被连带打死（0.1.10 及之前的老坑，已修）。
- App Management TCC 弹窗只在换签名时出现一次，同签名后续更新全自动无弹窗。
- 发新版后的交叉验证流程：
  1. `defaults write com.cortex.sentinelbar com.falcon.cortex.sentinelbar.updateAutoInstall -bool true`
  2. `killall CortexSentinelBar`
  3. 轮询 Info.plist 版本号直到变成新版（一般 40 秒内）
  4. 验 commit：`plutil -extract commit raw -o - /Applications/Cortex哨兵.app/Contents/Resources/installer-manifest.json`，对上刚推的 HEAD
  5. 开关写回 `-bool false`
  6. 检查善后：一次性 plist 应自删；`hdiutil info` 里不该有 /tmp/cortex-sentinel-mount.* 残留
- `/Volumes/Cortex 安装盘`、`/Volumes/Cortex 安装盘 1` 两个挂载卷是手动安装 DMG 时代的遗留，不是自更新泄漏。没在用可以 detach（DMG 文件还在），拿不准就先问。

## 公证（Error 68）

- stapler 阶段打 `api.apple-cloudkit.com` 走 VPN（utun1024）会 TLS 抽风：`The validate action failed! Error 68`。纯网络抖动，重试就好，别改公证配置。
- `build-release.sh` 可能在最后一步（挂载卷上重复的 stapler validate）死掉，此时公证、staple、spctl 终验其实全过了。手动补完即可：
  1. 挂载 DMG 到临时目录，`spctl -a -vv` + `xcrun stapler validate` 重试三次
  2. 核对 installer-manifest.json 的 commit 和 Info.plist 版本
  3. `dist/` 里补 `.sha256` 和 `Cortex哨兵-<版本>.manifest.json`（照 build-release.sh 尾段的模板，build 号是 `TZ=Asia/Shanghai date +%Y%m%d`）
  4. 再走 `scripts/publish-release.sh <版本> <notes文件>`
- `gh release create` 也偶发 fake-IP 198.18.x 超时，重试即可。

## defaults 域

- 生产（打包 app）读写 `com.cortex.sentinelbar` 域。
- 未打包的 debug 二进制读写 `CortexSentinelBar` 域（无 bundle id 落的另一个 plist）。两边键同名但域不同，debug 里改设置不会影响生产，反之亦然。调 defaults 先确认在调哪个域。
- 改 plist 文件会被 cfprefsd 旧值盖掉，写键一律走 `defaults write` / `defaults import`，别直接编辑 plist。

## 离屏验收出图

改面板先出图，不要抠屏幕截图：

```bash
# 真实环境真数据（等 8-10 秒让链路回来）
./.build/debug/CortexSentinelBar --render-live-panel-png /tmp/panel.png --settle-seconds 8
# 验悬停详情卡布局（卡片常显，不用真鼠标）
./.build/debug/CortexSentinelBar --render-live-panel-png /tmp/hover.png --settle-seconds 8 --preview-hover-card
# 中性假数据（README 用图）
./.build/debug/CortexSentinelBar --render-panel-png /tmp/demo.png --panel-fixture <名字> --demo-balances
```

- 出图 CLI 不受单例守卫影响，生产在跑也能出。
- 普通起第二实例会被单例守卫挡掉：打印 Cortex 哨兵已经在运行了然后退出。想真机交互验证只能重启生产。

## 悬停详情卡

- 弹层（NSPopover 内容）里系统 tooltip 经常不出，且样式没法设计。余额区一律用自绘 `HoverDetailCard`（悬停 0.5 秒 Task.sleep 后 overlay，zIndex 99 压相邻行）。
- 出图验收靠环境开关 `\.hoverCardPreview`（`--preview-hover-card` 传入），别用真鼠标。
- 行内和横条上不要再加 `.help`，会和详情卡双弹。NSInitialToolTipDelay=500 只管留下的那些（Cursor/官方/AIO/页脚）。
- `quotaSegmentWithBar` 的 barHelp 参数已删，加列时别加回来。

## 释放节奏

- 版本三连：commit（feat:/fix:/docs: 前缀）推送 → `RELEASE_VERSION=x.y.z bash scripts/build-release.sh` → `bash scripts/publish-release.sh x.y.z dist/Cortex哨兵-x.y.z.notes.md`。
- Release 资产必须 ASCII 名（`Cortex.-x.y.z.dmg`），publish 脚本负责改名，中文名 dmg 直接传会坏自动更新。
- `releases/latest` 只认正式版，draft/prerelease 不算，发完即成为更新源。

## 余额口径

- 数字报剩余（电量），横条报已流逝（时间轴正向：绿 → 黄 → 红）。0.1.15 把 GLM 百分比双重反转成已用口径、横条做成剩余方向越走越短，Falcon 点名：这种问题不要再犯。
- GLM API 给 percentUsed，模型 `remainingPercentage` 已算好剩余；显示层再动它就是事故。

## 改代码脚本

- 用 python 批量改源码时，每处替换必须断言锚点存在且唯一（`old in s` 且 `count == 1`），写入放最后。切片起止界写反会切出空串，replace 空串会把文件撑爆几百万行（2026-09-11 实踩，靠 git checkout 救回）。
- 一次改多个文件时别把 A 文件的锚点拿到 B 文件上 replace，断言能挡住但白跑一趟。

## 自更新与盘面版本断层（2026-09-11 实踩）

- 0.1.28 起安装盘只带 app + Applications，交接脚本改为内联换装。但旧版（≤0.1.27）的交接脚本要从 DMG 里跑 scripts/install-app.sh——它下载到新盘后必然报 No such file or directory，每小时重试永远失败。
- 跨这个断层只能手动换装：bootout 主任务 → rm 旧 app → ditto dist 的新 app → bootstrap 主任务。装上 0.1.28 后自更新回归自洽。
- 以后再改 DMG 盘面或交接脚本，先想一遍「旧版更新器拿到新盘会发生什么」。
