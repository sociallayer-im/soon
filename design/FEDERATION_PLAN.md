# Sola ActivityPub 联邦网络架构方案

> 状态：**待确认，未实施**。本文档基于对 mastodon、mobilizon、nebula/nebula、
> nebula/writefreely 四个参考项目源码级分析（2026-08-02），以及 soon /
> seastar-app 现状盘点。所有 file:line 引用均可在本仓库同级目录中核对。
>
> 目标：sola 服务器之间构成联邦网络，用户/群组/活动数据跨节点互通，
> 远端用户可以关注社区、报名其他节点的活动，并与 Mobilizon、Mastodon 互通。
>
> **首要互操作对象是 Mobilizon**：sola 的联邦语义（词表、活动类型、报名/群组
> 流程、受众规则）与 Mobilizon 保持平齐——凡 Mobilizon 已有定义的语义，照其
> converter 实现原样采用，不自创方言；Mastodon 作为微博类展示端兼容（summary
> 降级渲染），是第二优先级。

---

## 1. 参考项目架构分析结论

### 1.1 四个项目各自能教我们什么

| 项目 | 技术栈 | 联邦完成度 | 对 sola 的价值 |
|---|---|---|---|
| **Mobilizon** v5.2 | Elixir/Phoenix | 完整（活动联邦标准） | **首要互操作对象**：Event/Join/Accept 的 JSON-LD 词表、报名/群组流程、受众规则是 sola 语义的直接蓝本，逐条对齐 |
| **Mastodon** v4.7 | Rails 8.1 | 完整（事实标准） | 互通的**硬性验收标准**：webfinger 回环、内容类型、HTTP 签名要求、投递重试语义 |
| **nebula/nebula** | Rails 8.1 | 原型（发布方向可用） | Rails 落地的骨架参考：URL 生成模块、密钥生成、**进程内 mock 远端的 S2S 测试框架** |
| **writefreely** | Go | 最小可互通实现 | "最小可行面"的边界：哪些可以不做仍能和 Mastodon 互通 |

### 1.2 与 Mastodon 互通的硬性要求（验收红线）

来自 Mastodon 源码（`app/lib/webfinger.rb`、`app/services/activitypub/process_account_service.rb`、
`app/lib/signed_request.rb` 等）：

1. **Webfinger 回环**：`GET /.well-known/webfinger?resource=acct:user@domain` 返回的
   `links[rel=self].href` 必须等于 actor 文档的 `id`；Mastodon 还会反向验证——
   用 actor `id` 的 host + `preferredUsername` 再查一次 webfinger，必须回到同一个 acct。
   **不满足则账号永远不会被创建**（`process_account_service.rb:147-173`）。
2. **self link 的 `type` 只接受两个精确字符串**：`application/activity+json` 或
   `application/ld+json; profile="https://www.w3.org/ns/activitystreams"`。
3. **Actor 抓取响应的 Content-Type** 必须是上述二者之一（ld+json 必须带 profile 参数），
   且文档 `id` 必须等于被抓取的 URI。
4. Actor 必须有 `preferredUsername` 和 `inbox`；`type` ∈ {Person, Group, Organization,
   Service, Application}；`@context` 必须含 activitystreams 命名空间。
5. **inbox POST 无条件要求 HTTP 签名**（draft-cavage，rsa-sha256 或 hs2019）：
   POST 必须签 `digest`，必须签 `date` 或 `(created)`；`Digest: SHA-256=<b64>`（仅 SHA-256，
   解码后必须 32 字节）。时间窗：±1 小时时钟偏移容忍。
6. authorized_fetch 模式下 GET 也要签名（签 `(request-target) host date`），
   签名者必须能解析为一个 Account —— 所以要有**实例 actor**（Mastodon 自己用
   `/actor`，keyId `…#main-key`）。
7. `Create` 的 object `id` 的 host 必须与 actor host 一致；公开可见性通过 object 的
   `to`/`cc` 含 `https://www.w3.org/ns/activitystreams#Public`（或 `as:Public`）判定。
8. **投递响应语义**：2xx = 成功；4xx（除 401/408/429）= 永久失败不重试；
   401/408/429 和 5xx（除 501）会按指数退避重试（16 次，约 5-6 天）；
   连续 7 个自然日投递失败 → 整个域被标记不可用，停止投递。
9. **Mastodon 能显示 `Event` 类型**（`CONVERTED_TYPES` 含 Event，
   `activity.rb:9-10`），渲染为 `<h2>{name}</h2>\n{summary}\n{链接}` —— 结构化字段全部丢弃。
   所以 **`summary` 字段要放"时间 - 时区 - 地址"的人类可读文本**（Mobilizon 正是为此
   加的 summary，`converter/event.ex:389-403`）。

### 1.3 Mobilizon 的活动联邦模型（我们的领域蓝本）

- **Event 对象**：AS2 `Event` + schema.org（`sc:`）/自有（`mz:`）/iCal（`ical:`）扩展词表。
  关键属性：`startTime`/`endTime`、`location`（`Place` + `PostalAddress` + 顶层
  `longitude`/`latitude`）、`joinMode`（free|restricted|invite|external）、
  `maximumAttendeeCapacity`、`remainingAttendeeCapacity`、`participantCount`、
  `status`（CONFIRMED|TENTATIVE|CANCELLED，双写 `ical:status`）、`commentsEnabled`、
  `anonymousParticipationEnabled`、`timezone`、`draft`、`uuid`、`summary`。
