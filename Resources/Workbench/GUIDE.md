# AI 维护协议 v1

这是 Cortex 哨兵内置工作台。协议与网页随同一份 App 更新，持久资料在
~/.cortex-sentinel/workbench，不在 App 包体里。页面不是研究提纲。

## 最小身份

用 track 登记一个板块，area 表示其中任意层级，parent 可链接父块，group 可自由分组。
note 放自由正文，relation 记录影响关系，problem 才是独立追踪的问题。
id 稳定，title 可改。自定义字段原样保存、可回读，不认识的字段也不会被前端删除。
title 是地图短标题，body 可以长；status_label / color 是维护者的展示判断，绝不自动计为验收。
新板块登记后目录、地图、搜索、关系立即可用，不用新增导航标签或修改网页代码。
track.domains 可链接已有产品责任域；没准备好就留空，不要求先拆完全部产品。

## 读取与修改

先读 ~/.config/cortex-board/location.json 给出的 client 与 profile 路径，不打印密钥。
client.py --profile PROFILE overview
client.py --profile PROFILE read ID
client.py --profile PROFILE update --file EVENT.json

事件包含 event_id、id、kind、base_revision、patch。创建时 revision=0；修改前回读。
409 重读合并；同一请求超时可重发相同 event_id，禁止换新 event_id 盲目重试。
403 表示没有该板块权限，不能借别的板块身份绕过。局域网只读配对码不是维护授权。
新板块用本机管理员登记/发放 scoped profile；不用 SSH 作为日常传输方式。
新机器安装哨兵后在连接页连向已有共享账，不能默默初始化另一份共享账。

## 接缝与验收

relation 的 from 属于本板块，to 可指其他实体或尚未登记的外部引用。
certainty=proposed 表示待核，confirmed 要给 references。
同一缺陷只有一个 problem id，用关系关联多个板块，避免重复计数。
classification 区分 source_only / confirmed_bug / improvement。
state 区分 recorded / repairing / merged / delivered / verified / dismissed / source_closed。
verified 需要 evidence：machine、version、action、expected、actual、checked_at（ISO 时间）、reference。
代码合入、关票、来源图变绿都不代表用户验证。回归后重新验收需要新的证据。
CPU、签到、提交量不作成果分数。没有数据明确说未知。

## 原图与同步

保留既有 HTML 的维护方式时，用 publish-html --track ID --file FILE。
适配器只解析字面对象，不执行原稿脚本；保留分组、颜色图例、完整研究正文。
来源图说明与验收账独立，来源更新不会抹掉维护者的显式修订。
App config.local_sources 可登记任意板块的原图路径与 scoped profile，哨兵每三分钟发布。
该兼容适配器需要 Python 3；原生工作台/JSON 读写/其他机器浏览均不需要 Python。
维护原图应使用 location.json 的实际路径，Downloads 可能只是兼容链接。

## 运行与范围

GET /api/overview、/api/entities/ID、/api/history、/api/guide 均需本机或签名/浏览配对。
POST /api/update、/api/source 使用 X-Board-Client / X-Board-Time / X-Board-Signature。
签名为 HMAC-SHA256(secret, timestamp + newline + path + newline + body)，允许五分钟时差。
协议版本不一致不静默连接；来源断开保留旧快照。不会改 Multica 票、派工或同步 Hook。
网络限可信局域网；外网走已有安全隧道，不公开映射这个 HTTP 端口。
