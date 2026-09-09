# 投票模块设计文档

> **状态:已实现(2026-09-09,`poll` 分支)。** §7 的三个待确认问题按文档现状落地:保留 `on_vote`;`secret` 下管理员例外可见;`can_create_poll` 独立于 `can_post_topic`。实现与本文的偏差:`visibility` 在首票之后立即锁定(不享受 10 分钟宽限期)——放宽可见性会暴露别人在更严格承诺下投的票;`vote` 返回完整 detail,前端整体替换状态而不做本地乐观计数。

> 与 `discussion` 模块平行的新模块。设计目标:**最大化复用 discussion 已经验证过的表结构/权限/网关模式**,只在真正需要投票语义的地方(选项、计票、匿名策略)引入新概念。不追求 Loomio 的协商深度,也不追求 Discourse 的计票制度广度——按当前需求(简单、非区块链)做减法。

## 0. 复用清单 vs 新增清单

**直接复用 discussion 的模式(不重新发明):**
- 两开关网关:部署级开关(env)AND 群组级开关(`groups.poll_enabled`),404 不 403 —— 照抄 `DiscussionGate` / `discussion_enabled` / 刚做完的 `map_enabled`
- 创建权限三档位:`groups.can_create_poll`(`manager`/`member`/`everyone`)—— 照抄 `can_post_topic`
- `Flaggable`、`SoftDelete` concern —— 直接 include,零新代码
- 状态用可空 timestamp 字段而非 enum(`closed_at`)—— 照抄 Topic 的 `pinned_at`/`closed_at`/`flagged_at` 哲学
- 计数器"重算不自增"(`refresh_votes_count!`)—— 照抄 `refresh_stars_count!` / `refresh_topics_count!`
- `author?` 用 `!!(...)` 避免可空布尔泄漏到 blueprint —— 照抄 TopicPolicy
- 列表页轻量、详情页带 `content` 的双 view —— 照抄 `Topic` vs `TopicDetail`
- 前端:client-side fetch 的 tab 面板(不做服务端预取,理由同 DiscussionPanel 注释)、`Paginated<T>` 分页、`noCache: true`
- i18n:与 discussion 相同的扁平英文 key 命名,不加 `poll.` 前缀

**新增的投票语义(discussion 没有,不可复用):**
- `PollOption`(选项)、`PollVote`(选票)两张新表——是投票模块唯一必须新增的结构
- 三轴权限模型(见 §3):谁能投 / 谁能看结果 / 谁能看到是谁投的——这是 Loomio+Discourse 都验证过、但当前代码库里没有先例的部分
- 三种投票类型:单选 / 多选 / 数字评分(见 §1.1)
- 首票后的短暂编辑宽限期(见 §1.2)
- 到点自动关闭时触发一次通知(见 §4.1)——这是当前代码库里第一个"纯粹为了触发副作用而不能只在查询时判断"的场景,需要一个真正的定时任务,是对"查询时判断,不需要 job"这条 discussion 惯例的唯一偏离
- CSV 导出(见 §4.2),导出内容受可见性规则约束,不能绕过匿名保护

**明确不做(保持精简):**
- 不做 Category 式的"投票板"分组——一个 group 下所有 poll 平铺,像 Topic 那样按时间排列,不需要再分板块
- 不做排序(ranked-choice)/ STV 等复杂计票制度——支持单选、多选、数字评分三种(见 §1.1),不做投票理论意义上的"名次计票"
- 不做选票版本化审计表(Loomio 的 `stances.latest` 模式)——改票就是原地更新那一行,不留历史
- 不做真正密码学匿名(Shutter/门限加密)——"匿名"只做到"其他成员看不到",数据库里仍是一行普通记录,管理员/DB 层面可查。这是本设计对"精简 vs 强匿名"做的取舍,如果以后有更强的匿名需求需要重新设计
- 不做 Discourse 式的"动态/非动态"选项编辑模式——选项在有人投票后直接锁定,不允许增删改。**这也是为什么不需要 Discourse 的匿名票"按 hash 迁移"机制**:Discourse 允许锁定后仍编辑选项,于是要把旧选项的匿名计数器迁移到新选项(按选项内容 hash 匹配);我们直接锁定、不允许编辑,这个问题从根源上不存在,零新代码
- 不做投票内容的"嵌入式"用法(Discourse 允许一个帖子里嵌多个投票)——poll 是独立顶层资源,不挂在 Topic 回复里
- 不做细粒度的"限定某个 badge 持有者才能投"(Ticket 的 `check_badge_class_id`/`check_group_ids` 模式)——如果以后需要,是在现有三档位上加一层,不影响本设计

