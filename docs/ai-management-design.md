# 哨兵管理 Skill 与 Hook

## Requirement Packet

### Source refs

2026-09-21 本任务第二阶段请求；第一阶段见 `workbench-design.md`。

### User requirements

- 由哨兵承载不同机器的 Skill、Hook 管理，借鉴 Cortex Skill Hub；不依赖日常 SSH 搬文件。
- 第一阶段维护板块图的规则也要随之安装；板块和机器分工不能写死。
- 规则为探索和交付服务，不统一研究提纲，不把活动量当成果。

### Non-negotiables

本地数据不进程序仓；不复制完整 settings、环境变量、凭据或插件目录。旧 Hook 不因托管而重启。不启动或停止用户的 AI 进程。签名 App 内资源不作为可写软链目标。

### Approaches considered

| 方案 | 更新与风险 | 回退 / 验证 |
|---|---|---|
| SSH / 文件夹双向复制 | 机器必须能 SSH；配置冲突和执行权限混在一起 | 副本不证明宿主加载；难判正本 |
| 全部打进哨兵 App | 签名更新可信，但个人规则每改一次要发 App | App 可回退，但把程序和用户数据绑在一起 |
| 哨兵内置版本管理 + 局域网订阅 | 程序随 App 更新；个人包留本地；来源公钥固定；目标按包订阅 | 保留版本、按哈希识别本地修改；安装与宿主调用分开 |

采用第三种。任何机器都可发布任意包，不预设角色；首次登记来源需要本机授权和对照公钥指纹。现有浏览配对码只能读，不提供远程安装权。

## 借鉴而非重复搭建

来自 Cortex `src/web/src/app/api/skills/_shared.ts`：Skill Hub 正本与客户端入口分开、按目标部署；`user-skills/skill-freeze.ts`：内容版本冻结；`invocation-receipt.ts`：安装与调用证据分开。沿用 `~/.cortex-skills/skills/<id>`，已有非本管理器资产不接管、不改写。哨兵拥有网络、定时任务、包签名、状态界面，不增加常驻进程。Cortex 主仓没有可用的 GitNexus MCP/CLI，本次只读借鉴，未修改其符号。

## Contract v1

- 来源由本机登记：包 ID、显示名、类型、根目录、明确文件清单。Skill 保留完整正文和相对资源，不重写 description；不扫描全盘。新版本由登记文件内容生成。
- 包限 1 MB / 128 文件；禁止路径穿越、软链文件、隐藏文件、凭据命名和特殊文件。仅传明示的包文件；Hook 需声明事件、入口及解释器，不接受安装脚本。
- 每个哨兵持有独立 Ed25519 发布身份；导出响应有签名。接收方保存首次确认的公钥，包摘要校验后落版本目录；不因网络上的公钥变化重新信任。
- 本机订阅决定目标和自动更新。已安装文件改变或同名外部资产存在即冲突，保留原文件。失败不冒充已同步；离线保留最后可用版本并标注旧读数。
- Skill Hub 链接及宿主链接只能改自己登记的入口；Hook 只增减自己精确登记的条目，保留其余 settings，永不改变 disableAllHooks。
- Hook 更新默认待本机确认；即使来源已配对，也不等于允许它执行新命令。Skill 自动更新也必须在订阅时选择。
- 每次变更先保存可恢复记录。回退到已保留版本，并暂停自动更新，避免下一轮又覆盖回去。
- 已安装不等于已调用；只能用宿主触发的回执报告调用证据，测试回执单独标注。不承诺更改一定热加载。

## Official contracts checked

- https://code.claude.com/docs/en/hooks — 分层 hooks；直接编辑通常由 watcher 发现，但配置可能被策略覆盖或 ConfigChange 拒绝。
- https://agentskills.io/specification — SKILL.md + 自由正文及相对资源，不规定业务提纲。

## Acceptance checks

隔离目录验证签名篡改、路径/软链、同名冲突、本地漂移、精确 Hook 合并、回退、断线、重启持久化；真实 App 页面和本机 / mini 的局域网订阅；不调用 Claude CLI，宿主调用未出现则明确待验证。

### Read receipt

已读板块治理 Skill、Skill 编写规范、Cortex 路由/开工契约/Hook 关闭记录及 Skill Hub 源码；installed-set healthcheck 和实际双机回执于验证阶段记录。
