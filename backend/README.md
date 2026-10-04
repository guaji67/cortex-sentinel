Cortex 哨兵后端

盯三件事：派出去的线还活着吗、Grok / Codex 通道通不通、这台机器的内存和磁盘还撑不撑得住。

本目录是从 Cortex 仓抽出的零依赖后端，不依赖 Cortex 源码，也不写回 Cortex 仓。
菜单栏 App（Swift）是同一产品的前端，源码在仓库顶层。

家目录

状态不进被监护项目的仓库。默认写 `~/.cortex-sentinel/`：

    config.toml          被监护项目列表，没有也能空跑
    registry.json        线登记表
    status/              各线 *.status.json
    logs/                各线 stdout/stderr
    channel-status.json  通道判决

环境变量 `CORTEX_SENTINEL_HOME` 优先。

配置示例

    [[projects]]
    name = "cortex"
    root = "/path/to/cortex"
    data_root = "/path/to/cortex-data"
    dev_ports = [3000, "3401-3439"]

跑法

需要系统自带的 python3（3.9+），不要虚拟环境，不要 pip。

    cd /path/to/cortex-sentinel/backend
    /usr/bin/python3 -m cortex_sentinel doctor
    /usr/bin/python3 -m cortex_sentinel status
    /usr/bin/python3 -m cortex_sentinel watch list
    /usr/bin/python3 -m cortex_sentinel lines
    /usr/bin/python3 -m cortex_sentinel reap          # 默认只看不动
    /usr/bin/python3 -m cortex_sentinel dispatch grok --help

或者：

    ./bin/cortex-sentinel doctor

launchd 模板在 `launchd/*.plist.tmpl`，占位符是 `@INSTALL_ROOT@` `@PYTHON3@` `@SENTINEL_HOME@` `@HOME@`。
后端不负责挂 job。

派工占用与派工记录

每分钟记一行占用、每条新起的 run 记一行，留给派工复盘用（Falcon 10-04）。

    bash scripts/install_occupancy_log.sh install      # 装：每 60 秒一轮的 LaunchAgent，不是常驻
    bash scripts/install_occupancy_log.sh status
    bash scripts/install_occupancy_log.sh uninstall    # 只摘 job，记录不删

记录在 `~/Library/Application Support/CortexSentinel/occupancy/`（北京日期）：
`YYYY-MM-DD.jsonl` 每分钟一行（各号在跑/上限，看板 run、本机线、手开窗口、排队分开，各执行者在跑与看板帽，
三机内存压力）；`dispatch-YYYY-MM-DD.jsonl` 每条新 run 一行（票号、执行者、机器、号、模型、run 类型、
触发评论开头 40 字、当刻各号在跑数，按 run 号去重）。目录里有「不要删除.md」，至少留 30 天。

查询：

    sentinel-occupancy at "2026-10-04 00:05"      # 那一刻最近一行的各号占用
    sentinel-occupancy runs --since "00:00"       # 这段时间的派工行

落兜底档对账（Falcon 10-04：满了落小米是正常冗余，怕的是没满就选过去了）

Cortex 主线 #5888 起，派工器在没选 ZCode、落到小米或别的通道时，往各机主检出 `logs/dispatch-fallback.jsonl` 追加一行
（时刻、票号、选中谁、四个号各自的占用与帽、读数来源、判满理由）。每分钟 tick 把三台的行合起来（本机直接读，Pro / mini 用
`ssh` 只读 `tail` 对方的那份，Pro / mini 主检出在 `~/Documents/Code/cortex`，M1 Max 在 `~/Documents/code/cortex`），
每一行拿**同一分钟**占用记录里四个号的真在跑数（`plans[号].running`，预占不在里面）比：某个号帽 > 0 且真在跑 < 帽，
就判误选，记进 `occupancy/fallback-audit-YYYY-MM-DD.jsonl`（占用加预占已撑满的标 `reserve_only`，派工器当时记的别的拦因写在 `blockers`）。
同一分钟没有占用记录的行等 3 分钟，还没有就记「没法判」，不算误选。

    sentinel-occupancy fallback-audit [--day 今天] [--local] [--report-only] [--json]
    # 今天落兜底档几次、其中落小米几次、误选几次、误选的票号和当时哪个号有空；连不上的机器写「没读到」

装机：`install_occupancy_log.sh install` 现在多拷 `review.py`（三台 ssh 读口）和 `fallback_audit.py`。

数法不另写一套：号的在跑数读哨兵面板同一份（闸运行时 `glm_plan_status.py --json`），三机内存读
`sentry_telemetry.read_machines()`。面板口径不含手开窗口、监工占位和预占；这些来自三机上报的
`zcode_other`，单列在 `manual_windows` / `supervisor_windows`；派工器账本口径（号超上限哨兵同一读方，看板行不封顶、含手开/监工/预占）并排写在 `plans[*].ledger`，两边口径的差别各自写，不合并。