---

## 1. 数据结构

```
groups (改动)
  + poll_enabled       boolean, null:false, default:false   -- 群组开关
  + can_create_poll    string,  default:"member"             -- manager|member|everyone

polls
  id            string, PK              -- 与 topics 同款 id 生成方式
  group_id      string, FK groups, not null, indexed
  user_id       string, FK users, not null                   -- 创建者
  title         string, not null
  content       text                                         -- 说明/理由,可空
  poll_type     string, default:"single"                     -- single|multiple|number,见 §1.1
  min_value     integer, nullable                             -- 仅 number 类型使用
  max_value     integer, nullable                             -- 仅 number 类型使用
  visibility    string, default:"public"                     -- public|participants|secret,见 §3
  results       string, default:"always"                     -- always|on_vote|on_close|manager_only,见 §3
  close_at      datetime, nullable                            -- 计划截止时间
  closed_at     datetime, nullable                            -- 实际关闭时间(手动提前关闭或到点关闭时回填)
  first_voted_at datetime, nullable                            -- 首次有人投票的时间,用于计算编辑宽限期(见 §1.2)
  votes_count   integer, default:0                            -- 参与人数,重算不自增
  flagged_at / flagged_by_id / flag_reason                    -- Flaggable
  deleted_at                                                  -- SoftDelete
  created_at / updated_at
  索引:(group_id, closed_at)、部分索引比照 topics 按 deleted_at IS NULL 过滤

poll_options
  id            string, PK
  poll_id       string, FK polls, not null, indexed
  title         string, not null                              -- number 类型不建选项行,此表仅 single/multiple 使用
  position      integer, default:0
  votes_count   integer, default:0                            -- 该选项得票数,重算不自增
  created_at / updated_at

poll_votes
  id            string, PK
  poll_id       string, FK polls, not null
  option_id     string, FK poll_options, nullable              -- number 类型为 null
  value         integer, nullable                              -- 仅 number 类型使用,单个评分值
  user_id       string, FK users, not null
  created_at / updated_at
  唯一索引:
    single / number  → (poll_id, user_id) 恰好一行,改票/改分 = 原地更新
    multiple         → (poll_id, user_id, option_id) 一人可对多个选项各留一行,取消勾选 = 删除该行
```

**为什么不拆"参与记录"和"选票记录"两张表(Loomio 的 AnonymousBallot 思路)?** 因为本设计的匿名不追求"连管理员都不可查",`poll_votes` 单表 + 序列化层控制可见性就能满足"看参与率但不看选了什么"的需求(见 §3),没必要多一张表。如果未来要上强匿名,再引入结构分离,是纯增量改动,不影响现在的表。

**为什么不用两个不同的唯一索引来强制 single/multiple 的差异?** Postgres 的唯一索引无法"按 `poll_type` 条件生效"(部分索引的条件只能引用本表列,查 `poll_type` 要跨表 join)。所以表结构上统一用 `(poll_id, user_id, option_id)` 建唯一索引,「单选只能有一行」这条约束放在应用层(`PollVote` model validation:`poll_type == "single"` 时先删除该用户在此 poll 下的其他行,再写入新行),不是数据库层保证。这是当前设计里唯一一处约束下放到应用层而非 DB 的地方,原因已注明,不是遗漏。