- **报名 = `Join` 活动**：`{"type":"Join","actor":<用户>,"object":<event url>,
  "participationMessage":…}`。免审批 → 主办方实例直接回 `Accept`（object 内联整个
  Join）；需审批 → 挂起，审批后回 `Accept`/`Reject`。退出 = `Leave`。
  **只有活动归属实例有权 Accept**（收到 Accept 时校验签名者 `can_manage_event?`）。
- **没有跨实例参与者集合**——只联邦 `participantCount` 标量；容量校验各实例各自做，
  存在竞态（可接受）。
- **群组联邦**：Group actor + `Member` 一等对象（有自己的 id 和 role）、
  Join/Invite/Accept/Remove；群组内容同步 = 推（audience 注入 members 集合 + 展开投递）
  + 拉（接受成员后全量爬七个集合）+ 群组实例作为 hub 转发 Announce。**这块复杂度高，
  我们放最后、可裁剪。**
- **评论互通**：`Note` + `inReplyTo: <event url>`。Mastodon 用户回复被 boost 的
  Event status 时，Mobilizon 抓取 inReplyTo 发现是 Event，把 toot 变成活动评论。

### 1.4 两个原型项目的共同教训（我们必须避免）

nebula 和 writefreely 都犯了同样的错，且都"能跑"——直到上生产：

- **都没有做入站签名验证**。nebula 的后果最严重：匿名 POST 一个 Delete 即可删除
  本地帖子（`inboxes_controller.rb:137-151`，无属主校验）。**我们的 inbox 从第一天
  起强制验签 + 验 Digest + 时间窗。**
- **都没有投递队列/重试**：nebula 在 AR 回调里同步阻塞投递（失败即静默丢失）；
  writefreely 裸 `go func` 无重试、进程重启丢投递。**我们从第一天起走 outbox 表 +
  GoodJob。**
- nebula 签名把端口写进 `host`（`service.rb:85`，https 下变成 `host: example.com:443`），
  和 Mastodon 验签必然失败——**签名字符串逐字段对照 Mastodon 的验证代码写测试**。
- 值得直接借鉴的：nebula `lib/activity_pub/urls.rb`（集中式 URL 生成）、
  `test_federation_s2s.rb` 的进程内 mock 远端 + 线程安全投递记录仓的测试架构；
  writefreely 的"共享 inbox 按 host 去重投递"“给签名 GET 也带空 body Digest"等
  兼容性细节。

---

## 2. Sola 联邦架构设计

### 2.1 现状约束（决定架构形态的四件事）

来自 soon/seastar-app 盘点：

1. **后台资源极紧**：生产共享 Postgres 仅 ~22 可用连接，soon 池 = 6；GoodJob
   `:async` 模式**只有 1 个后台线程**，与邮件投递共用。→ 投递必须是
   outbox 表 + 小步长排空 + 限速，绝不能每个活动裸 fan-out N 个 HTTP。
2. **无密钥体系**：users/groups 没有任何 RSA/Ed25519 密钥列。→ 新增加密存储的
   密钥列 + 存量回填。
3. **`users.name`（即 handle）可为空**（钱包/微信首登用户），格式 `[a-z0-9_]{3,30}`
   唯一；`groups.name` 非空唯一，`[a-z0-9_-]{3,30}`。→ **群组天然可寻址；用户必须
   先设置 handle 才开启联邦身份**。
4. **双域名**：API 在 `api.sola.day`，人类访问 `app.sola.day`（邮件/iCal 链接全部
   指向后者）。Actor URL 一旦铸造不可更换。

### 2.2 决策一：规范域名 = `app.sola.day`

Actor 身份形如 `@handle@app.sola.day`，actor id 形如
`https://app.sola.day/users/<handle>`。理由：

- 这是用户认知里的"实例域名"，也是所有邮件、iCal、分享链接的域；
- webfinger 回环要求 actor id 的 host 必须能同时服务 webfinger 和 AP JSON，
  选 app 域一步到位，将来对人类展示 `@alice@app.sola.day` 而非 api 子域。

实现方式：**seastar-app 加 Next.js rewrites**（`next.config.mjs` 目前完全没有
rewrites，加上不影响现有页面），把以下路径代理到 soon：

```
/.well-known/webfinger      → https://api.sola.day/.well-known/webfinger
/.well-known/nodeinfo       → https://api.sola.day/.well-known/nodeinfo
/nodeinfo/2.0               → https://api.sola.day/nodeinfo/2.0
/users/:handle              → 按 Accept 协商：AP 请求 rewrite 到 api，HTML 请求走现有 profile 页
/users/:handle/inbox|outbox|followers|following → api
/groups/:handle(/…)         → 同上
/events/:id(/…)             → 同上
/inbox                      → api（shared inbox）
/actor                      → api（实例 actor）
```

Accept 协商：AP 客户端带 `Accept: application/activity+json`，Next middleware
判断后 rewrite；普通浏览器继续拿 HTML。（备选：Traefik 按 Host+PathPrefix 直接
把这些路径路由给 soon 服务，不经过 Next——两个服务本来就在同一台 Traefik 后面；
Next rewrites 的好处是配置进仓库、CN 部署 juluo.xyz 自动同构。）

soon 侧路由加在 `/api/v1` **之外**的根层（现状根层只有 `/up` 和
`/group/icalendar`，无冲突）。Rails 需信任 `X-Forwarded-Host`（限定白名单），
用 `FEDERATION_HOST=app.sola.day` 环境变量集中生成 URL（借鉴 nebula `urls.rb`）。

### 2.3 决策二：Actor 映射

