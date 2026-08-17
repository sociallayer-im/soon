# 论坛（Discussion）功能规划

Status: **规划中，未实现**（2026-08-17）。分支 `discussion`（`soon` 与
`seastar-app` 各一条），**验证完成前不合并回 main**。

参考实现：`/Users/jiang/zurich/soma/homeland`（Ruby China，Rails 8.0，
`0bad08a4`）。下文凡提到 homeland 的取舍，都基于对其 `db/schema.rb`、
`app/models/{topic,reply,node,counter}.rb` 和 `app/models/concerns/*` 的实际
阅读，不是照抄社区通行做法。

目标：在 event app 首页的主内容区加一个 `Event | Discussion` 切换，Discussion
是一个按 category 分板块、带 tag、可回帖、可收藏的主题列表。**论坛属于
group**（即 event home 所属的那个社群），不是全站单一论坛。

---

## 0. 先说五个已定的结论

1. **category = homeland 的 node，但它是 group 内的一张新表，不是 `groups`。**
   曾考虑复用 `groups.parent_id` 把板块做成子 group，否决了：子 group 有成员、
   权限、活动、handle 命名空间（`domains`），而板块只需要一个名字和排序。用
   group 做板块会让每建一个板块就多占一个全局 handle。
2. **reply 独立建表，不复用 `comments`。** `comments` 已经承载
   checkin/chat/comment/star/feedback 五种用途，且带联邦字段
   (`fed_uri`/`fed_actor_id`)。楼层有自己的生命周期（楼层号、最后回复回写、
   软删除后重算计数），塞进通用 comments 会把两种东西绑死。
3. **收藏复用现有的 star，不建新表。** `soon` 的 star 已经是
   `Comment(comment_type: "star", item: <polymorphic>)`，
   `POST /api/v1/comments/star` 接受任意 `item_type`。**收藏帖子在后端可以零
   改动跑通** —— 见 §5 的但书。
4. **回复是平铺的，回给帖子，不回给人。** 不做楼中楼，不做 `reply_to_id`。
   homeland 有 `replies.reply_to_id`，但它也只是"引用了谁"的弱指针，不构成树；
   我们连这个都不需要。
5. **两级开关：部署级 env + group 级列。** 见 §0.1。板块可以是私有的，
   可见性是板块自己的属性，帖子继承它 —— 见 §1.2。

---

## 0.1 两级开关

照搬 `soon` 已有的三个部署开关（`PHONE_LOGIN_ENABLED` / `STRIPE_ENABLED` /
`WECHAT_PAY_ENABLED`）的形状，一字不改：

**部署级（全局）** —— `DISCUSSION_ENABLED=true`，在 `ginger.yml` /
`ginger.cn.yml` 的 env 里设。`Api::BaseController` 加：

```ruby
def discussion_enabled? = ENV["DISCUSSION_ENABLED"] == "true"
def require_discussion_enabled! = render_not_found unless discussion_enabled?
```

**所有** discussion 端点（含公开读）挂 `before_action :require_discussion_enabled!`
—— 关闭时**返回 404 而不是 403**，和 `/auth/*_phone*` 一致：功能没上线时，
端点就该看起来不存在。

前端 `NEXT_PUBLIC_DISCUSSION`，只用来藏 UI，**后端那个才是权威的**。这个主从
关系必须在 `config.ts` 的注释里写明，`PHONE_LOGIN` 和 `STRIPE_ENABLED` 都是这么
注的。

**group 级** —— `groups.discussion_enabled`，boolean，**默认 `false`**。

默认值是个产品决定，不是技术细节。CLAUDE.md 记着 `admin_notification` 默认 `true`
那次教训：在 CN（1 个成员）上正确，在国际站上给 841 个 owner/manager 订阅了没人
要的邮件，而邮件发出去收不回来。这里同理 —— 默认 `true` 会让**每一个**现存
group 的首页突然长出一个空论坛 tab。默认 `false`，由 group 管理员在设置页主动
打开。

两级是 AND 关系：`DISCUSSION_ENABLED` 关 → 端点 404（group 那列的值无关紧要）；
env 开而 group 关 → 该 group 的论坛端点 404，首页不显示 tab。

