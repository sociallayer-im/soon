# Sola ActivityPub 协议兼容性与互操作性验证方案

> 配套文档：架构与实施计划见 `FEDERATION_PLAN.md`。本文档只回答一个问题：
> **如何证明 sola 的联邦实现是对的**——对协议对（AP/AS2/WebFinger/HTTP
> Signatures），对系统对（Mobilizon、Mastodon、sola↔sola）。
>
> 状态：待确认。验证基础设施随实施分期建设（见 §7 与 FEDERATION_PLAN 分期的对应关系）。

---

## 1. 验证模型：五层金字塔

每一层建立在下一层之上；下层不绿，上层的失败无法定位。

```
L4  生产灰度        真实公网实例、真实用户、一周观察期
L3  端到端场景      docker 三方实验室：完整用户故事（关注→发布→报名→评论）
L2  领域语义        Join/Accept/Event 词表——以 Mobilizon converter 为语义预言机
L1  活动交换        inbox/outbox、签名、投递、重试——以 Mastodon 校验代码为协议预言机
L0  发现原语        webfinger / actor / nodeinfo / content-type——curl 可验证
```

**预言机（oracle）原则**：不自己解释 RFC/规范原文，而是以两个参考实现的
**校验代码**为判定标准——sola 的输出必须能通过：

- Mastodon 的入站校验路径（`mastodon/app/lib/signed_request.rb`、
  `app/lib/webfinger.rb:9,38-47`、`app/helpers/json_ld_helper.rb:228,327-337`、
  `app/services/activitypub/process_account_service.rb:147-173`）；
- Mobilizon 的入站转换路径（`mobilizon/lib/federation/activity_stream/converter/*.ex`、
  `lib/web/plugs/http_signatures.ex`、`lib/federation/activity_pub/transmogrifier.ex`）。

理由：公网上真正需要互通的就是这两套代码；规范（尤其 draft-cavage）本身
存在歧义，实现即事实标准。

---

## 2. L0 — 发现原语兼容性（curl 级，可脚本化）

工具：`curl --noproxy "*"`（本机代理陷阱，见 CLAUDE.md）+ `jq`。每条都写成
可重复执行的断言脚本，进 CI（对 staging 域跑）。

### 2.1 WebFinger

| # | 检查 | 断言 | 预言机依据 |
|---|---|---|---|
| WF-1 | `GET /.well-known/webfinger?resource=acct:<group>@app.sola.day` | 200，`Content-Type: application/jrd+json` | Mastodon 请求 `Accept: application/jrd+json` |
| WF-2 | `subject` | 精确等于 `acct:<name>@app.sola.day`（小写） | `resolve_account_service.rb:84-105` 回环比对 |
| WF-3 | `links[rel=self].type` | **精确字符串** `application/activity+json`（或带 profile 的 ld+json，二选一，不得有其他变体） | `webfinger.rb:9` 字面匹配 |
| WF-4 | `links[rel=self].href` | 与 actor 文档 `id` 逐字节相同 | 回环要求 |
| WF-5 | 未知用户 | 404（不是 200 空体） | `webfinger.rb:60-63` |
| WF-6 | 缺 resource 参数 | 400 | 通例 |
| WF-7 | resource 带 https URL 形式（`resource=https://…/users/x`） | 也能解析（Mobilizon 的 webfinger 兼容此形式） | `web_finger.ex:59-76` |
| WF-8 | `links` 含 `http://ostatus.org/schema/1.0/subscribe` 模板 | 存在且模板含 `{uri}` | Mastodon 远程关注按钮依赖；nebula 缺了这个 |
| WF-9 | host-meta | `GET /.well-known/host-meta` 返回 XRD，`Link[rel=lrdd]` 模板正确 | `webfinger.rb:75-105` 404 回退路径 |

### 2.2 Actor 文档