| sola 实体 | AP Actor 类型 | 寻址 | 备注 |
|---|---|---|---|
| User | `Person` | `@name@app.sola.day` | **仅 name 非空的用户**可联邦；无 handle 用户提示先设置 |
| Group（含 popup city） | `Group` | `@name@app.sola.day` | 主要联邦入口：Mastodon 用户关注群组即可在时间线看到活动 |
| 实例 | `Application`（`/actor`） | `app.sola.day@app.sola.day` | 用于签名出站 GET（authorized fetch）、中继 |

Event 不是 actor，是群组/用户名下的**对象**（同 Mobilizon）。
`attributedTo` = 群组 actor，`actor`（Create 的）= 发布者。

TSID 与 handle 共存没有冲突：AP 路由用 handle（`/users/:handle`），对象路由用
TSID（`/events/:id`）；现有 `User.resolve!` 已同时支持两者。

### 2.4 决策三：对象与活动词表（与 Mobilizon 语义平齐）

平齐原则：以 `mobilizon/lib/federation/activity_stream/converter/*.ex` 的出入站
形状为**规范**，sola 的序列化器按它逐键实现；Mobilizon 的兼容性启发式
（endTime 补全、status 双写、audience 反转等）一并采用，使 Mobilizon 收到
sola 的对象时走的是它处理同类实例的同一条代码路径。

**Event 出站形状**（映射自 `events` 表）：

```jsonc
{
  "@context": ["https://www.w3.org/ns/activitystreams",
               "https://w3id.org/security/v1",
               { "sc": "http://schema.org#", "mz": "https://mobilizon.org/ns#",
                 "ical": "http://www.w3.org/2002/12/cal/ical#",
                 "pt": "https://joinpeertube.org/ns#",
                 "commentsEnabled": {"@id":"pt:commentsEnabled","@type":"sc:Boolean"},
                 "joinMode": {"@id":"mz:joinMode","@type":"mz:joinModeType"},
                 "participantCount": {"@id":"mz:participantCount","@type":"sc:Integer"},
                 "anonymousParticipationEnabled": {"@id":"mz:anonymousParticipationEnabled","@type":"sc:Boolean"},
                 "maximumAttendeeCapacity": {"@id":"sc:maximumAttendeeCapacity","@type":"sc:Integer"},
                 "location": {"@id":"sc:location","@type":"sc:Place"},
                 "timezone": {"@id":"mz:timezone"},
                 "status": {"@id":"ical:status","@type":"ical:status"},
                 "uuid": "sc:identifier" }],
  "type": "Event",
  "id": "https://app.sola.day/events/<tsid>",
  "url": "https://app.sola.day/event/detail/<tsid>",
  "name": "<title>",
  "actor": "<owner actor url>",
  "attributedTo": "<group actor url>",
  "content": "<content 渲染为 HTML>", "mediaType": "text/html",
  "startTime": "…", "endTime": "…", "timezone": "<event_timezone>",
  "status": "CONFIRMED",            // published→CONFIRMED, cancelled→CANCELLED
  "ical:status": "CONFIRMED",       // 双写，Mobilizon 向后兼容
  "draft": false,
  "joinMode": "free",               // require_approval→restricted; 有 ticket→external
  "externalParticipationUrl": "https://app.sola.day/event/detail/<tsid>",  // ticket 场景
  "maximumAttendeeCapacity": <max_participant>,
  "participantCount": <participant_count>,
  "commentsEnabled": true,
  "anonymousParticipationEnabled": false,
  "location": { "type": "Place", "name": "<venue.name|place.name>",
                "address": { "type": "PostalAddress", "streetAddress": "<address>", … },
                "latitude": <lat>, "longitude": <lng> },
  "attachment": [ { "type": "Image", "name": "Banner", "url": "<image_url>" } ],
  "tag": [ { "type": "Hashtag", "name": "#<tag>" } ],
  "summary": "<起止时间(本地化) - GMT±X - 地址>",   // 给 Mastodon 看的关键字段
  "to": ["https://www.w3.org/ns/activitystreams#Public"],   // visibility=public
  "cc": ["<group followers url>"]
}
```

映射要点：

- 受众规则照抄 Mobilizon（`audience.ex:135-138`）：public → `to: [as:Public],
  cc: [followers]`；非 public → **反转**为 `to: [followers], cc: []`（Mobilizon 的
  入站可见性判定是"as:Public ∈ to 则 public，否则 unlisted/private"，反转保证
  对方判定正确）。draft/pending/archived **不出站**（对齐 Mobilizon `draft` 语义）。
- `joinMode`：soon 的免费无审批 → `free`；`require_approval` → `restricted`；
  **需要购票的活动 → `external` + `externalParticipationUrl` 指回 sola 售票页**
  （Mobilizon 原生语义，远端会显示"到源站参与"——支付流程不联邦，这是刻意裁剪）。
- 地点：`venues`/`places` 都有 name/address/lat/lng，直接映射 Place；线上活动
  （meeting_url）→ `isOnline: true` + attachment Link（学 Mobilizon）。
- `endTime` 不留空（Mobilizon 有"nil → 当日 23:59:59"的双向启发式，`event.ex:78-84,
  145-149`，跟随之）。
- 更新 → `Update`，取消/删除 → 状态改 CANCELLED 的 `Update` + （硬删时）`Delete` + Tombstone。
- 活动 id 约定同样平齐：`Accept(Join)` 的 id 形如 `<host>/accept/join/<participant_id>`、
  `Reject` 形如 `<host>/reject/join/<id>`、`Leave` 形如 `<host>/leave/event/<id>`
  （`accept.ex:77-103`、`reject.ex:41-69`、`leave.ex:31-70`）；`Accept` 的 `object`
  **内联完整 Join 原文**（对方靠 join object URL 关联参与记录）。