### 1.1 三种投票类型

- **single(单选,默认)**:选一个选项,§2/§3 原有逻辑不变。
- **multiple(多选)**:可勾选多个选项,`poll_votes.votes_count`(参与人数)按"去重后的 `user_id` 数"计算,不等于选票行数;选项的 `votes_count` 就是该选项的选票行数,两者含义分开,序列化时都要注明。
- **number(数字评分)**:不建 `poll_options` 行,投票就是提交一个 `min_value..max_value` 之间的整数到 `poll_votes.value`。结果聚合(平均分、分布直方图)在 `results` 字段里现算现返,不额外建统计表——量级(单个 group 的投票参与人数)不需要预聚合。**前端交互是一个滑杆(slider),不是数字输入框**——`PollDetail.tsx` 对 `poll_type === 'number'` 渲染 `min_value..max_value` 区间的 slider,拖动即乐观更新、松手触发 `votePoll` 提交,不需要用户手动输入数字,体验上更接近"打个分"而不是"填表单"。

三种类型共用同一套 `visibility`/`results` 可见性模型(§3),不因类型不同而改变权限逻辑。

### 1.2 首票后的编辑宽限期

Discourse 的做法是"有票之后还允许在一个可配置窗口内编辑",避免创建者手滑打错字之后永久没法改。采用同样思路,但用一个固定的短窗口而非可配置项(保持精简,不给每个 poll 加一个新设置项):

- `first_voted_at` 记录第一次有人投票的时间。
- 选项/标题的编辑权限:`first_voted_at.nil? || Time.current < first_voted_at + 10.minutes`。
- 超过窗口后完全锁定(不可增删改选项),与原设计一致。
- 这个窗口只影响"编辑",不影响"关闭"或"投票"本身。

---

## 2. 网关与权限(Controller / Policy)

### 2.1 两开关网关(照抄 DiscussionGate)

```ruby
# app/controllers/concerns/poll_gate.rb
def require_group_poll!(group)
  render_not_found unless group&.poll_enabled?
end
```
部署级 env(如 `POLL_ENABLED`)在 `before_action` 里再挡一层,和 discussion 一样两层都是 404。**关键**:必须挡在“记录自己的 group”上,不能挡请求参数里的 group——这是 discussion 模块文档里明确记录过的真实 bug(`set_topic` 的教训),poll 的 `set_poll` 也要照此重新查一次。

### 2.2 创建权限(照抄 TopicPolicy#create?)

```ruby
def create?
  return false if user.nil?
  return true  if manages_group?
  case record.group&.can_create_poll
  when "manager" then false
  when "member"  then group_member?(record.group)
  else                true
  end
end
```

### 2.3 投票权限——比创建更宽松

投票门槛不跟 `can_create_poll` 挂钩,只要是群成员(或管理员)且 poll 未关闭就能投,思路对齐 `ReplyPolicy` 相对 `TopicPolicy` 更宽松的关系:

```ruby
def vote?
  return false if user.nil?
  return false if record.closed?
  group_member?(record.group) || manages_group?
end
```

### 2.4 三轴可见性权限(新增,无先例可抄)

```ruby
# 谁能看到"结果"(聚合票数)
def can_see_results?(user)
  return manages_group? if record.results == "manager_only"
  return true           if record.results == "always"
  return record.closed? if record.results == "on_close"
  # on_vote
  manages_group? || record.voted_by?(user) || record.closed?
end

# 谁能看到"参与名单"(谁投了,不含投了什么)
def can_see_participants?(user)
  return true if manages_group?
  record.visibility.in?(%w[public participants]) && can_see_results?(user)
end

# 谁能看到"每个人投了什么"
def can_see_choices?(user)
  return true if manages_group?
  record.visibility == "public" && can_see_results?(user)
end
```

`visibility` 三态映射用户提出的场景:

| visibility | 参与名单可见 | 各自选了什么可见 |
|---|---|---|
| `public` | ✅ | ✅ |
| `participants` | ✅ | ❌ 只看聚合票数 |
| `secret` | ❌ | ❌ 只看聚合票数 |

自己的投票状态(`my_vote`)不受以上任何一条约束——一个人永远能看到自己投了什么,这是基本可用性,不是"可见性"的一部分。

---

## 3. Blueprint

```ruby
# PollBlueprint(列表 view,不含 content/options)
:id, :group_id, :title, :visibility, :results,
:close_at, :closed?, :votes_count, :created_at
association :user, blueprint: UserRefBlueprint

# :detail view(include_view :card + 以下)
:content
field :options do |poll, opts|
  poll.poll_options.map { |o|
    { id: o.id, title: o.title, position: o.position,
      votes_count: PollPolicy.new(opts[:user], poll).can_see_results?(opts[:user]) ? o.votes_count : nil }
  }
end
field :my_vote { |poll, opts| poll.poll_votes.find_by(user: opts[:user])&.option_id }
field :can_vote { |poll, opts| PollPolicy.new(opts[:user], poll).vote? }
field :can_manage { |poll, opts| PollPolicy.new(opts[:user], poll).manages_group? }
association :voters, blueprint: UserRefBlueprint, if: ->(_, poll, opts) {
  PollPolicy.new(opts[:user], poll).can_see_participants?(opts[:user])
}
```

`voters` 关联本身要不要带 `choice` 字段,由 `can_see_choices?` 单独控制(在关联的 view 层做,而不是整体开关关联)——这是三轴权限落到序列化层的具体做法。

---

## 4. 路由 / 控制器(照抄 topics_controller 的形状)

```ruby
resources :polls, only: %i[index show create update destroy] do
  member do
    post :vote      # body: { option_id }  (multiple: { option_ids: [...] }; number: { value })
    delete :vote     # 撤回投票(截止前可撤回,截止后不行)
    post :close       # 创建者/管理员提前关闭
    post :flag
    post :unflag
    post :restore
    get  :export      # CSV 导出,见 §4.2
  end
end
```

`PollsController` 结构对齐 `TopicsController`:
- `skip_before_action :authenticate!, only: %i[index show]` + `authenticate_optional!`
- `index`/`show` 前置 `require_group_poll!`
- `vote` action:`authorize poll, :vote?` → `upsert` 语义(`find_or_initialize_by(poll:, user:).update!(option_id:)`,`poll_type == "single"`/`"number"` 时先清掉该用户其余行,`multiple` 时按 `option_ids` diff 增删)→ 重算 `poll.votes_count` 与相关 option 的 `votes_count`
- `close` action:`authorize poll, :update?`(即 `author? || manages_group?`)→ `update_columns(closed_at: Time.current)`
- 展示层的"是否已关闭"仍然查询时派生(`closed?` = `closed_at.present? || (close_at.present? && close_at <= Time.current)`),`index`/`show` 不因此产生额外维护成本

### 4.1 到点自动关闭 + 通知

单纯"查询时派生 `closed?`"能保证展示正确,但**不会主动发生任何事**——没有请求进来时,`closed_at` 永远不会被真正写入,通知也就永远不会触发。这是本设计里唯一一处必须要有定时任务的地方,不能照搬 discussion/Topic 的"查询时判断,不需要 job"惯例:

- 新增一个低频(如每 5 分钟)的 GoodJob 周期任务:`PollAutoCloseJob`,扫描 `close_at <= Time.current AND closed_at IS NULL AND deleted_at IS NULL` 的 poll,`update_columns(closed_at: close_at)`,然后触发一次通知(复用现有通知发送机制,发给创建者 + 参与投票的用户,内容是"投票已结束,查看结果")。
- 手动 `close` action 不发这个通知(创建者自己点的关闭,不需要通知自己),只有"到点自动关闭"这一种情况触发。
- 任务是幂等的:`closed_at IS NULL` 这个条件保证同一个 poll 不会被重复触发通知。