| # | 检查 | 断言 |
|---|---|---|
| AC-1 | `curl -H 'Accept: application/activity+json' https://app.sola.day/users/<h>` | 200，响应 `Content-Type` ∈ {`application/activity+json`, `application/ld+json; profile="https://www.w3.org/ns/activitystreams"`}（`json_ld_helper.rb:327-337`） |
| AC-2 | 文档 `id` == 请求 URI（跳转后最终 URI） | `json_ld_helper.rb:228` |
| AC-3 | `@context` 含 `https://www.w3.org/ns/activitystreams` | `json_ld_helper.rb:87-89` |
| AC-4 | `type` ∈ {Person, Group, Application}；`preferredUsername` 与 `inbox` 非空 | `fetch_remote_actor_service.rb:9,34`、`process_account_service.rb:24` |
| AC-5 | `publicKey.id` = `<actor id>#main-key`，`owner` == actor id，`publicKeyPem` 可被 `OpenSSL::PKey::RSA.new` 解析 | `process_account_service.rb:375-402` |
| AC-6 | `endpoints.sharedInbox` 存在且为**真正的共享 inbox**（`https://app.sola.day/inbox`），不是 per-actor inbox | nebula 的错误（`actors_controller.rb:38-40`）作为反例回归 |
| AC-7 | 同 URL 浏览器 Accept → 返回 HTML（Next 协商不串线）；AP Accept → JSON | rewrites 双栈检查 |
| AC-8 | followers/outbox/following URL 可解引用，为合法 `OrderedCollection`，大集合有 `first`/`OrderedCollectionPage` 分页 | nebula 无分页作为反例 |
| AC-9 | 无 handle 用户的 `/users/<tsid>` | 404 或明确不可联邦（不得泄露半成品 actor） |

### 2.3 NodeInfo

- NI-1：`/.well-known/nodeinfo` → links 指向 `/nodeinfo/2.0`；
- NI-2：`/nodeinfo/2.0` schema 2.0 合法（`software.name: "sola"`、`protocols: ["activitypub"]`、usage 统计）；
- NI-3：被 Mobilizon 的实例探测识别（它先查 NodeInfo 再猜 relay actor，
  `refresh_instances.ex:70-106`）。

---

## 3. L1 — 活动交换与 HTTP 签名（单测 + harness 级）

### 3.1 签名负例矩阵（单元测试，双向）

**出站（sola 签名必须被两个预言机验过）**——签名串逐字节断言：

| # | 断言 | 反例来源 |
|---|---|---|
| SG-1 | POST 签 `(request-target) host date digest`，GET 签 `(request-target) host date` | Mastodon `signed_request.rb:54-59` 强度要求 |
| SG-2 | `host` **不含默认端口**（443/80） | nebula 事故（`service.rb:85`）回归 |
| SG-3 | `(request-target)` 动词小写、路径含 query | `signed_request.rb:108-119` |
| SG-4 | `Digest: SHA-256=<b64>`，解码 32 字节 | `signed_request.rb:61-80` |
| SG-5 | `Date` 为 RFC 1123 GMT 格式 | Mobilizon 的格式串 |
| SG-6 | keyId = `<actor>#main-key`，`algorithm="rsa-sha256"` | 双方共同要求 |
| SG-7 | Mobilizon 侧兼容：签名头集合被其 plug 接受（它还签 `content-length`，但**验证端不要求**——断言我们不签它也能过） | `lib/web/plugs/http_signatures.ex` |

**入站（sola 验签必须拒绝所有坏输入）**——每条都是一个 401/400 断言：

无 Signature 头；签名与 body 不符（篡改 body → Digest 校验失败）；Digest 头对但签名没覆盖 digest（POST）；`Date` 偏移 > ±1h（时间窗按 Mastodon 的 `CLOCK_SKEW_MARGIN` 对齐）；keyId 指向不存在/不可达 actor；keyId 的 actor 与 payload `actor` 字段不一致（**以签名身份为准**，payload 不可信）；算法为 `rsa-sha1` 等不支持值；重复送达同一活动 id（第二次幂等 202，无副作用）；>1MB payload → 413；hs2019 标注 → 按 rsa-sha256 尝试（Mastodon 语义）。