模型口碑（Falcon 10-04：每张活交回来，验收的窗口顺手写一句好 / 一般 / 差加感受，按模型攒起来；不是跑分，不从回执里自动判）

    bash scripts/install_review.sh install            # 装 sentinel-review 到 ~/.local/bin，没有常驻 job；每台机器各装一次
    sentinel-review add COR-12345 好|一般|差 "一句感受" [--run 前缀] [--by 窗口名] [--model 手填]
    sentinel-review summary [--days 7] [--local]      # 按模型一行：好 / 一般 / 差各几条、最近三句
    sentinel-review pending [--since 今天] [--local]  # 已完工、还没评价的票

`add` 先在本机派工记录里找这张票最近一条 run，没有再 `multica issue runs` 现查（含已归档的执行者），把模型、执行者、
机器、号、run 号带上；评价人缺省读环境里的窗口名（`CLAUDE_WINDOW_NAME` 等），再退到会话号前 8 位，都没有写 unknown。
记录各机写各机的 `~/Library/Application Support/CortexSentinel/reviews/reviews.jsonl`（只追加，目录里有「不要删除.md」）。
`add` 不带 `--run` 时取这张票最近一条真跑完的 run（完工状态、有实际用时）；没开跑就撤的、被取消的、失败的跳过，要评它们明写 `--run`。
误记或不该计口碑的（比如没起跑）用 `sentinel-review void COR-12153 --run 01a1009f --by 窗口名 "原因"` 作废：追加一行作废记录，summary 按同票同 run 取最新时遇到作废整条不算，旧行不删；之后再 `add` 又按最新算。
评价里的模型取值顺序：那条 run 的 usage 里实际用的（去掉 `[1m]` 这类后缀）→ 派工记录里这条 run 刚建出来时执行者的模型配置 → 执行者现配置（标「模型未核」，`model_verified=false`）。代码里不写任何模型名单或分组：summary、list 按数据里出现的模型串原样分组，新模型不改代码自动出新的一行；免费和付费 Spark 靠模型串本身不同分行。本机线（CLI 派工）读会话记录或日志里的实际模型这一支还没做（本机和 Pro 上没有可核对的状态文件样本），目前用 `--model` 手填。
`sentinel-review reverify-models [--apply] [--match 正则]` 是一次性重核：默认核全部评价，模型和 run 实际不符就追加一条更正（`--match` 可收窄到执行者名匹配某个正则的）（同票同 run 新行覆盖旧行，旧行留着，评价发生时刻存在 `orig_ts_bj`）；不带 `--apply` 只出计划。
评价人只写两样：好 / 一般 / 差加一句为什么，其余程序填：任务标题（`multica issue get` 现查，缓存在 `reviews/task-titles.json`）、执行者、run 实际用的模型、机器、号、run 起止时刻、评价人窗口名（环境里的窗口名，否则读 Claude Code 会话记录里的窗口标题，带 `@机器`）、评价者自己的模型（Claude Code 读 `~/.claude/projects/*/<会话号>.jsonl` 最后一条助手消息的 model，Codex 读 rollout 的 turn_context，环境变量 `CORTEX_REVIEWER_MODEL` 优先，读不到留空不报错）。`--task`（没有票号的活，票号写 `-`，同时要 `--model`）和 `--reviewer-model` 只当兜底。
`sentinel-review list [--model 小米|spark|glm] [--grade 差|一般|好] [--days 7]` 一行一条：时刻、票号、任务标题（40 字内）、评价档、为什么、评价人、评价者模型、模型、执行者、机器；`--model` 先查俗名表 `reviews/model-aliases.json`（可改，第一次用时从随代码带的 `cortex_sentinel/data/model-aliases.json` 拷过去，重装不覆盖；右边写正则，如 小米、spark、免费spark、付费spark、glm），查不到俗名就按模型串子串匹配，不报错。`sentinel-review backfill-tasks` 给已有评价补任务标题（只写旁表，评价原行不改）。
补评或翻案就再 `add` 一条：summary 里同一张票同一条 run 只算最新那条（含最近感受），旧行留在文件里不删。
`summary`、`pending` 默认三台合看：用 `ssh cortex-pro` / `cortex-mini` 只读 cat 对方的 reviews.jsonl 和 dispatch-*.jsonl
（不往对方写任何东西），连不上的机器在输出末尾写「没读到：xxx」；`--local` 只看本机。`pending` 另扫看板上所有执行者
（含已归档）最近 200 条 run，派工记录里没有的完工票也补进来；票上还有 run 在跑的算没交回，只报个数。
Pro、mini 上命令要装才有：拉最新哨兵仓后跑 `bash backend/scripts/install_review.sh install`。