### 4.2 CSV 导出(注意匿名保护)

导出内容按 `visibility` 收紧,不允许绕过匿名规则:

- `export` action:`authorize poll, :update?`(仅创建者/管理员可导出,导出本身就是一种更强的"查看"能力,门槛比网页端的 `can_see_*` 更高,不单独开放给普通参与者)
- 导出两种粒度,由请求参数 `?by=voter|option` 选择:
  - `by=option`(选项支持率,任何 `visibility` 下都可以导出):每个选项一行,`title, votes_count, percentage`;number 类型导出 `平均分, 中位数, 参与人数`。这一档不暴露"谁投的",secret/participants 下同样允许导出。
  - `by=voter`(每个人的投票):每个参与者一行,`user_id, name, choice, voted_at`。**这一档只有在 `visibility == "public"` 时才允许**——直接复用 `can_see_choices?` 的判断,`secret`/`participants` 下请求 `by=voter` 返回 403,而不是静默降级成聚合数据(降级容易让管理员误以为拿到了明细,实际是聚合,更危险),要求前端在 UI 上直接不显示这个导出选项。
- 两档共享同一个 `authorize`,粒度差异在 action 内部按 `can_see_choices?` 二次判断,不新增 Policy 方法。

---

## 5. 前端(seastar-app)

### 5.1 目录结构(照抄 discussion)

```
src/app/(normal)/event/[grouphandle]/poll/
  data.ts / page.tsx / PollPanel.tsx        # 列表 tab,client-side fetch
  [pollid]/data.ts / page.tsx / PollDetail.tsx
  create/page.tsx / PollCreateForm.tsx
```

### 5.2 SDK:`packages/sola-sdk/src/poll/`

```ts
// poll.ts
getPolls / getPoll / createPoll / updatePoll / deletePoll
votePoll(pollId, optionId) / retractVote(pollId)
pollAction(pollId, action: 'close'|'flag'|'unflag'|'restore', reason?)

// types.ts
type PollVisibility = 'public' | 'participants' | 'secret'
type PollResults = 'always' | 'on_vote' | 'on_close' | 'manager_only'
interface PollOption { id, title, position, votes_count: number | null }
interface Poll { id, group_id, title, visibility, results, close_at, closed, votes_count, user, created_at }
interface PollDetail extends Poll { content, options: PollOption[], my_vote: string | null, can_vote, can_manage, voters?: UserRef[] }
interface PollDraft { title, content, visibility, results, close_at, options: string[] }
```

### 5.3 `poll_enabled` 的六处联动(严格照抄 map_enabled 模板,一处不落就是"保存成功但没生效"的静默丢失)

| 层 | 位置 |
|---|---|
| Migration | `groups.poll_enabled` + `groups.can_create_poll` |
| Permit list | `groups_controller.rb` 的 `params.require(:group).permit(...)` |
| Blueprint | `group_blueprint.rb` 的 `:card` view |
| SDK 类型 | `group/types.ts` 的 `GroupDetail` |
| SDK 请求体 | `group/group.ts` 的 `updateGroup` body |
| 前端开关 UI | `group/[handle]/edit/EditGroup.tsx`,`Switch` 组件,同 discussion/map 那一排 |

### 5.4 投票交互组件

按 `poll_type` 分三种渲染:
- **single**:选项渲染为单选(radio 语义,不是 `StarDiscussionBtn` 的 toggle 语义)——点击已投的选项 = 触发 `retractVote`,点击其他选项 = 触发 `votePoll` 换票。
- **multiple**:选项渲染为多选(checkbox),每次勾选/取消单独调用 `votePoll`/`retractVote`,不做"提交按钮攒一批再交"的设计,交互上跟 single 保持一致的即时反馈。
- **number**:渲染为 `min_value..max_value` 区间的滑杆(slider,见 §1.1),拖动即乐观更新本地显示值,松手(`onChange`/`pointerup`)才真正调用 `votePoll` 提交,避免拖动过程中打满请求。

