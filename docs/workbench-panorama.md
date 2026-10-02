# Cortex 开发全景图

全景是哨兵工作台现有 `#overview`，继续读 `/api/overview`。不新增服务、守护进程或另一份名册。

- 每个责任域来自快照的 `domains`，票归属只读当前 `域:*` 标签。新域标签自动出现；没有主域或多个主域的票进入未归类，不沿用旧建议。
- 板块、窗口与家族继续登记为账本中的 `kind=track`。负责人、短状态、阻塞只取登记字段；没有就明确未登记，不从票面执行者猜主责。既有 `domains` 是关联范围，家族取票用 `ticket_labels`。
- 所有统计按本次快照重算，只显示百分比。进行中只指票面状态；不等同于真实 run。家族可跨域，其占比不与责任域相加。
- 最近合入只读 GitHub 最近一批已合到 `main`、含合并 SHA 的 PR，以票号关联标签；不会把 `done` 当成已合或用户已验。限定近 7 天、最近 100 条，只是有界记录，不保证覆盖全部历史。
- 票单每次只读活状态，最多 40 页、每页 100、总调用 64、整轮 180 秒。旧票消失每轮最多复核 12 张，其余标待复核且不冒充合入。失败保留完整快照；合入记录失败不抹掉票单。
- 来源约每 6 分钟随哨兵现有定时器检查；浏览器每 30 秒重读快照。刷新按钮仍走原 `/api/refresh`。

## 唯一登记入口

先从 `~/.config/cortex-board/location.json` 取 client 和 profile 路径，只把 profile 交给客户端，不回显内容。

```sh
python3 <client> --profile <profile> register-track <稳定ID> \
  --title <板块名> --owner <当前明确负责人> \
  --domain <责任域编号> --family <家族名> \
  --summary <现在在做什么> --blocker <卡在哪>
```

只需域关联可不带 `--family`；家族选择按标签匹配。客户端先读修订再写事件、写后回读；冲突或无授权直接报告，不借别人的身份。

测试完撤下自己的板块：同一命令加 `--archive`。历史仍在，可再次登记恢复。正常维护仍可用既有 `update` 事件；没有第二份登记文件。

## 定向验证

```sh
node --test backend/tests/panorama.test.cjs
python3 -m unittest discover -s backend/tests -p test_workbench_multica_bounded.py -v
python3 -m unittest discover -s backend/tests -p test_workbench_native.py -v
```

实机验收另放本机数据目录：从安装后的哨兵打开全景，记录三个域与独立 CLI 查询的计数一致率；登记测试板块、确认自动出现、撤下；取现成无标签票确认在未归类。截图不提交。