- `Join` 的受众也按 Mobilizon（`audience.ex:79-95`）：`to: [参与者, 组织者]`，
  `cc: [其他参与者 actor]`——这是跨实例参与者信息传播的唯一机制。

**活动类型总表**：

| 活动 | 方向 | 语义 |
|---|---|---|
| `Follow` / `Accept` / `Undo(Follow)` | 双向 | 关注用户/群组（Mastodon & Mobilizon 关注 sola 群组是第一互通场景） |
| `Create/Update/Delete(Event)` | 双向 | 活动发布/修改/取消 |
| `Join` / `Accept(Join)` / `Reject(Join)` / `Leave` | 双向 | 跨实例报名（对齐 Mobilizon 语义；只有活动属主实例可 Accept） |
| `Create(Note, inReplyTo: event)` | 双向 | 活动评论互通（映射到 `comments` 表，item_type=Event） |
| `Announce` | 入站 | Mastodon boost，仅计数/忽略（一期） |
| 其他未知类型 | 入站 | 202 接受后丢弃并记日志（学 Mastodon 静默丢弃） |

### 2.5 数据模型（新增，全部 `fed_` 前缀，避开已被占用的 `Activity` 模型名）

```ruby
# 本地密钥：users / groups 各加两列（Rails AR 加密存私钥）
add_column :users,  :fed_private_key, :text   # encrypts
add_column :users,  :fed_public_key,  :text
add_column :groups, :fed_private_key, :text   # encrypts
add_column :groups, :fed_public_key,  :text
# 惰性生成：首次被 webfinger/关注时生成 2048-bit RSA，不做全量回填

# 远端 actor 缓存（对照 nebula 的 remote_users 补齐缺失字段）
create_table :fed_actors, id: :string do |t|
  t.string :uri, null: false, index: {unique: true}   # actor id
  t.string :domain, null: false, index: true
  t.string :actor_type            # Person|Group|Application…
  t.string :preferred_username
  t.string :name; t.text :summary; t.string :icon_url
  t.string :inbox_url, null: false
  t.string :shared_inbox_url
  t.string :outbox_url; t.string :followers_url
  t.text   :public_key_pem        # 验签必需（nebula 漏了这个）
  t.string :key_id
  t.datetime :last_fetched_at     # 过期重抓（Mastodon 是 1 天）
  t.jsonb  :raw
end

# 关注关系（双向，state 支撑 pending Accept）
create_table :fed_follows, id: :string do |t|
  t.string :local_type, :local_id      # User|Group（被关注/发起方，多态）
  t.string :fed_actor_id               # 远端方
  t.string :direction, null: false     # inbound(远端关注本地) | outbound(本地关注远端)
  t.string :state, default: "accepted" # pending|accepted|rejected
  t.string :uri, null: false           # Follow 活动 id（Undo/Accept 按它匹配）
  t.index [:local_type, :local_id, :fed_actor_id, :direction], unique: true, name: "idx_fed_follows_uniq"
end

# 远端参与者：复用 participants 表（加列而非新表——报名逻辑/容量检查全部复用）
add_column :participants, :fed_actor_id, :string   # 非空即远端参与者
add_column :participants, :fed_join_uri, :string   # 远端 Join 活动 id（Accept/Reject 引用）
change_column_null :participants, :user_id, true   # 远端参与者无本地 user
# 唯一性：本地 (user_id,event_id) 不变；远端加 (fed_actor_id,event_id) 部分唯一索引

# 入站幂等：活动 id 去重（nebula/writefreely 都没做，重放防护必需）
create_table :fed_inbound_activities, id: :string do |t|
  t.string :uri, null: false, index: {unique: true}
  t.string :activity_type; t.string :fed_actor_id
  t.string :status, default: "processed"   # processed|failed|ignored
  t.datetime :created_at
end

# 出站投递队列（核心：不依赖 GoodJob 队列表做业务状态）
create_table :fed_deliveries, id: :string do |t|
  t.jsonb  :payload, null: false        # 签好名之前的活动 JSON
  t.string :sender_type, :sender_id     # 用谁的密钥签名
  t.string :inbox_url, null: false      # 已按 shared_inbox 去重后的目标
  t.string :status, default: "pending"  # pending|delivering|delivered|failed_permanent
  t.integer :attempts, default: 0
  t.datetime :next_attempt_at, index: true
  t.string :last_error
end

# 域策略：黑白名单（§2.10）
create_table :fed_domain_policies, id: :string do |t|
  t.string :domain, null: false, index: {unique: true}
  t.string :policy, null: false      # blocked | allowed
  t.string :reason
  t.string :created_by               # 操作者 user_id
  t.datetime :created_at
end

# 域级滚动统计：可观测性 + 熔断依据（§2.9）
create_table :fed_domain_stats, id: :string do |t|
  t.string :domain, null: false, index: {unique: true}
  t.integer :delivered_count, default: 0
  t.integer :failed_count, default: 0
  t.integer :inbound_count, default: 0
  t.integer :inbound_rejected_count, default: 0   # 验签失败/被限流/被拒格式
  t.datetime :last_success_at, :last_failure_at
  t.date :unavailable_since          # 连续失败起始日（域级熔断，Mastodon 7 天语义）
  t.string :last_error
end

# 远端事件镜像（Phase 4 才需要：本地用户浏览/报名远端活动）
create_table :fed_events, id: :string do |t|
  t.string :uri, null: false, index: {unique: true}
  t.string :fed_actor_id      # attributedTo
  t.jsonb  :data              # 解析后的规范化字段（title/start/end/location/joinMode…）
  t.datetime :last_fetched_at
end
```