⚠️ `discussion_enabled` 必须同时加进 `groups_controller` 的 permit 列表**和**
SDK 的 `updateGroup` 请求体。`group_params` 用的是
`params.require(:group).permit(...)`，**不在列表里的字段静默丢弃**，这在这个
仓库里已经造成过真实的数据丢失。设置页能保存但值不落库，是这个坑最典型的表现。

---

## 1. 数据模型

三张新表，全部沿用 `soon` 的 TSID 字符串主键（`ApplicationRecord` 的
`before_create :set_tsid_primary_key`），**不是** homeland 的 `id: :serial`。

### 1.0 命名：模型就叫 `Category`

| 场合 | 用什么 |
|---|---|
| 模型 / 表 | `Category` / `categories` |
| 外键 | `category_id` |
| REST 路径 | `/api/v1/categories` |
| 查询参数 | `category_id` / `category_slug` |
| Blueprint 字段 | `category` |
| SDK / 前端 / i18n | `category` / 板块 |

从模型到 URL 到前端类型是同一个词，没有翻译层。附带的好处是所有自动生成的
索引名都在 Postgres 的 63 字符上限内，不用手写 `name:`。

**代价，写在这里以免以后当成疏忽：** `Category` 是个裸名词，`soon` 里只能有
一个。将来若要做活动分类或徽章分类，它们**不能**再叫 `Category`，得叫
`EventCategory` / `BadgeCategory` —— 也就是说，先到先得的这一个归了论坛。
接受这一点是本次的明确决定，不是没想到。

对应地，`categories` 这张表**必须**有 `group_id`：它不是全站分类表，只是论坛
板块。任何以为"categories 是通用分类"的后续代码都是误解，注释里要写死。

### `categories`（板块）

```ruby
create_table :categories, id: :string do |t|
  t.string   :group_id,     null: false
  t.string   :name,         null: false          # 展示名，可中文
  t.string   :slug,         null: false          # URL 片段，小写
  t.string   :summary
  t.integer  :sort,         null: false, default: 0
  t.integer  :topics_count, null: false, default: 0
  t.boolean  :archived,     null: false, default: false
  t.string   :visibility,   null: false, default: "public",
             comment: "public | member | manager | invited"
  t.timestamps
  t.index [:group_id, :slug], unique: true
  t.index [:group_id, :sort]
  t.index [:group_id, :visibility]
end
```

**扁平，无 `parent_id`** —— 和 homeland 一致。层级用 `sort` 人工排序表达。
真需要分组时再说，加 `parent_id` 比拆掉它容易。

`slug` 在 group 内唯一而非全局唯一：板块 URL 是
`/event/<group>/discussion?category=<slug>`，本来就带 group 前缀，全局唯一没有
意义，也不该去挤 `domains` 那个命名空间。

板块由 group 的 manager 创建（`GroupPolicy#manage?`，父 group 的 manager 也算）。

### 1.2 私有板块

`visibility` 四档，从宽到严：

| 值 | 谁能看 |
|---|---|
| `public` | 任何人，包括未登录 |
| `member` | 该 group 的成员（含 manager / owner） |
| `manager` | 该 group 的 manager / owner（含父 group 的 manager） |
| `invited` | 显式名单，见下表 |

前三档不需要额外存储，直接查现有的 `memberships`。只有 `invited` 需要一张表：

```ruby
create_table :category_members, id: :string do |t|
  t.string :category_id, null: false
  t.string :user_id,     null: false
  t.timestamps
  t.index [:category_id, :user_id], unique: true
  t.index :user_id
end
```

为什么不是"一张表通吃"（所有档都写名单）：`member` 档要跟着 group 成员变动自动
生效，物化成名单就要在每次加入/退出 group 时同步，那是一个必然会漂移的副本。
名单只在**没有现成集合可查**的 `invited` 档才存在。

#### 可见性是板块的属性，帖子继承它

`topics` **不重复存可见性**。一个帖子能不能看，取决于它所在的板块 —— 单一真相
来源。代价是每个 topic 查询都要能拿到"当前用户可见的板块 id 集合"，所以统一走
一个 scope：

```ruby
# Category.visible_to(user, group)   → 返回 category 关系
# Topic.in_visible_categories(user)  → where(category_id: ...)
```

**移动帖子到另一个板块会改变它的可见性。** 把帖子从 public 板块移进 manager
板块等于把它藏起来，反过来等于公开它 —— 移动操作必须只有 manager 能做，并且
在 UI 上说清楚会发生什么。

