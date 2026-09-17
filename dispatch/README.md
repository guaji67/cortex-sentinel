# dispatch/ — 派工花名册公开镜像

这个目录是 Cortex 派工执行者花名册的公开镜像，给没有 GitHub 凭据的机器匿名拉取用。

- 正本在私有仓 guaji67/cortex 的 `docs/reference/executor-availability.yaml`，别在这里直接改，改了也会被下一次同步盖掉。
- 同步只有一个出口：私有仓的 `bash scripts/sync_dispatch_public.sh <本仓检出路径>`，正本 PR 合入后由主控跑。
- 消费方：闸运行时刷新脚本 `refresh_gate_runtime.sh` 在私有仓 fetch 失败（机器没配凭据）时，匿名克隆本仓把 `executor-availability.yaml` 装进运行时根的 `dispatch-override/` 兜底；私有仓 fetch 成功的机器自动删兜底，永远读正本。
- 换镜像拉取地址：环境变量 `CORTEX_DISPATCH_PUBLIC_REPO`（默认本仓）。

文件里只有执行者名字、模型、可用状态和 Falcon 的原话理由，没有任何密钥或凭据。