### 2.6 代码组织（soon 内）

```
app/lib/federation/                  # 纯逻辑，无 AR
  urls.rb                # 集中 URL 生成（移植 nebula urls.rb 思路，FEDERATION_HOST）
  http_signature.rb      # draft-cavage 签名 + 验证（含 Digest、时间窗、(request-target)）
  json_ld.rb             # @context 构造（不引入 JSON-LD 处理器，学 Mobilizon/writefreely 硬编码词表）
  http_client.rb         # httpx 封装：超时(连5s/读10s)、跳转≤3、响应≤1MB、SSRF 防护(禁私网IP)
app/services/federation/
  webfinger_service.rb   # 出站解析 acct: → actor
  actor_fetch_service.rb # 抓取+缓存远端 actor（校验 id==URI、content-type、@context）
  inbox_service.rb       # 入站活动分发（Follow/Undo/Join/Accept/Reject/Create/Update/Delete/Leave）
  outbox_service.rb      # 构造活动 + 计算受众 + 展开 followers → 写 fed_deliveries
  serializers/           # event_serializer / actor_serializer / place_serializer …
app/controllers/federation/          # 根层路由（非 /api/v1）
  well_known_controller  # webfinger / nodeinfo 发现 / host-meta
  actors_controller      # /users/:handle /groups/:handle /actor（Accept 协商）
  inboxes_controller     # POST /users/:h/inbox /groups/:h/inbox /inbox（验签→202→入队）
  objects_controller     # /events/:id（AP 视图）
  collections_controller # outbox/followers/following（OrderedCollection + 分页）
app/jobs/federation/
  delivery_job.rb        # 单条 fed_delivery 投递：签名→POST→按状态码定 retry/permanent
  delivery_sweeper_job.rb# GoodJob cron 每分钟：捞 next_attempt_at 到期的 N 条入队（限速阀）
  inbound_job.rb         # inbox 202 之后的异步处理（验签在请求内、业务在任务内，学 Mastodon）
  actor_refresh_job.rb   # 远端 actor 过期刷新
```

关键运行时决策：

- **投递限速**：`delivery_sweeper_job` 每分钟最多派发 ~30 条（可配），
  `delivery_job` 内 HTTP 调用期间显式释放 AR 连接
  （`ActiveRecord::Base.connection_pool.release_connection` 包裹）。
  `GOOD_JOB_MAX_THREADS` 从 1 提到 **2**（多占 1 个 DB 连接，需按 CLAUDE.md 约定
  先测量连接余量再上生产），federation 用独立 `:federation` 低优先队列，
  排在 `:mailers` 之后，保证验证码邮件不被投递风暴饿死。
- **重试语义照抄 Mastodon**：4xx（除 401/408/429）→ `failed_permanent`；
  其余指数退避（`attempts**4 + 15 + jitter`，上限 10 次≈2 天——比 Mastodon 的
  16 次收敛快，尊重我们的资源预算）；同域连续 7 天失败 → 域级熔断表（v2 再做，
  一期先靠 permanent 状态止血）。
- **入站**：inbox 控制器内完成验签 + Digest + 时间窗 + 1MB 上限 + `fed_inbound_activities`
  幂等检查，**立即 202**，业务处理进 `inbound_job`（避免远端超时重发）。
  入站 HTML（content/summary）一律 sanitize 后入库。
- **安全**：私钥 `encrypts`；出站抓取禁私网 IP/localhost（SSRF）；域级
  blocklist 表留钩子；inbox 永不信任 payload 里的 `actor` 字段——以验签得到的
  keyId → actor 为准（学 Mastodon `MappedSignatureToIdentity`）。

### 2.7 报名（跨实例）流程设计

**入站（远端用户报名 sola 活动）—— Phase 3 核心：**

```
远端(Mobilizon) POST Join{actor, object: event_url} → sola inbox
  验签 → 解析 event → 复用 participants 业务规则：
    容量检查（max_participant / venue.capacity，复用 capacity_error 逻辑）
    joinMode=free  → 建 participant(fed_actor_id, status=attending)
                     → 出站 Accept{object: 内联 Join 原文, actor: 群组/组织者}
    require_approval → participant(status=pending)，进现有审批列表
                     → 管理员在 seastar-app 现有审批 UI 批准/拒绝
                     → approve/reject 钩子里追加出站 Accept/Reject(Join)
    需购票(external) → 出站 Reject + 说明（远端 UI 会引导去 externalParticipationUrl）
远端 Leave → participant 软取消（复用现有 transition!），participant_count 同步
```

**出站（sola 用户报名远端活动）—— Phase 4，依赖远端事件镜像：**

```
用户在 seastar-app 看到镜像的远端活动（fed_events）→ 点报名
  soon 以该用户的 Person actor 出站 Join → 等远端 Accept/Reject
  → 更新本地"我的活动"状态（远端活动的 participant 行指向 fed_events）
```

### 2.8 seastar-app 前端改动面

1. `next.config.mjs` rewrites + middleware Accept 协商（§2.2）。
2. 搜索支持 `@user@domain` / `@group@domain` → 调 soon 新增
   `/api/v1/federation/resolve` → 展示远端 actor 卡片 + 关注按钮。
3. 群组/个人页显示远端关注者计数；"关注"按钮对远端访客展示
   webfinger 引导（`ostatus subscribe` 模板，让 Mastodon 的关注弹窗可用）。