#### 私有板块最容易漏的地方，是别的端点

板块列表和帖子列表上做过滤是显然的。真正的风险在**绕过列表的路径**，每一条都
必须过同一个 scope：

- `GET /topics/:id` 直接按 id 取（拿到过 id 的人）
- `GET /topics/:topic_id/replies` 楼层列表
- 搜索（`search` 参数）
- `starred_id` 收藏列表 —— **收藏之后板块才变私有**，或者用户被移出名单
- `user_id` 过滤（"某人发过的帖"）
- `activities` 通知 —— 有人回复了私有板块的帖，通知落到 receiver 身上；
  之后此人失去权限，通知里的标题还在
- 未来的联邦出站（`fed_uri`）—— 私有板块的帖**绝不能**进 outbox

这不是可以靠"记得加条件"解决的，必须是**一个 scope，所有读路径都从它出发**，
并且每条路径都有测试。

#### 不可见时返回 404，不返回 403

访问看不到的私有板块或其中的帖子，一律 `render_not_found`。403 等于确认"这里
有个东西但你看不到"，对私有板块本身就是信息泄漏（板块名往往就是内容，比如
`acquisition-talks`）。这与 §0.1 里 env 关闭时返回 404 是同一条原则。

### `topics`（主题帖）

```ruby
create_table :topics, id: :string do |t|
  t.string   :group_id,               null: false
  t.string   :category_id,            null: false
  t.string   :user_id,                null: false
  t.string   :title,                  null: false
  t.text     :content
  t.string   :content_type, default: "text"      # 与 comments 一致
  t.string   :image_url                          # 可选海报，列表卡片用
  t.string   :tags,     default: [], array: true
  t.string   :status,   default: "published"     # published | closed | hidden
  t.datetime :pinned_at                          # 置顶（板块内）
  t.datetime :closed_at                          # 锁帖，不再接受回复

  # 反规范化的"最后回复"缓存 —— 列表页排序与展示全靠它，见 §1.1
  t.string   :last_reply_id
  t.string   :last_reply_user_id
  t.datetime :replied_at
  t.integer  :replies_count, null: false, default: 0
  t.integer  :stars_count,   null: false, default: 0
  t.bigint   :last_active_mark, null: false      # 排序键，Unix 秒

  t.datetime :deleted_at                         # 软删除
  t.timestamps
  t.index [:group_id, :status, :last_active_mark]
  t.index [:category_id, :status, :last_active_mark]
  t.index [:group_id, :pinned_at]
  t.index :user_id
  t.index :deleted_at
  t.index :tags, using: :gin
end
```

**`last_active_mark` 是整数 Unix 秒而不是 datetime**，直接抄 homeland：列表页
唯一的排序键，整数索引扫描更省。同时抄它那条产品规则：

```ruby
self.last_active_mark = Time.now.to_i if created_at > 1.month.ago
```

一个月前的老帖，回复不再顶回首页。这是**反挖坟**，同时让排序索引的写入热点
收敛在近期数据上。

**`last_reply_user_login` 不抄。** homeland 连回复者的 login 都反规范化进
`topics`，是为了列表页不 join `users`。我们的 handle 会改（`HandleName` 允许
改名），存下来就会过期，而列表页本来就要 `includes(:last_reply_user)` 取头像。

**`stars_count` 需要自己维护**，因为 star 落在 `comments` 表里，不是关联。见
§5。

### `replies`（楼层）

```ruby
create_table :replies, id: :string do |t|
  t.string   :topic_id, null: false
  t.string   :user_id,  null: false
  t.text     :content,  null: false
  t.string   :content_type, default: "text"
  t.datetime :deleted_at
  t.timestamps
  t.index [:topic_id, :created_at]
  t.index :user_id
  t.index :deleted_at
end
```

刻意**没有**的三个字段，每个都对应 homeland 的一个决定：

- **没有 `action` / `target_type`。** homeland 把"加精""封禁""关帖"这类系统
  事件写成 `action` 非空的 reply，混进楼层流。省了一张表，代价是此后**每一处**
  查询都要记得 `.without_system`，`replies_count` 也要排除它们——忘一次就是脏
  数据露出。我们把这些操作留给现有的 `activities` 表。
