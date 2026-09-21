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