4. Phase 4：远端活动详情页（渲染 `fed_events` 镜像，报名走出站 Join）、
   活动评论区显示联邦评论（带来源实例标记）。
5. 用户设置页：无 handle 用户的"开启联邦身份需先设置用户名"引导。

### 2.9 可观测性：消息投递与联邦网络监控

约束下的务实选型：无 Redis、无现成 Prometheus 栈，所以观测三件套 =
**结构化日志 + 域级统计表 + 管理端点**，全部零新增基础设施：

1. **结构化日志**：所有联邦事件统一 tag（`[fed] direction=out type=Create
   domain=mobi.example status=delivered attempts=2 ms=340`），出站每次尝试、
   入站每次接收/拒绝各一行——`ginger logs | grep '\[fed\]'` 即可现场排查，
   也是事后对账的原始凭证。
2. **`fed_domain_stats` 滚动计数**（表结构见 §2.5）：投递成功/失败、入站
   接收/拒绝按域累计，`unavailable_since` 记连续失败起始——连续 **7 天**
   失败即域级熔断（对齐 Mastodon `DeliveryFailureTracker`），停止向该域投递，
   **收到该域任一合法入站签名请求即复位**。
3. **管理端点** `GET /api/v1/federation/stats`（平台 admin 权限）：
   - 队列健康：pending/delivering/failed_permanent 计数、最老 pending 年龄、
     近 1h 投递成功率;
   - 域视图：按失败率/拒绝率排序的 top-N 域（发现故障邻居和攻击源都靠它）;
   - 名单视图：当前 blocked/allowed 域及命中计数。
4. **告警阈值**（先进日志告警，接现有排查路径）：队列深度 > 500、最老
   pending > 1h、`:mailers` 队列延迟 > 5min（联邦挤占邮件的红线）、单域
   入站拒绝率突增。

### 2.10 反滥用：限流与黑白名单

**威胁模型**：恶意/失控实例洪泛 inbox；单个远端用户刷 Join/评论 spam；
伪造域批量制造 actor（子域爆破）；坏签名轰炸诱导出站密钥抓取放大。

**限流（多层，先到先挡）**：

| 层 | 限制 | 超限行为 |
|---|---|---|
| 域级 inbox | 每域每分钟活动数上限（默认 120/min，env 可调） | 429 + Retry-After（对方按语义退避，Mastodon/Mobilizon 都尊重） |
| 远端 actor 级 | 单 actor 的 Join ≤ 10/min、评论 Note ≤ 6/min、Follow ≤ 10/min | 429；持续超限自动升级为 actor 屏蔽并进日志 |
| actor 发现 | 单请求链新建远端 actor 上限、同一注册域子域数上限（对齐 Mastodon `SUBDOMAINS_RATELIMIT=10` / `DISCOVERIES_PER_REQUEST` 先例） | 拒绝新建，已有不受影响 |
| 密钥抓取 | 验签失败域的负缓存 + 熔断（同一坏 keyId 短期只抓一次） | 401 不抓取——**入站洪泛绝不能被放大成出站流量** |

实现：计数器放 Rails cache（进程内存足够——限流是防洪不是精确计费，
单进程部署下无分布式一致性问题）。

**黑白名单（`fed_domain_policies`）**：

- **两种运行模式**（env `FEDERATION_MODE`）：
  - `open`（默认）：开放联邦 + **黑名单**——`policy=blocked` 的域全链路拒绝；
  - `allowlist`：封闭联邦——**仅** `policy=allowed` 的域可通，其余一律拒。
    （多个 sola 节点私有组网、或 CN 节点合规场景用这个模式。）
- **执法点（全链路一致，测试逐点验证）**：
  1. inbox POST：blocked 域 → 403，**在密钥抓取之前判定**（keyId 域名先查表，
     不为攻击者做任何工作）;
  2. 出站：受众展开时过滤 blocked 域的 inbox（不入队，而非入队后失败）;
  3. actor 抓取/webfinger 解析：blocked 域直接拒绝;
  4. 已有数据：拉黑时既有 follower/participant 标记停用（保留数据可恢复，
     学 Mastodon suspend 语义而非硬删）。
- **actor 级屏蔽**：`fed_actors.blocked_at` 列，粒度补充（拉黑一个 spam 用户
  不必拉黑整个实例）。
- 管理入口：`/api/v1/admin/federation/policies` CRUD（平台 admin），
  变更即时生效（查表判定，无需重启）；每次命中计入 `fed_domain_stats`。

一期裁剪：不做 Mastodon 的 `silence`（收下但不公开展示）中间档——只有
block/allow 两态，语义简单、测试面小；需要再加。

---

## 3. 实施计划

原则：每期结束都有一个**可对外验收的互通里程碑**；soon 与 seastar-app 分仓提交；
不动 sails；上生产前全部先过 staging（`soon-api.sola.day` + 测试前端）。

### Phase 0 — 地基（无对外行为）
- 决策定版：域名（app.sola.day）、handle 策略、词表。
- 迁移：密钥列、`fed_actors`、`fed_follows`、`fed_inbound_activities`、`fed_deliveries`。
- `Federation::Urls`、`Federation::HttpSignature`（签名+验证，全量单测）、
  `Federation::HttpClient`（SSRF/超时/上限）。
- 产出：无路由变化，纯库表和 lib，`bin/rails test` 全绿。

### Phase 1 — 可被发现（只读联邦）
- webfinger、nodeinfo（2.0）、host-meta；实例 actor `/actor`。
- `/users/:handle`、`/groups/:handle` actor JSON（含 publicKey、followers/outbox 链接）；
  `/events/:id` 的 AP 视图（public+published 才可匿名取）；outbox/followers 空集合骨架。
