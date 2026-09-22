# 第二阶段交付与验收

2026-09-22 UTC。范围是哨兵内置的规则管理链路，未声称所有电脑或所有第三方插件已经统一。

## 已交付

- App 0.1.51，build `2026092205`；安装包源码 `e1d591133757a388b25a1e4ac4b99046b5ecb7f1`。
- 本机与另一台实际局域网机器均完成签名 App 安装，来源身份、订阅和旧看板跨重启保留。开发中的验证服务不作为正式工作台交付。
- 第一阶段板块维护 Skill 在两台机器的 Claude / Codex 入口接入 Skill Hub，旧入口有备份；管理角色手册以原来来源机器的目录为正本，5 个文件经签名 LAN 接口订阅到本机，逐文件摘要一致，原文未修改。
- 每 180 秒随哨兵刷新。首次核对身份使用既有可信通道，日常读取与更新不经 SSH；人工同步后又观察到定时刷新时间自行前进。
- Hook 支持预览、逐版本确认、精确注册、停用和回退。真实机器没有新开 Hook，没有恢复旧闸；两台用户级 settings 文件与安装前逐字节一致。
- 原工作台仍保留自动化 23 块、Harness 14 块及另一个已登记板块；模块名单与机器分工未写死。

## 自动检查

| 范围 | 实际结果 |
|---|---|
| 完整原生 Swift 测试（完整 Xcode 环境） | 517 通过，0 失败 |
| 工作台 / 规则管理 / 原图适配集成 | 30 通过，0 失败；对最终签名 App 的同一套测试也通过 |
| Skill 格式 | quick_validate 通过 |
| 前端与安装脚本 | JS 语法、Shell 语法、git diff --check 通过 |
| 既有 Cortex installed-set Hook 检查 | schema / 预算 / 已装条目检查通过；严格 GateRuntime 与主线尖对齐项当时提示主线又前进，不能写成全部通过 |

集成包含双节点真实 HTTP、签名篡改、路径/软链拒绝、预览版本竞态、同名外部资产、本机改动、回退暂停、精确 Hook 合并/停用、断线旧版保留、损坏规则库不拖垮原看板、以及 CLI helper 不占 GUI 单实例。

```sh
swift test
PYTHONPATH=backend/tests python3 -m unittest test_managed_ai.ManagedAI test_workbench_native.NativeWorkbench test_workbench_import -v
SENTINEL_TEST_BINARY="$PWD/.build/CortexSentinelBar.app/Contents/MacOS/CortexSentinelBar" PYTHONPATH=backend/tests python3 -m unittest test_managed_ai.ManagedAI test_workbench_native.NativeWorkbench test_workbench_import -v
bash -n scripts/install-app.sh
node --check Resources/Workbench/ai-management.js
```

## 实机问题与闭环

最终安装时复现：同时跑签名程序的隔离验证 CLI，旧单实例判据把它当成 GUI 哨兵，GUI 正常退出而安装器仍报成功。修复不是延长等待：单实例判断排除有明确入口的 headless helper；真实 GUI 重复实例仍拦。补了两个原生测试和一个真实进程测试。

安装器增加“新 PID 的 ready 回执 + 本机 HTTP 真响应”门槛，失败回退并重新拉起旧版。修复后的本机安装与隔离原生服务并行时仍成功启动正式 8935，服务 PID 与就绪回执一致；两台安装日志均出现实际工作台响应验证。

浏览器真实验收：同版多来源合并成三行、两台机器对照；已有原目录显示“已有入口 · 未接管”；同版已安装与未知调用分开；机器列等宽，详情才展开正文。配对 / 安装权限只留在目标本机。

## 包与边界

`Cortex哨兵-0.1.51.dmg` 已完成 Developer ID 签名、Apple 公证、staple、spctl / DMG 验证。两台机器下载目录内文件摘要一致：

`a52e0d6e1e8785dc7a7e1ff16fdce609440b50d32c417406e83d47c10e5e13e0`

没有发布 GitHub Release；其他电脑仍需装这个版本并明确连接来源。个人规则、原始配置、身份密钥、真实日志与截图不入仓。未启动或重启用户的 Claude Code；独立 Hook 冒烟回执不冒充宿主实际调用。工程闸继续复用既有 GateRuntime，其刷新与主线存在时差，不承诺实时零落后。