**每一条负例都要有对应的正例对照**（同一请求修正后通过），防止验签实现"全拒绝"假绿。

### 3.2 进程内 S2S harness（集成测试，随 P2 建设）

移植 nebula `test_federation_s2s.rb` 的架构（测试内起 Puma mock 远端 + 线程安全
投递记录仓），三处强化：

1. **mock 端对 sola 发出的每个请求做完整验签**（按 §3.1 出站规则，用 mock actor 公钥）——nebula 的 mock 不验签导致 host:port bug 逃逸到"生产"，这是本方案最重要的一条改进；
2. mock 提供**故障注入**：按脚本返回 400/401/408/429/500/超时/断连，断言 `fed_deliveries` 状态机（401/408/429/5xx → 退避重试；其余 4xx → `failed_permanent`；成功 → `delivered`）与 Mastodon 的 `response_error_unsalvageable?` 语义一致；
3. mock 可同时扮演 **Mastodon 人格**（回 minimal actor + 严格 content-type）和 **Mobilizon 人格**（回带 mz: 词表的 Group actor + Event fixture），用真实 fixture 做应答体。

覆盖场景：Follow→Accept 往返（Accept 的 object 回显对方 Follow 原始 id）；Undo(Follow)（内联与裸 URI 两种形式都处理）；Create(Event) 扇出（多 follower 同域 → 只投 shared inbox 一次）；Join→Accept（内联 Join 原文 + id 形如 `/accept/join/<id>`）；Join→Reject；Leave；重试→补投→permanent 全链路。

### 3.3 契约夹具（fixture as contract）

直接把参考仓库的真实 JSON 作为入站单测输入，落库结果逐字段断言：

| 夹具 | 来源 | 验证点 |
|---|---|---|
| `mobilizon-post-activity.json` | mobilizon/test/fixtures | Create(Event) 全字段入库：Place/PostalAddress、uuid、Mention |
| `mobilizon-join-activity.json` | 同上 | 入站 Join → participant 建立 |
| `mobilizon-invite-activity.json` | 同上 | （P5）Invite 语义 |
| `mobilizon-members-collection.json` | 同上 | （P5）成员集合分页解析 |
| `gancio-event-activity.json` | 同上 | **地点缺 type/address 的宽容解析**（Mobilizon 已知兼容性坑） |
| `mastodon-follow-activity.json` 等 | mobilizon/test/fixtures 的 mastodon-* 系列 | Mastodon 形状的 Follow/Undo/Accept/Delete/Like |
| Mastodon 出站 Note（自采） | 实验室抓包 | Note inReplyTo event → 评论入库 + sanitize |
| sola 自身出站样本 | 序列化器快照测试 | 与 `FEDERATION_PLAN.md` §2.4 形状逐键 diff（对齐 mobilizon `events_test.exs:29-61` 的断言风格） |

夹具目录：`soon/test/fixtures/federation/`，来源注明 upstream 路径与 commit，
升级参考仓库时 diff 夹具即知协议漂移。

---

## 4. L2 — 领域语义对齐验证（Mobilizon 平齐性）

逐条验证 FEDERATION_PLAN §2.4 的平齐规则确实平齐——方法是**双向转换回环**：

