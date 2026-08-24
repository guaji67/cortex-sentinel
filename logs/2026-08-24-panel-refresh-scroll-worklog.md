# 面板刷新滚动卡顿修复

- 时间：2026-08-24 19:12:06 +0800
- 仓库：`cortex-sentinel-public`
- 基线提交保持：`ac83b46`

## 卡顿主因

磁盘读取本身已经在 `StatusDiskReader.load` 的后台队列中；这次真正吃掉滚动帧的是 SwiftUI `body` 在主线程反复求值时触发的派生计算。`SentinelStore.lineGroups` 原先每次都把全部状态线重新 `map + sort`，`SentinelMenuView.boardWindow` 又基于分组重复做最近/历史切分和排序。面板 body 多处读取这些属性，滚动带来的 body 重算因此会重复执行全量工作。

面板打开的四类刷新还会分别发布状态。AIO 逐 provider 的 loading/结果发布已有测试契约，本轮不改成一次结果发布；这轮保留逐 provider 回显，把三类互不依赖的 I/O 并行等待，缩短刷新窗口，并让派生重活只在快照生成时执行一次。

## 改动

1. `SentinelStore` 新增 `@Published` 的 `lineGroups` / `boardWindow` 快照；`apply` 接受同一轮快照并更新缓存，避免菜单 body 再次计算。
2. `StatusDiskReader.load` 在后台读取阶段一次生成分组和看板窗口；`SentinelBoardWindow` 同时缓存已排序的 `recentUnregistered`，自动识别区不再二次排序。
3. `refreshStatuses` 增加 `diskRefreshInFlight` 防重入。上一轮磁盘/进程读取未完成时，定时器或面板打开触发的下一轮直接跳过，不排队堆叠。
4. `refreshOnPanelOpenIfNeeded` 保留 30 秒门槛，同时并行启动状态、AIO 余额和 Input 刷新；官方额度刷新仍按现有独立生命周期启动。`SentinelMenuView` 改为只读缓存，并复核其余计算属性：余额/路由/计数类属性是小规模展示映射，没有同等级的全量排序重活。
5. `StackedRefreshGateTests` 增加慢进程读取场景，验证重叠状态刷新只执行一轮。

## 验证

- `swift build`：通过。
- `swift test`：326 tests / 0 failures（基线 325，新增 1 个防重入测试）。
- `bash scripts/build-app.sh --bundle-version dev-refresh-scroll`：通过；产物仅写入仓库 `.build/CortexSentinelBar.app`，未安装到 `/Applications`。
- 真机 smoke：使用临时目录中的 80 条状态 fixture，从 `.build` 启动独立 smoke 实例；CoreGraphics 看到面板窗口为 406 x 646，离屏 `busy` 面板渲染正常，重复滚轮事件期间面板保持可重绘。临时把构建产物改为独立 bundle 标识以避开常驻实例后已重新构建恢复 `LSUIElement=true`；常驻哨兵 PID 68553 全程未触碰。

## 手感结论

- 改前：刷新发布触发 body 重算时，滚动会出现一顿一顿；根因对应的是每次 body 重算都重新做全量分组/排序。
- 改后：80 条线的独立 fixture 在刷新期间滚轮交互保持连续，未再观察到由分组/看板计算造成的停顿。transient smoke popover 被辅助窗口抢前台后会自动收起，因此本次没有把截图当作精确帧率测量。

## 剩余事项

尚未做 Instruments 级别的逐帧采样；AIO 逐 provider 的独立发布仍会使整个观察面板收到多次失效，这是既有余额逐行 loading 契约，当前每次 body 已不再承担全量 `map + sort`。若后续仍需更低的重绘量，可再把 AIO/服务区拆成独立观察子视图。