- seastar-app rewrites 上线。
- **里程碑：在 Mastodon 搜索框输入 `@group@app.sola.day` 能显示群组卡片。**
  （此时关注会挂起——inbox 未开——预期内。）

### Phase 2 — 可被关注 + 活动推送（与 Mastodon 互通完成）
- inbox（验签全套）+ Follow/Undo(Follow) 处理 + Accept 出站。
- `fed_deliveries` + delivery_job/sweeper；Event 的 Create/Update/Delete 出站
  （挂在 events_controller 的 publish/approve/update/cancel 钩子上）。
- outbox/followers 返回真实数据（OrderedCollection 分页）。
- 观测与防护基线同批上线（§2.9/2.10）：`[fed]` 结构化日志、`fed_domain_stats`、
  stats 管理端点、inbox 域级限流、黑名单执法点 1/2/3——**inbox 对公网开放的
  同一个部署里必须带着限流和黑名单**，不留裸奔窗口。
- **里程碑：Mobilizon 用户关注 sola 群组后，群组发布的活动在 Mobilizon 侧
  以结构化活动（时间/地点/joinMode 完整）出现并随更新/取消同步；同一活动在
  Mastodon 时间线以标题+summary+链接降级显示。**

### Phase 3 — 跨实例报名（与 Mobilizon 互通，入站方向）
- Join/Leave 入站 → participants 复用；Accept/Reject(Join) 出站（含审批钩子）。
- Event 序列化补全 Mobilizon 词表（joinMode/participantCount/location Place…）。
- 活动评论入站：`Note inReplyTo event` → comments 表；本地评论出站。
- **里程碑：Mobilizon 实例用户报名 sola 免审批活动即时成功、审批活动走
  sola 现有审批 UI；活动页评论双向可见。**

### Phase 4 — 出站报名 + 远端内容展示
- `fed_events` 镜像 + 刷新任务；本地关注远端群组（outbound Follow）拉取其活动。
- seastar-app：远端 actor/活动展示、出站 Join 报名、"我的活动"含远端。
- **里程碑：sola 用户在 sola 界面里报名一个 Mobilizon 活动并出现在
  对方参与者列表。**

### Phase 5（可选，另行评审）— 群组成员联邦、中继、RFC 9421 双栈、
域级熔断/屏蔽管理界面、多节点 sola（SG/CN 互联即是第一对真实节点）。

规模预估（供排期参考）：P0 ≈ 小、P1 ≈ 小-中、P2 ≈ 中-大（签名+投递是最难部分）、
P3 ≈ 中、P4 ≈ 中-大（前端为主）。

---

## 4. 测试计划

### 4.1 单元测试（soon，minitest）
- **HTTP 签名**：签名串构造逐字节断言（含 `(request-target)` 小写、host 不带 443
  端口、Digest 32 字节）；验证侧用 Mastodon 的规则做负例矩阵——缺 digest 的 POST、
  缺 host 的 GET、时钟偏移 >1h、篡改 body、错误 keyId、hs2019。
- **序列化器**：Event/Actor/Place 出站 JSON 与 §2.4 形状全字段断言
  （参照 mobilizon `events_test.exs:29-61` 的逐键断言风格）；draft/pending 不出站；
  visibility 与 to/cc 的映射。
- **入站转换**：直接使用 mobilizon `test/fixtures/` 与 mastodon `spec/fixtures/` 的
  真实 JSON（`mobilizon-post-activity.json`、`mobilizon-join-activity.json`、
  `mastodon-follow-activity` 等）作为输入夹具，断言落库结果。
  夹具即互通契约。
- **幂等/安全**：重复活动 id 去重；1MB 上限 413；未知类型 202+丢弃；
  Delete 属主校验（nebula 事故的回归测试）；SSRF 私网地址拒绝。

### 4.2 集成测试：进程内 S2S harness（移植 nebula 的架构）
- 测试内起一个 Puma mock 远端（两个 mock actor + 线程安全投递记录仓），
  **但补上 nebula 缺的一环：mock 端验证 sola 发出的每个签名**（用 mock actor
  的公钥按 Mastodon 规则验），这样 host:port 类 bug 在 CI 就死。
- 覆盖：Follow→Accept 往返、Create(Event) 扇出（shared inbox 去重）、
  Join→Accept/Reject 往返、Leave、Undo(Follow)、投递失败→重试→permanent 状态机
  （mock 返回 400/401/429/500 各断言一次）。

### 4.3 回归保护
- 现有 573 例 `bin/rails test` 保持全绿；federation 路由不得触碰 `/api/v1` 行为
  （CORS、认证前置不变）。
- seastar-app：`npx tsc --noEmit` + `bun run lint`；rewrites 后现有页面路由快照
  （尤其 `/users/*` 与 profile 页的 Accept 协商不串线）。

## 5. 网络互操作性验证方案

### 5.1 本地联邦实验室（docker compose，三节点）

mastodon 和 mobilizon 仓库都自带 docker-compose。搭建：

```
lab/
  sola-a.localdev    ← soon+seastar-app（被测）
  masto.localdev     ← 本仓库 mastodon 检出（v4.7.0-alpha.2）
  mobi.localdev      ← 本仓库 mobilizon 检出（v5.2.4）
```

