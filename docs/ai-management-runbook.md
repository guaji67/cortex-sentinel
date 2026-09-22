# Skill / Hook 管理

## 人的入口

启动哨兵 → 打开开发工作台 → **AI 规则**。表格是一份规则对应多台机器；点击才展开正文、文件、版本与安装选择。

任意机器可作为某一份规则的正本，不设主控机角色。登记根目录与明确文件清单，不移动原稿。其余机器连接该来源：地址、浏览配对码、公钥；公钥应在那台机器的页面核对，不能把网络自己报的公钥当核对。

安装 Skill 时选择已有 AI 工具，并决定是否订阅后续版本。Hook 每个新版本都要预览后在目标机器本机确认，默认不会安装。查看码只能读，不能从远端替另一台机器安装。普通用户级 Hook、项目配置和插件配置不自动接管，旧关闭项不恢复。

停用只移除哨兵拥有的入口，不删除正本和保留版本；回退会暂停自动更新。出现「本机差异」时先对照正本与安装副本，不能强制覆盖或从界面把差异消掉。

## AI 的入口

随 App 携带可选 CLI（需 Python 3）；运行服务本身不需要 Python：

```sh
python3 '/Applications/Cortex哨兵.app/Contents/Resources/Workbench/client/ai-rules.py' status
python3 '/Applications/Cortex哨兵.app/Contents/Resources/Workbench/client/ai-rules.py' source --file /绝对路径/manifest.json
python3 '/Applications/Cortex哨兵.app/Contents/Resources/Workbench/client/ai-rules.py' preview management-roles --source team-node
```

也可直接请求本机 `/api/ai/*`；变更需 `X-Sentinel-Local: 1` 和同源，JSON UTF-8。`preview` 返回精确 digest；`install` 必带它，防止确认后来源偷偷变版。

Skill 来源示例（合成）:

```json
{"id":"example-rules","title":"工作规则","kind":"skill","root":"/absolute/source/example-rules","files":["SKILL.md","references/roles.md"]}
```

Hook 来源示例（只适用自包含脚本，不猜测外部依赖）:

```json
{"id":"example-hook","title":"会话提示","kind":"hook","root":"/absolute/source/example-hook","files":["entry.sh"],"hook":{"event":"SessionStart","matcher":"","entry":"entry.sh","interpreter":"/bin/sh"}}
```

依赖仓库的现有闸继续归 GateRuntime 管，不复制成脱离运行时的单文件。插件由原插件安装器负责，哨兵不修改其内部文件。个人规则只存在来源机器数据目录，不随公开仓库发布。

## 运行与回执

- 每 180 秒随哨兵现有生命周期刷新，不新增守护进程。离线不写成功状态，已装版本仍可读。
- 数据：`~/.cortex-sentinel/workbench/ai/`。`identity.json` / `state.json` 含身份或配对资料，0600，禁止提交或整份贴出。
- Skill Hub：`~/.cortex-skills/skills/<id>` → 保留版本；AI 宿主入口 → Hub。既有非哨兵资产让路，不以同名判归属。
- 第一阶段的精确原始入口可保留备份后迁入；有任何本机修改则不迁移。App 内资源不是可写链接目标。
- 安装回执、源内容版本、Hook 执行回执是三类事实。独立测试使用 `--test` 标记，不记作 Claude Code 实际触发。脚本输入、对话、会话标识、路径上下文不进入调用回执。
- 不启动或重启用户的 AI 窗口。新窗口是否发现 Skill、某个 Hook 是否被宿主实际调用，没证据就保持未知。
- 已关闭的 Hook 不因为目录存在而重开；用户级 `disableAllHooks` 不改。项目/策略/插件层可能影响最终生效，页面不能冒充全部有效配置。

## 安装另一台机器

安装同一版签名哨兵 App，打开工作台；在「连接与接入」选择已有看板；在「AI 规则」确认所需规则来源并选包。看板连接和执行规则信任分开，不拿看板授权自动授予代码执行权。一次性 SSH 可用于已有机器部署和核对身份；日常刷新不使用 SSH。

## 验证

`python3 -m unittest discover -s backend/tests -p 'test_managed_ai.py' -v` 使用真实 Swift 服务、隔离用户目录、合成数据。`swift test` 需完整 Xcode。真实机验收另记 `ai-management-verification.md`。