- **没有 `reply_to_id`。** 平铺，见 §0.4。
- **没有 `mentioned_user_ids`（数组列）。** 一期不做 @ 提醒。真要做时，
  homeland 的做法（`before_save` 正则扫 body，最多取 5 个，存
  `integer[]`）可以直接翻译成 `string[]`，但要连它的 **limit(5)** 一起抄——
  没有上限的话一条 @全员 就是一次群发。

### 与现有模型的关系

| 现有 | 关系 |
|---|---|
| `Group` | 论坛的归属；`has_many :categories, :topics` |
| `User` | 作者、回复者 |
| `Comment` | 收藏（`comment_type: "star"`, `item: Topic`） |
| `Activity` | 通知/动态（**复用，不引入 homeland 的 `notifications`**） |

homeland 的 `notifications` 表有 `target` / `second_target` / `third_target`
三级多态，明显是长年累积出来的形状。`soon` 的 `activities`
（`action` + 多态 item + `receiver_id` + `has_read` + `jsonb payload`）更干净，
用自己的。

---

## 1.1 计数器：重算，不增减

`topics.replies_count` 和 `categories.topics_count` **一律全量重算**，
不用 `counter_cache`，也不用 `increment!`。

原因和 `Participant#transition!` / `sync_event_seat!` 踩过的坑是同一类：软删除
走 `update_columns`，**不触发 callback**，`counter_cache` 不会减，计数必然漂移。
homeland 自己就是这么绕过去的——`Topic#update_last_reply` 里是
`self.replies_count = replies.without_system.count`，一次 COUNT，不是增减。

**计数器的所有权必须单点**：`Topic#refresh_last_reply!` 是唯一写
`replies_count` / `last_reply_id` / `replied_at` / `last_active_mark` 的地方，
创建回复、删除回复、恢复回复都调它。

浏览量（`hits`）**一期不做**。homeland 把它放 Redis（`RedisCountable`）而从不
落库，是对的：PV 每次请求都要写，落库就是给主表制造写热点。我们要做时照这个
做，不要加一列 `views_count`。

---

## 2. 软删除

抄 homeland 的 `SoftDelete` concern（`deleted_at` + `default_scope` +
覆盖 `destroy`），但**改一个名字**：

homeland 里 `alias_method :destroy!, :destroy` 把原始的硬删除挂到了 `destroy!`
上。这在 Rails 语境里是陷阱——`destroy!` 本该表示"失败就抛异常"，这里被改成
"真的删掉"。我们命名为 `hard_destroy!`。

`default_scope` 本身也有代价（`unscoped` 会一并丢掉排序、`joins` 里行为微妙），
但比在每个查询上挂 `.where(deleted_at: nil)` 更不容易漏。接受它，并在 concern
里提供 `with_deleted`。

---

## 3. 权限

复用 Pundit 与 `groups` 已有的权限列，**不新增权限模型**：

- 看板块/主题：group 本身的可见性 **AND** 板块的 `visibility`（§1.2）。
  两层都要过 —— 一个 public 板块挂在私有 group 下，仍然只有成员能看。
- 发主题：新增 `groups.can_post_topic`（`manager | member | everyone`），
  默认 `member`。与 `can_publish_event` 同形，这样后台设置页可以直接复用组件。
  **但它被板块可见性收紧**：看不见的板块自然发不了帖；`manager` 档的板块里，
  `can_post_topic: everyone` 也只有 manager 能发。取两者的交集，不是并集。
- 回复：同上
- 编辑/删除自己的：作者本人
- 建/改/删板块、改板块可见性、管理 `invited` 名单、置顶、锁帖、移动板块、
  删他人帖：`GroupPolicy#manage?`（group manager，且按现有规则，父 group 的
  manager 也管得了子 group）

⚠️ **`group_params` 的 permit 列表是静默丢弃的**（CLAUDE.md 有记录，已造成过真实
数据丢失）。新增 `can_post_topic` 和 `discussion_enabled` 必须同时改
`groups_controller` 的 permit 列表和 SDK 的 `updateGroup` 请求体，两处都要，
否则设置页保存了但值不落库。

---

## 4. API

全部在 `/api/v1` 下，列表一律走 `render_collection`（Pagy，`{data, meta}`，
默认 20，上限 `PAGY_MAX_LIMIT = 500`）。