三种类型共享同一套乐观更新规则:`my_vote` 永远即时反显;各 option 的 `votes_count`(或 number 类型的聚合统计)只有在 `can_see_results` 为真时才做乐观更新,否则不动展示的票数。未登录点击 → 跳 `/signin?return=...`,照抄 `StarDiscussionBtn`。

### 5.5 i18n

在 `en.ts`/`zh.ts` 里紧邻 Discussion 那一段加一组扁平 key:`Poll` / `Create Poll` / `Vote` / `Votes` / `Change Vote` / `Retract Vote` / `Close Poll` / `Poll closed` / `Results` / `Who can see this poll's results` / `Everyone` / `Participants only (who voted, not what)` / `Only me` 等,en/zh 逐条对齐,没有自动校验工具,需要人工核对(discussion 模块也是这个状况,风险已知)。

---

## 6. 与已有模块的边界

- **不并入 discussion**:poll 不是 Topic 的一种 `content_type`,也不挂在 Topic 下面——用户要求"平行模块",且 Topic/Reply 的扁平评论语义和"选项+计票"语义不同,硬塞进同一张表会让 `TopicPolicy`/`ReplyPolicy` 里再叉出一堆 `if poll?` 分支,违反"每个事实只在一个地方"的原则。
- **poll 上要不要挂讨论/评论**:v1 不做。如果以后需要"针对某个投票展开讨论",做法是允许 Topic 可选关联一个 `poll_id`(在 discussion 侧加一个可空外键,而不是反过来在 poll 侧长出评论树),但这是后续扩展,不在本次范围。
- **与 Ticket 的 `check_badge_class_id`/`check_group_ids` 模式的关系**:如果以后要做"仅限持有某 badge 的人投票",在 `polls` 表上加同名字段、在 `PollPolicy#vote?` 里多一层 `check` 即可,是纯增量,不影响本设计的核心表结构。

---

## 7. 已确认的决定 / 仍待确认的问题

**已确认(本轮讨论已拍板,不再是开放问题):**
- 支持多选(`multiple`)和数字评分(`number`),不只是单选——见 §1.1,`poll_votes` 唯一索引和计数逻辑已按此调整。
- 首票后给一个 10 分钟编辑宽限期(§1.2),而不是投票即永久锁定。
- 到点自动关闭需要真正触发一次通知,为此新增一个周期性 `PollAutoCloseJob`(§4.1),这是唯一偏离"查询时判断、不需要 job"的地方。
- 支持 CSV 导出,分"选项支持率"和"每人投票明细"两档,后者受 `visibility == "public"` 限制,不允许在 secret/participants 下绕过匿名保护(§4.2)。
- 不做投票的"嵌入式"用法,poll 维持独立顶层资源。

**仍待确认:**
1. **`results: on_vote` 的语义是否需要?** 会引入"投完才看结果"的心智,增加一个状态分支。如果用不上,可以先去掉,只留 `always`/`on_close`/`manager_only` 三档,更简单。
2. **`visibility: secret` 要不要允许管理员例外查看?** 当前策略里 `manages_group?` 对三个 `can_see_*` 都是硬性放行——如果希望"连管理员都看不到具体选择"(更接近 Loomio 的强匿名),需要把 `manages_group?` 从 `can_see_choices?` 里去掉,但那样管理员也没法核实作弊投票,也没法用 CSV 导出核实(§4.2 的 `by=voter` 档也会对管理员一并关闭),需要取舍。
3. **`groups.can_create_poll` 是否需要独立于 `can_post_topic`,还是干脆共用一个"谁能发内容"的档位?** 当前设计是独立字段,更灵活但多一个设置项;如果两者总是配置成一样的值,可以合并。

请确认以上结构和剩余开放问题后再开始实现。
