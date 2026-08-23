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