全部端点挂 `before_action :require_discussion_enabled!`（§0.1），并在取到
group 后校验 `group.discussion_enabled`，不满足一律 404。

```
GET    /categories?group_id=                 板块列表（只返回可见的）
POST   /categories                           建板块（manager）
PATCH  /categories/:id                       含改 visibility（manager）
DELETE /categories/:id

GET    /categories/:id/members               invited 名单（manager）
POST   /categories/:id/members               加人（manager）
DELETE /categories/:id/members/:user_id

GET    /topics                               列表；filters 见下（公开）
GET    /topics/:id                           详情（公开）
POST   /topics                               发帖
PATCH  /topics/:id
DELETE /topics/:id                           软删除
POST   /topics/:id/pin      /unpin           manager
POST   /topics/:id/close    /open            manager 或作者

GET    /topics/:topic_id/replies             楼层列表（公开，正序分页）
POST   /topics/:topic_id/replies
PATCH  /replies/:id
DELETE /replies/:id
```

`GET /topics` 的 filter：`group_id`（必填）、`category_id` 或 `category_slug`、
`tags`、`search`、`user_id`、`starred_id`、`collection`
（`latest` 默认按 `last_active_mark desc` | `newest` 按 `created_at desc` |
`unanswered` 即 `replies_count = 0`）。

`starred_id` 直接照搬 `events_controller` 已有的写法（从 `comments` 里取
`comment_type: "star"` 的 item_id 子查询），行为一致 —— 但**必须再套一层
`in_visible_categories`**，否则收藏列表会漏出后来变私有的帖（§1.2）。

**所有公开读端点必须 `skip_before_action :authenticate!`**，并在需要个性化时
（`is_starred`、`is_author`）加 `authenticate_optional!`。这是 CLAUDE.md 里明写
的坑：SDK 不带 token 调用的读端点如果不 skip，直接 401。

### Blueprint

- `CategoryBlueprint` — 默认视图即全部字段（表很小），含
  `visibility`；`invited` 名单**不在**默认视图里，走
  `:members` 视图并单独鉴权 —— 名单是一份用户清单，和
  `GroupInvite#receiver_address` 同类，不能顺手渲染出去
- `TopicBlueprint` — 默认视图**不含 `content`**（列表页不需要正文，
  照 `EventBlueprint` 把 `content` 放 `:extended` 的先例）；含
  `category`（用 ref blueprint）、`user`、`last_reply_user`、计数、`is_starred`
- `TopicBlueprint` `:detail` 视图 — 加 `content`、`is_starred`、`can_edit`
- `ReplyBlueprint` — `content` + `user` + `created_at` + `can_edit`
- `CategoryRefBlueprint` — 嵌在 topic 里的轻量形状。按既有约定，
  **另建 ref blueprint，而不是给 category blueprint 加 view**。

---

## 5. 收藏（star）：可以零改动，但有三个但书

`POST /api/v1/comments/star` 现在是：

```ruby
Comment.find_or_initialize_by(user: current_user,
  item_type: params[:item_type], item_id: params[:item_id], comment_type: "star")
```

`item_type` 直接来自参数，**没有白名单**，所以 `item_type=Topic` 立刻就能用。
三个必须处理的问题：

1. **`item_type` 无白名单本身是个缺陷。** 任何字符串都能写进去，`item_type` 之后
   被用来做多态关联和子查询。加论坛之前先把它约束到
   `%w[Event Group Topic]`。这是顺手修，不是新功能。
2. **`unstar` 是 `destroy`（硬删），而 `index` 按 `removed` 过滤**——两套删除
   语义混在一张表上。不改它，但 `stars_count` 的重算必须同时排除
   `removed: true` 和不存在的行。
3. **`stars_count` 要有人维护。** star 写在 `comments` 里，`topics` 看不见它。
   在 star/unstar 后按 topic 重算（`Comment.where(...).count`），和 §1.1 同一
   规则：单点所有权、重算而非增减。

---

## 6. 全文搜索

一期用 `ILIKE` 覆盖标题即可，**不要**一上来就建检索表。