1. **出站回环**：sola Event → 序列化 → 喂给（实验室里的）Mobilizon → 用其 GraphQL API 读回 → 断言 title/start/end/timezone/location/joinMode/capacity/participantCount/status 全部等值。时区重点：Mobilizon 会**用地理坐标覆盖声明的 timezone**（`event.ex:222-241`），所以带坐标的活动必须坐标与时区一致，否则对方显示会漂移——这是一条容易漏的语义断言。
2. **入站回环**：Mobilizon 创建活动 → sola 收 Create → sola 库中字段 → 与 Mobilizon GraphQL 读出的原值比对。特别覆盖：`endTime` 的 23:59:59 启发式双向不失真；`commentsEnabled`/`repliesModerationOption` 的优先级（后者赢）；visibility 二值化（非 Public → unlisted）。
3. **状态机对齐**：published↔CONFIRMED、cancelled↔CANCELLED 的 Update 双向；draft 永不出站（对方永远见不到 draft=true 的对象）。
4. **报名语义表**（每格一个实验室用例）：

| sola 活动配置 | 出站 joinMode | Mobilizon 用户报名后 | sola 侧结果 |
|---|---|---|---|
| 无审批无票 | `free` | 立即显示"已参加" | participant(attending)，双方计数一致 |
| require_approval | `restricted` | 显示"等待批准" | participant(pending) → 审批 UI → Accept/Reject 后对方状态翻转 |
| 需购票 | `external` | 显示外部报名按钮 → 跳 sola 售票页 | 无 Join 活动产生 |
| 满员 | — | 报名失败 | 无 participant，无 Accept 出站，不超卖 |

---

## 5. L3 — 端到端场景（docker 三方实验室）

### 5.1 实验室拓扑

```
lab/docker-compose.yml
  sola-a.lab     soon + seastar-app + postgres        （被测）
  sola-b.lab     第二个 sola 实例                      （sola↔sola，P4 起）
  masto.lab      本仓库 mastodon 检出（v4.7.0-alpha.2）+ pg + redis + sidekiq
  mobi.lab       本仓库 mobilizon 检出（v5.2.4）+ postgis
  proxy          Traefik/Caddy + mkcert 本地 CA（全员真 TLS，容器 hosts 互注）
```

- Mastodon 跑**两轮**：默认模式 + `AUTHORIZED_FETCH=true`（最严格，签名 GET 必须有效；过了它默认模式必过）。
- 实例数据可随时重置（`docker compose down -v`）——actor id 缓存污染在实验室无成本，这正是它存在的意义（staging/生产没有这个自由，见 §6）。

### 5.2 场景脚本（每个都是一条从 UI 出发的用户故事）

**S1 发现与关注**
Mastodon/Mobilizon 搜索 `@<group>@sola-a.lab` → 卡片显示（头像/简介）→ 关注 → sola 侧 follower +1 → 对方显示已关注 → 取消关注 → follower −1。反向：sola 搜索 `@group@mobi.lab`（P4）。

**S2 活动生命周期广播**
sola 群组发布活动 → Mobilizon 关注者收到结构化活动、Mastodon 关注者收到降级 status（`<h2>标题</h2> + summary + 链接`，验证 summary 的"时间-时区-地址"渲染）→ 改时间 → 双方同步 → 取消 → Mobilizon 显示 CANCELLED。

**S3 跨实例报名全流程**（§4 的表逐行走 UI）
额外覆盖：Mobilizon 用户报名后**在 Mobilizon 侧取消**（Leave）→ sola 计数回落；审批场景下 sola 管理员在**现有** seastar-app 审批页操作（证明复用无缝）。

**S4 评论互通**
Mastodon 用户回复活动 status → sola 活动评论区出现（HTML 已 sanitize、来源实例标注）→ sola 用户回复 → Mastodon 线程正确挂载（inReplyTo 链完整）→ Mobilizon 侧同一评论线程可见（三方一致性）。

**S5 sola↔sola**（P4）
sola-b 用户关注 sola-a 群组、报名活动；两个 sola 节点各自的"我的活动"正确。这是 SG↔CN 未来互联的预演。

**S6 故障与恢复**
`docker stop masto.lab` → sola 发布活动 → 队列积压 → 重启 Mastodon → 断言退避窗口内补投成功；对方返回 410（删除账号）→ 断言 follower 清理。