要点：三方互访需 HTTPS 与可解析域名——用 mkcert 本地 CA + Caddy/Traefik 反代 +
容器内 hosts 注入（Mastodon 对 content-type/签名的校验在 http 明文下同样生效，
`.onion` 之外不接受 http，所以必须真 TLS）。Mastodon 侧开启
`AUTHORIZED_FETCH=true` 跑一轮——这是最严格模式，过了它普通模式必过。

### 5.2 验收清单（每项都要在实验室里打勾）

**发现层**
- [ ] Mastodon 搜索 `@group@sola-a` → 显示卡片（webfinger 回环 + content-type 正确的证明）
- [ ] Mobilizon 搜索同上；`curl` 直接核对 webfinger JSON 的 self link type 精确字符串
- [ ] nodeinfo 被 fediverse 爬虫格式校验通过（`/.well-known/nodeinfo` → `/nodeinfo/2.0`）

**关注层**
- [ ] Mastodon 关注 sola 群组 → sola 记录 inbound follow，Mastodon 显示"已关注"
      （Accept 的 object 必须回显对方 Follow 的原始 id）
- [ ] Mastodon 取消关注（Undo 内联 Follow）→ sola follower 消失
- [ ] AUTHORIZED_FETCH 开启时 Mastodon 仍能抓取 actor/事件（sola 出站 GET 签名有效）

**内容层**
- [ ] sola 发布活动 → Mastodon 关注者时间线出现（标题/summary/回链正确渲染）
- [ ] 同一活动在 Mobilizon 侧显示为**结构化活动**（时间/地点/joinMode 完整）
- [ ] 活动更新/取消 → 两侧同步；取消后 Mobilizon 显示 CANCELLED
- [ ] Mastodon 用户回复该活动的 toot → sola 活动评论区出现该评论；
      sola 回复出站 → Mastodon 线程正确挂载

**报名层**
- [ ] Mobilizon 用户报名 sola 免审批活动 → 立即 Accept，双方计数一致
- [ ] 报名需审批活动 → sola 审批 UI 出现 → 批准/拒绝 → Mobilizon 侧状态正确
- [ ] 容量满时 Join 被拒绝且不超卖；Leave 后计数回落
- [ ] （P4）sola 用户报名 Mobilizon 活动 → 对方参与者列表出现

**健壮性层**
- [ ] 无签名/坏签名/过期 Date 的 inbox POST → 401，无副作用
- [ ] 重放同一活动 id → 幂等
- [ ] 对方实例宕机 → fed_deliveries 退避重试，恢复后补投；4xx 标记 permanent
- [ ] 1MB+ payload → 413；未知活动类型 → 202 且日志可查

### 5.3 生产前灰度

1. 全部路由先部署到 staging（`soon-api.sola.day` + 前端预览域），用一个真实的
   公网 Mastodon 测试账号（如 mastodon.social）完成 §5.2 发现层+关注层验证——
   **注意 actor id 一旦被公网实例缓存就固定了，所以 staging 验证要用一次性
   测试群组**，生产域的 actor 首次铸造必须在正式上线时。
2. 上线开关：`FEDERATION_ENABLED` env，默认关；先在 SG 生产开、观察
   fed_deliveries 积压/DB 连接水位一周，再考虑 CN（juluo.xyz 的公网可达性与
   TLS 对进出站都是前提，需单独评估）。
3. 观测：投递成功率、队列深度、按域失败 top-N 三个指标进现有日志/ginger logs
   排查路径；GoodJob dashboard 已有。

---

## 6. 已知裁剪与风险

| 项 | 决定 | 理由 |
|---|---|---|
| 支付/购票联邦 | 不做，`external` 模式回源站 | Mobilizon 原生语义，支付合规不可联邦 |
| 群组成员联邦（Member/Invite/七集合爬取） | 推迟 P5，届时仍按 Mobilizon 语义原样实现 | Mobilizon 最复杂子系统，非首要场景 |
| 匿名报名联邦 | 不做 | Mobilizon 也只做本地匿名 |
| JSON-LD 规范化处理器 | 不引入 | 四个参考项目里只有 Mastodon 部分做；硬编码词表足够互通 |
| RFC 9421 签名 | 只收不发（先 cavage） | Mastodon 默认发 cavage，9421 是 fallback |
| LD Signatures（转发场景） | 不做 | 只影响中继转发，直投不需要 |
| 无 handle 用户 | 不可联邦，UI 引导设置 | users.name 可空是既有事实 |
| 域级熔断 | P2 随 `fed_domain_stats` 实现（7 天语义） | 观测表顺带承载，成本已摊薄 |
| `silence`（收下不展示）中间档 | 不做，只有 block/allow 两态 | 语义简单、测试面小；需要再加 |
| CN 节点联邦 | 单独评估 | 跨境公网可达性/合规问题独立于本方案 |

最大的技术风险集中在两处：**HTTP 签名的逐字节正确性**（对策：负例矩阵单测 +
mock 端验签 + AUTHORIZED_FETCH 实验室）和**单后台线程下的投递吞吐**（对策：
outbox 限速排空 + 独立队列 + 连接释放；如果实测不够，再谈加线程/独立 worker，
那是一次需要重新测量连接预算的变更）。

---

*参考文件索引：Mastodon 要求细节 → mastodon/app/lib/{webfinger,signed_request}.rb、
app/services/activitypub/process_account_service.rb；Event/Join 词表 →
mobilizon/lib/federation/activity_stream/converter/{event,participant,address}.ex、
lib/federation/activity_pub/{utils,audience}.ex、test/fixtures/*.json；
Rails 落地骨架 → nebula/nebula/lib/activity_pub/urls.rb、test_federation_s2s.rb；
最小面参照 → writefreely/activitypub.go。*