真要做时抄 homeland 的方案而不是引 Elasticsearch：`search_documents` 表
（多态 + `tsvector` 列 + **GIN 索引**），写入前在 Ruby 侧分好词，再
`TO_TSVECTOR('simple', ...)`——用 `simple` 而不是语言配置，正是因为分词已经
外部做完了。以我们的体量，这比维护一套 ES 划算得多。中文分词需要额外的库，
这是届时的主要成本，要单独评估。

---

## 7. 前端（seastar-app）

### 7.1 首页 tab

落点是 `src/app/(normal)/event/[grouphandle]/GroupEventHome.tsx` —— 即
`x-event-home` 命中时首页渲染的那个组件（`(normal)/page.tsx` 里分流）。

**tab 只在 `DISCUSSION && groupDetail.discussion_enabled` 都为真时渲染。**
两者有一个为假就完全不渲染 tab 栏 —— 不是渲染一个禁用态。只有一个 tab 的 tab
栏是视觉噪音，而现在的首页本来就没有 tab 栏。相应地，`?tab=discussion` 在
未开启的 group 上要落回 event（和无法识别的值同样处理），否则分享出去的链接
在关掉功能后会显示空白。

在左侧主内容区（`flex-1 md:max-w-[648px]`）**顶部**加一个两项 tab：
`Event | Discussion`。右侧 328px 边栏（社群信息、日程、banner、场地、建活动、
发徽章、管理入口）**两个 tab 共用，不随切换变化**——它描述的是社群本身，不是
列表内容。

URL 用 `?tab=discussion`，和 group 页 `?tab=members` 的既有写法一致。切换用
`router.replace(..., {scroll: false})`，照 `FormsHub` 刚做过的那套。默认
`event`，任何无法识别的值都落回 `event`（不要显示空白）。

Discussion tab 内部的 filter 行复用 `EventHomeFilter` 的视觉：左侧是
category 横向选择器（相当于现在的 collection 切换），右侧是搜索框。

category 选择器里，私有板块**要有一个锁标记**（`uil-lock`）。看得见它的人本来
就有权限，标记的作用是让发帖的人知道这条会发到哪里 —— 私有板块最常见的事故是
以为在私密处说话、其实在公开处，或者反过来。发帖页的板块选择器同理，并在
选中私有板块时显示一行"仅 X 可见"。

### 7.2 卡片

`CardTopic` 新建，**布局与 `CardEvent` 同构**（`shadow rounded-lg p-3`、
xs 断点下左右翻转、右侧 140×140 图），差异只在内容：

| CardEvent | CardTopic |
|---|---|
| 状态 Badge（Past/Ongoing/…） | 置顶 / 已锁 / 精华 Badge |
| 标题 + EventKindLabel | 标题 |
| tags（彩色圆点，`getLabelColor`） | tags，**同一套配色函数** |
| track | category |
| hosted by … | 作者 + 发帖时间 |
| 日历图标 + 时间 | 回复数 + 最后回复时间 |
| 地点 / 会议链接 | 无 |
| 右侧封面，无图时 default-cover 合成 | 有 `image_url` 才显示；**无图就不占位** |
| 右上角 StarEventBtn | 右上角 StarTopicBtn（同一组件，换 item_type） |

无图不占位这一条要明说：`CardEvent` 无图时会用标题+时间+地点合成一张默认封面，
论坛帖没有时间地点，合成出来是一张只有标题的灰图，不如不占那 140px。

列表**不按日期分组**（`EventListGroupedByDate` 不复用）——论坛的组织维度是
category 和活跃度，不是日期。置顶帖单独一段排在最上。

### 7.3 详情页

路由 `/event/[grouphandle]/discussion/[topicId]`，按既有约定拆
`data.ts` + `page.tsx` + `'use client'` 子组件。

版式与活动详情页同构，去掉报名区、活动信息区、参与者列表，加：正文
（markdown 渲染，与 event `content` 同一套）、回复列表（正序、分页）、
底部回复框（未登录显示登录提示，锁帖显示锁定提示）。右侧保留作者卡片、
收藏按钮、管理操作（置顶/锁帖/删除）。

### 7.4 SDK

新建 `packages/sola-sdk/src/discussion/`（`topic.ts` / `category.ts` /
`types.ts`），从 `index.ts` re-export。所有请求走
`packages/sola-sdk/src/request.ts`，路径相对 `/api/v1`。

