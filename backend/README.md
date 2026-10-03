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

数法不另写一套：号的在跑数读哨兵面板同一份（闸运行时 `glm_plan_status.py --json`），三机内存读
`sentry_telemetry.read_machines()`。面板口径不含手开窗口、监工占位和预占；这些来自三机上报的
`zcode_other`，单列在 `manual_windows` / `supervisor_windows`，两边口径的差别各自并排写，不合并。