**S7 治理：黑白名单与限流的对方行为验证**（矩阵级测试见 FEDERATION_TEST_PLAN §5/§6，此处验证只能在真实实例上验的部分）
拉黑 masto.lab → 其用户的关注/报名/评论全链路被拒（403 且 sola 无密钥抓取出站），mobi.lab 全程不受影响 → 解除拉黑恢复；切换 `FEDERATION_MODE=allowlist` 只含 mobi.lab → masto.lab 全流程被拒、mobi.lab 正常；用脚本对 sola inbox 洪泛触发 429 → **验证真实 Mastodon/Mobilizon 收到 429 + Retry-After 后确实按语义退避重投而非丢弃**（发送端行为只有真实实例能证明）；全场景跑完后 stats 端点各域计数与双侧取证记录一致。

### 5.3 判定与记录

每个场景一张结果表（步骤 / 预期 / 实际 / 截图或 curl 输出 / PASS-FAIL），
归档到 `soon/test/interop-reports/<日期>-<版本>.md`。**双侧取证**：sola 侧断言
数据库状态，对方侧断言 UI/API 状态——只看单侧会漏掉"我以为发出去了"类 bug
（writefreely 忽略响应码的教训）。

---

## 6. L4 — 生产灰度验证

1. **staging 先行**：全部路由部署到 staging 域，用公网真实实例（mastodon.social 上的测试账号 + 一个公共 Mobilizon 实例如 mobilizon.fr 的测试账号）重跑 §2 全部 + S1/S2。⚠️ **只用一次性测试群组**——公网实例会永久缓存 actor id 与公钥，staging 域的 actor 不可复用到生产。
2. **生产开启**（`FEDERATION_ENABLED=true`，需明确的 ginger deploy 指令）后观察一周：
   - `fed_deliveries` 队列深度与最老 pending 年龄（阈值：深度 < 500，年龄 < 1h）；
   - 投递成功率按域 top-N（连续失败域是否该进屏蔽表）；
   - DB 连接水位（联邦上线前后 `pg_stat_activity` 对比，绝不能逼近 22 上限）；
   - GoodJob `:mailers` 队列延迟无回归（验证码邮件时效是红线）。
3. **回滚预案**：关 `FEDERATION_ENABLED` 即停收停发（inbox 返回 503、sweeper 不派发）；已铸造的 actor id 与密钥保留，重开后身份连续。

---

## 7. 建设时序（与 FEDERATION_PLAN 分期对应）

| 分期 | 本方案交付 |
|---|---|
| P0 | §3.1 签名负例矩阵（实现签名库的同一个 PR 内），夹具目录骨架 |
| P1 | §2 L0 脚本全套（对 staging 跑通），CI 接入 |
| P2 | §3.2 S2S harness + §3.3 夹具契约测试；实验室搭建（masto.lab + mobi.lab）；S1/S2/S6/S7 |
| P3 | §4 领域语义回环 + S3/S4 |
| P4 | sola-b.lab + S5；§6 staging 公网验证 → 生产灰度 |

CI 策略：L0 脚本 + 全部单测/harness 每次提交跑；实验室场景（分钟级、依赖
docker）作为合并前手动门禁 + 每周定时全量，报告归档。

---

## 8. 已知不验证项（明确出界）

- LD Signatures / FEP-8b32 对象完整性证明（不做转发场景，见 FEDERATION_PLAN §6）；
- RFC 9421 出站（只验证入站能收 9421 并按 cavage 回落）；
- Pleroma/Misskey/GoToSocial 等其他实现：不主动验证，收到其流量按通用路径处理，兼容性问题按报告修复（writefreely 的 Hubzilla/Pleroma workaround 清单提示这类问题会来，但不预支）；
- 性能压测：连接预算下的吞吐上限由 §6 生产观察给出经验值，不做合成压测。