**凡是鉴权相关或按人不同的读取，必须 `noCache: true`** —— Next 默认会缓存
`fetch`。列表页匿名可读所以可缓存，但带 `is_starred` 的详情不行。

### 7.5 i18n

`src/lang/en.ts` 和 `zh.ts` **两边都要加**。加之前**先搜一遍 key 是否已存在**
——对象字面量里重复的 key 会被后面那个静默覆盖，`Name` 这个 key 上周刚出过
这个问题（CSV 的"姓名" vs DNS 记录的"名称"）。

---

## 8. 分期

**一期（可上线的最小闭环）**
两级开关（env + `groups.discussion_enabled` + 设置页开关）· 板块 CRUD
（manager）· 板块可见性 `public`/`member`/`manager` · 发帖/编辑/软删 ·
平铺回复 · 列表（category 过滤 + 最新排序）· 详情 · 收藏 · 首页 tab ·
卡片与详情页 UI

`invited` 档（`category_members` 表 + 名单管理 UI）可以推到二期，
但 **`visibility` 列一期就要建，且 scope 从一开始就按 §1.2 的单一 scope 写**。
补一个枚举值是加一行，把散落各处的可见性判断收回一个 scope 是重写。

**二期**
`invited` 板块与名单管理 · tag 过滤与 tag 管理（复用 group 的 `*_tag_list`
形状）· 置顶/锁帖 · 搜索（先 ILIKE）· 通知接入 `activities`（有人回复我的帖，
**注意通知本身会泄漏私有板块的标题**，见 §1.2）

**三期（各自独立评估，不要顺手做）**
@ 提醒 · 浏览量（Redis）· 全文检索（`search_documents` + GIN）·
Markdown 编辑器增强 · 联邦（`topics` 也许该有 `fed_uri`，但联邦分支尚未验证
互操作，先不动）

---

## 9. 明确不做的（以及为什么）

- **不引入 `settings` 表**（homeland 的全局可变配置）。`soon` 的配置在环境变量
  和 `groups` 列上，再加一套会有两个真相来源。
- **不引入 `action-store` gem。** homeland 用一张 `actions` 表统一
  like/favorite/follow/block，设计确实漂亮；但 `soon` 已经用
  `comments(comment_type)` 表达 star 了，两套并存比任何一套单独存在都糟。要统一
  是一次独立的重构，不是论坛的一部分。
- **不做系统事件混入楼层流**（见 §1 replies）。
- **不做楼中楼。**
- **不做跨 group 的全站论坛。** 论坛是 group 的一部分，
  `topics.group_id` 非空。全站聚合视图是以后的事，加 `discover` 端点即可，不用
  改表。

---

## 10. 验证清单（合并回 main 的前置条件）

- [ ] `bin/rails test` 全绿（当前基线 1123 runs / 0 failures）
- [ ] 新增模型/策略/端点各有测试；软删除后的计数重算有专门用例
- [ ] `npx tsc --noEmit` 干净
- [ ] 匿名访问 `GET /topics`、`GET /topics/:id`、`GET /replies` 不 401
      （逐个 curl，不靠"应该没问题"）
- [ ] `DISCUSSION_ENABLED` 未设时，**每一个** discussion 端点都 404
      （逐个 curl；漏掉一个就是绕过全局开关的后门）
- [ ] `groups.discussion_enabled = false` 的 group，其论坛端点 404、
      首页不出 tab、`?tab=discussion` 落回 event
- [ ] 私有 group 的论坛对非成员不可见（curl 验证，不只看策略代码）
- [ ] **私有板块逐路径验证**：§1.2 列的每一条（按 id 直取详情、楼层、搜索、
      收藏列表、按作者过滤、通知）都用一个无权限的 token curl 一遍，
      且返回 404 而非 403
- [ ] 移出 `invited` 名单后，此人立刻看不到该板块的帖（含已收藏的）
- [ ] `groups.can_post_topic` 和 `discussion_enabled` 从设置页保存后**确实
      落库**（permit 列表 + SDK 请求体两处都验）
- [ ] 首页两个 tab 的 URL 前进/后退正常，刷新后停在同一 tab
- [ ] 移动端断点下卡片布局与活动卡片一致
- [ ] i18n 两个语言文件都有，且无重复 key

在以上全部通过之前，`discussion` 分支不合并。
