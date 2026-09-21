# 工作台验证记录

## 2026-09-21 开发验证

- Swift debug 原生构建通过；网页语法、打包脚本语法、diff whitespace 检查通过。
- 原生服务黑盒 10 项通过：100 个任意板块、全文扩展字段、幂等、版本冲突、权限、
  浏览配对与写权限分离、验收证据、父子成环、来源越界、请求大小/重复头。
- HTML 兼容导入 3 项通过：保留颜色语义与研究正文，不执行脚本，拒绝重复身份。
- 在有 Xcode 的验收机运行 Swift 新增 13 项，全部通过。
- Swift 全量 515 项中有 6 项失败；在未修改的 2c4d924 上单独运行对应两组 17 项，
  同样的 6 项失败、相同断言差值。不是全绿，没有修改/跳过原测试来伪造通过：
  - PanelBalanceRefreshTests.testIdleSixtySecondsWithoutOpeningPanelDoesNotFetchUsageOrPublish
  - StatusPublishDedupTests.testChannelStatusChangePublishesOnceAndKeepsNewValue
  - StatusPublishDedupTests.testLineRegistryChangePublishesOnceAndKeepsNewValue
  - StatusPublishDedupTests.testLinesChangePublishesOnceAndKeepsNewValue
  - StatusPublishDedupTests.testMultipleSourcesInOneRefreshPublishOnlyChangedCount
  - StatusPublishDedupTests.testUnchangedDiskEmitsZeroPublicationsAcrossRepeatedRefreshes
- 安装器登录项匹配测试通过。签名/公证/装机和局域网验收结果另追加，不以本页代替。

## 视觉与迁移

浏览器实际对照三份参考：原总工作台、Harness 图、自动化图。新页保留横向职责分组、
维护者颜色图例、点击详情；总览包含所有已有责任域，不以两条已开工板块代替全产品。
迁移副本中已有第三个板块，无须改网页代码即可出现。原稿正文、草稿与历史保留。
实际检查了地图→详情、全景、窄屏；窄屏宽度没有横向溢出，导航单独换行。

真实账本、HTML 原件、机器读数和截图属于本地数据，不纳入程序仓库。

## 最终安装态验收

- 同一份 0.1.50（应用来源 c0bedb8）完成 Developer ID 签名、App 与 DMG 公证、
  staple、spctl 和挂载内容校验，安装到两台机器，均由正式哨兵进程监听工作台端口。
- 保存共享账的节点返回 SentinelStore 同源读数；另一节点返回 joined，双方 node_id 一致。
- 限板块维护者从另一台机器真实写入原有维护笔记，主机回读修订推进、原正文未变。
- 停用旧独立发布器后，接收时间继续按三分钟推进，证明由哨兵托管的发布在运行。
- 原图转入哨兵数据目录，原件有备份、旧路径保留链接；维护 Skill 使用随包正本指针。
- 实际用户窗口 908 × 836：自动化 23 块均可见，最后一行下沿 778；切换 Harness 14 块正常。
- 补充旧 IPv4 HTTP → 哨兵迁移测试：未修版复现 Address already in use；修正版在约
  32 秒内自动等到端口释放。另测同栈快速重启和第二进程不能共享同一监听端口。
- 最终原生 HTTP 黑盒 **13 项通过**，导入 **3 项通过**；最终 Swift 全量 **515 项通过**。
  上述早期六项基线失败在最终全量运行中未再出现，未修改这些测试；保留早期记录，不将
  环境相关的时序差异解释成此次修好了那些原有逻辑。
- 机器遥测上游目前仍返回脚本错误，没有可用机器读数，网页显示未知，不虚构在线或负载。

本次提供本地已公证安装包，没有发布 GitHub Release 或推动全体用户自动升级。
