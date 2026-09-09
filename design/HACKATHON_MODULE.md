# 黑客松模块设计文档

> **状态:已实现(2026-09-09,`hackathon` 分支)。** 与 `poll` 平行的群组内模块。全部决定见 §8。实现与本文的偏差:报名活动选择器列出群组的全部活动(不限 upcoming),黑客松类别的排在最前 —— 报名可能已经在进行中;`judges_team` 一并跳过不是群成员的评委(`TeamMembership` 要求群成员),和无账号的评委一起列在 `skipped` 里。

> **核心结论:黑客松是独立实体,但报名这一半不写新代码。** `hackathons` 是自己的表,一个 group 下多场;每场可以挂一个 `event_id`,报名、审核、签到、名额、付费票全部交给那个 Event 已有的 `Participant` / `Form` / `Ticket` 机制。本模块只新增比赛特有的那一半:**作品与提交**。`events` 表一列不加,Event 模块对黑客松的存在毫无感知。
>
> 参考实现是 `~/zurich/hometown`(一个独立的 Rails 黑客松站点)。它从零写了 form 引擎、participant 表、team 表 —— 在 soon 里这三样有两样已经存在且更完善,所以本文对它的结构大量反对,反对处逐条注明原因。

---

## 0. 复用清单 vs 新增清单

### 已经存在、直接用,不新建

| 需求 | 现成的东西 | 说明 |
|---|---|---|
| 报名表 | `Event.form_id` → `Form`/`FormField`/`FormAnswer` | 8 种字段类型、`required`、`for_admin` 内部字段 |
| 报名动作 | `POST /events/:id/participants` | 已含 `require_approval` 分支 |
| 报名审核 | `POST /participants/:id/approve` / `reject` | `Participant#transition!` 强制合法迁移 |
| 报名状态机 | `participants.status` = attending/pending/declined/maybe/cancelled | 退出后重报复用同一行 |
| 名额 | `events.max_participant` + `SEATED` | 只有 `attending` 占座 |
| 签到 | `participants.checked_in_at` + `check_in` action | |
| 付费报名 | `Ticket` / `TicketItem`(Stripe / 微信 / EVM) | `check_group_ids` / `check_badge_class_id` 可限定购买资格 |
| 答卷查看与导出 | `GET /events/:id/form/submissions` | 已有权限判断 |
| 活动类别 | `events.kind = "hackathon"` | **已存在**(SDK `EventKind`、`eventKinds` 下拉、生产库 8 条),不用加 |
| 评委名单 | `EventRole` 加一个 `judge` 值 | 挂在报名活动上,§2.1;**有一个权限陷阱要先拆** |
| 两开关网关 / 创建档位 / Flaggable / 计数重算 / 双 view / tab 面板 / i18n | discussion / poll | 照抄 |

### 本模块新增

- `hackathons`(比赛本体 + 提交窗口 + 赛道 jsonb)
- `hackathon_projects` + `hackathon_project_members`(**作品即队伍**,§1.2)
- `hackathon_project_stars`(点赞,照抄 Topic 的 star 模式)
- `groups.hackathon_enabled` + `groups.can_create_hackathon`(与 poll 同构)
- 提交窗口的服务端强制(hometown 的 deadline 都是纯装饰列)

### 明确不做

- **不新建报名/参与者/答卷相关的任何表。** hometown 那边 `hackathon_participants` 和 `form_submissions` 各有一个回调写同一个 `registered_count`,互相覆盖;而 `hackathon_participants` 没有在线写入路径,只有 rake 事后回填,`checked_in_at` 永远是 null。**一件事一个权威**,这里的权威是 `participants.status`。
- **不给 `events` 加任何列。** 解耦是硬要求:Event 模块日常改动远多于黑客松,不能让每次改 Event 都要想着黑客松。关联方向只有一个:`hackathons.event_id → events`。
- **不建 `hackathon_tracks` 表。** 赛道是每场比赛三五条、创建后基本不动的配置,放 `hackathons.tracks` jsonb(§1.3)。
- **不复用群组的 `Track`。** `tracks` 是"活动系列"(name 全局唯一、带 start/end date、挂在 `events.track_id`),与赛道同名不同义。
- **不做独立于作品的"队伍"实体。** §1.2。
- **不做评分/评审系统(v1)。** §6。
- **不做提醒/通知。** 没有任何"必须在无请求时发生"的副作用,所以**不新增定时任务** —— `PollAutoCloseJob` 保持是唯一例外。
- **`hackathon_projects` 不用 `SoftDelete`。** 原因在 §1.4,与"一人一作品"的唯一索引直接相关。

---

## 1. 数据结构

```
groups (改动,六处联动见 §7.3)
  + hackathon_enabled      boolean, null:false, default:false
  + can_create_hackathon   string, default:"manager"       -- manager|member|everyone,见 §3.1

hackathons
  id                  string, PK
  group_id            string, FK groups, not null, indexed
  user_id             string, FK users, not null            -- 创建者
  event_id            string, FK events, nullable, UNIQUE   -- 报名用活动,见 §2;DB 级 on_delete: :nullify
  title               string, not null
  tagline             string
  content             text                                  -- 详情(markdown),仅 :detail view
  cover_url           string
  status              string, default:"draft"               -- draft|published,见 §1.1
  start_at / end_at   datetime, nullable                    -- 比赛周期(展示),见 §2 末尾关于与 event 时间的关系
  submit_open_at      datetime, nullable                    -- 作品提交窗口;null = 立即开放
  submit_close_at     datetime, nullable                    -- null = 不关闭
  projects_visibility string, default:"after_submit"        -- always|after_submit|after_review,§3.3
  can_submit_project  string, default:"participant"         -- participant|member|everyone,§3.2
  tracks              jsonb, default:[]                     -- [{id, title, description, color}],§1.3
  projects_count      integer, default:0                    -- 已提交作品数,重算不自增
  flagged_at / flagged_by_id / flag_reason                   -- Flaggable
  deleted_at                                                -- SoftDelete
  created_at / updated_at
  索引:(group_id, status)、event_id unique(where not null)

hackathon_projects
  id             string, PK
  hackathon_id   string, FK hackathons, not null, indexed
  track_id       string, nullable                          -- 指向 hackathons.tracks[].id,应用层校验,§1.3
  user_id        string, FK users, not null                -- 队长,权限判断的唯一权威
  title          string, not null
  tagline        string
  content        text                                     -- 作品说明,仅 :detail view
  cover_url      string
  repo_url / demo_url / video_url  string
  tech           string[], default:[]
  seeking        string[], default:[]                     -- 招募中的角色
  recruiting     boolean, default:false
  submitted_at   datetime, nullable                       -- null = 草稿
  approved_at    datetime, nullable
  rejected_at    datetime, nullable
  review_note    text                                     -- 拒绝理由,给作者看
  award          string, nullable                         -- 获奖名称,自由文本,§6
  stars_count    integer, default:0                       -- 重算不自增
  members_count  integer, default:0                       -- 重算不自增
  flagged_at / flagged_by_id / flag_reason                 -- Flaggable(有);SoftDelete(无,§1.4)
  created_at / updated_at
  索引:(hackathon_id, submitted_at)、(hackathon_id, track_id)、(hackathon_id, recruiting)

hackathon_project_members
  id             string, PK
  project_id     string, FK hackathon_projects, not null
  hackathon_id   string, FK hackathons, not null           -- 冗余自 project,只为下面的唯一索引
  user_id        string, FK users, not null
  role           string, default:"member"                 -- owner|member
  created_at / updated_at
  唯一索引:(project_id, user_id)
  唯一索引:(hackathon_id, user_id)                          -- 一人一场只能在一个作品里,§1.4

hackathon_project_stars
  id, project_id FK not null, user_id FK not null, created_at / updated_at
  唯一索引:(project_id, user_id)
```

**`hackathon_projects.user_id` 与 `role: "owner"` 的冗余是有意的。** hometown 用 `role_label == "队长"`(中文字符串)判断队长,改一次文案就锁死所有人的编辑权。这里外键列是权威,`role` 只服务展示和转让队长,**权限只读 `user_id`**。转让队长 = 一个事务里同时改 `user_id` 和两行 `role`。

### 1.1 状态只有两态

`draft` / `published`。hometown 用四态(`draft/live/reviewing/ended`),其中后两个完全由时间派生 —— 做成手工状态必然出现"时间到了状态没改",且没有任何东西去修。所以 `status` 只回答"组织者是否已放出来",其余派生:

```ruby
def submission_open?
  published? &&
    (submit_open_at.nil?  || submit_open_at  <= Time.current) &&
    (submit_close_at.nil? || Time.current < submit_close_at)
end
```

照抄 `Poll#closed?` 的"查询时派生"哲学,也是本模块不需要 job 的原因。

### 1.2 作品即队伍

一个 `hackathon_project` 自带成员。组队流程:

1. 想组队的人建作品(草稿),勾 `recruiting`,`seeking: ["前端","设计"]`。
2. 作品出现在组队列表(`?recruiting=true`)。
3. 别人 `join`,队长在作品页确认(或队长直接 `add member`)。
4. 提交时 `recruiting` 自动置 false,`submitted_at` 打戳。

省掉的:teams 表、team_members 表、建队页、"提交前必须先选队"的校验(hometown 有),以及"队伍成员与作品成员不一致"这个 hometown 允许但无人处理的状态。

**为什么不复用群组的 `Team`。** `Team` 是"群成员的具名子集":slug 在 group 内唯一、成员必须是群成员、刻意没有 role 列。参赛队要队长、要临时、要在赛后不污染群组织架构,三条都冲突。`Team` 在本模块只可能作为评委名单的引用出现(§6)。

### 1.3 赛道放 jsonb

```json
tracks: [
  {"id": "a3f9k2", "title": "AI 应用", "description": "…", "color": "#7c3aed"},
  {"id": "m8q1zx", "title": "公共物品", "description": "…", "color": "#059669"}
]
```

规则,每一条都是为了让"没有外键"不变成"没有约束":

- **`id` 由服务端生成(短随机串),客户端不可指定、不可修改。** 前端引用赛道永远用 `id`,不用数组下标 —— 重排或删除会让下标漂移。
- `hackathon_projects.track_id` 在 model 里校验:`hackathon.tracks.any? { |t| t["id"] == track_id }`,否则 422。这和 `Poll#eligibility_refs_exist` 的思路一样:一个匹配不到东西的 id 不能静默通过。
- **删除一条被作品引用的赛道 → 422 拒绝**,错误信息带上引用它的作品数。组织者先把作品改赛道、再删。不做"自动把作品置为无赛道",那是静默改动别人的提交。
- 改标题/颜色/描述随时可以,不影响引用。
- 一个作品一条赛道(可空)。hometown 用 jsonb 数组允许跨赛道,评奖时立刻冲突:同一作品是 A、B 两个赛道的第一名吗?
- 不分赛道的比赛 `tracks: []`,前端不渲染筛选。

**代价**:按赛道统计要 `WHERE track_id = ?`,没有 join,反而更快;赛道自身没有独立 URL,也不需要。

### 1.4 一人一场一作品,以及它对删除的影响

`(hackathon_id, user_id)` 唯一索引直接把这条规则放到 DB 层。`hackathon_id` 从 project 冗余到 member 行上,由 model `before_validation` 同步,**没有它这条约束就只能是应用层的**(部分唯一索引不能引用别的表,和 poll 单选的处境一样,但这次多冗余一列就能让 DB 兜底,值得)。

行为:
- 队长把已在别的作品里的人加进来 → 422 `already on a project in this hackathon`。
- 换队 = 先 `leave`(成员自己退)再由新队长加。队长不能 `leave`,只能转让或删除作品。
- 提交后成员列表锁定:加人 422,截止前可撤回提交再调整。

**这条约束决定了 `hackathon_projects` 不能用 `SoftDelete`。** 软删除的作品仍持有成员行,成员就永远无法加入别的作品;而部分索引查不到 `projects.deleted_at`。三个选项里选最简单的:

- 草稿由队长**硬删除**,成员行随之硬删。草稿没有值得保留的历史。
- 提交后的作品作者不能删(截止前可 `unsubmit` 回草稿再删,截止后不行)。
- 组织者处理垃圾内容用 `flag`(隐藏但保留)——成员因此也留在里面无法另组队,**这是刻意的**:被 flag 的作品成员本来就不该换个作品再来一次。

---

## 2. 报名:交给关联的 Event

`hackathons.event_id` 指向一个普通活动。组织者流程:

1. 在群组里建一个活动(日常操作),按需挂报名表(`form_id`)、开审核(`require_approval`)、设名额、挂票。
2. 建黑客松,选择这个活动作为"报名活动"。
3. 参赛者在活动页报名 → `Participant`;组织者在活动的参与者管理页 approve / reject / check_in。

本模块对报名的**唯一新增读法**:`participants.status == "attending"` = 有参赛资格(§3.2)。没有新的写法。

规则:
- **`event_id` 唯一**:一个活动只服务一场黑客松。反过来,一个黑客松只有一个报名活动;开幕式/workshop 这些是普通活动,不需要挂上来。
- **event 必须属于同一个 group**,model 校验。
- **DB 级 `on_delete: :nullify`**。活动被删,黑客松的 `event_id` 变 null,Event 模型不需要 `has_one :hackathon`,一行代码都不用加 —— 这就是解耦的全部含义。**但要接受一个后果**:活动被删后 `can_submit_project: participant` 档位下无人能再提交(§3.2 的校验会在这时给出明确错误,而不是静默把所有人挡在外面)。
- `event_id` 可空:不需要报名的比赛(社群内部、任何成员都能直接提交)不挂活动,此时 `can_submit_project` 只能是 `member` 或 `everyone`(model 校验,§3.2)。
- **黑客松自己的 `start_at/end_at` 与活动的时间是两件事**:活动时间是报名/开幕的时间,黑客松周期是比赛的时间(通常更长)。允许它们不同,这是刻意的双份,不是遗漏。**但 `title/cover/content` 不从活动同步** —— 黑客松有自己的落地页,活动是它的报名入口,两边文案本来就不同。
- **报名活动的 `kind` 用已有的 `"hackathon"`。** 这个值早就在 `EventKind` 和 `eventKinds` 下拉里,生产库有 8 条。前端选择报名活动的控件把 `kind == "hackathon"` 的活动排在前面(不硬过滤,组织者可能先建了活动才想起来改 kind);从黑客松落地页"一键建报名活动"时默认填 `kind: "hackathon"`。**它仍然只是展示标签**,后端任何判断都不读它 —— "这是黑客松的报名活动"这个事实只在 `hackathons.event_id` 上。

### 2.1 评委 = `EventRole` 的 `judge`

评委挂在报名活动上,`EventRole::ROLES` 加一个 `judge`,复用 co_host/speaker 已有的全部机制:按账号或邮箱邀请、无账号的名字也能列、`events_controller` 的 inline 创建路径、`EventRoleInput` 组件。前端在 `EventForm.tsx` 的 "Invite Speakers" 下面加一段 "Invite Judges",活动详情页 speakers 那一栏旁边加 judges —— 三处改动,都是照抄旁边那一段。

**必须先拆的权限陷阱:`EventPolicy#update?` 通过 `event_co_host?` 把任何 `EventRole` 持有者都放成了活动编辑者**(`event_co_host?` 只查 `item_id`/`email`,不看 `role`;注释里说这是刻意的,因为早先按 `role: "manager"` 过滤把所有 co-host 的编辑权都静默收掉了)。现状下 speaker 也能改活动;直接加 `judge` 就等于让评委能改活动、改票、改报名表。所以:

```ruby
# event_policy.rb
# judge 是评审身份,不是主办身份:能被列在活动页上,不能改活动。
EDITOR_ROLES = %w[group_host custom_host co_host speaker].freeze
def event_co_host?(event)
  return false unless user
  scope = event.event_roles.where(role: EDITOR_ROLES).where(item_type: "User", item_id: user.id)
  scope = scope.or(event.event_roles.where(role: EDITOR_ROLES, email: user.email)) if user.email.present?
  scope.exists?
end
```

用白名单而不是 `where.not(role: "judge")`,下一个新角色默认就是无权限的。`TicketItemPolicy#refund?` 已经只认 `co_host`,不受影响。

**另一个连带约束**:`event_roles` 的唯一索引是 `(event_id, item_id, item_type)`,一个人在一个活动上只能有一个角色 —— 既是 speaker 又是 judge 做不到。可以接受:评委和讲者同一个人的时候,列成评委。

**评委在 v1 里只是名单**(落地页展示),不带任何权限;它是 §6 评审系统的入口,现在把名单收好,等评审要做时资格判定直接读 `EventRole.where(event_id: hackathon.event_id, role: "judge")`。

---

## 3. 权限

### 3.1 网关与创建(照抄 PollGate / PollPolicy#create?)

```ruby
# app/controllers/concerns/hackathon_gate.rb
def require_group_hackathon!(group)
  render_not_found unless group&.hackathon_enabled?
end
```

env `HACKATHON_ENABLED` AND `groups.hackathon_enabled`,两层都 404。**必须挡在记录自己的 group 上,不是请求参数里的** —— discussion 和 poll 都记录过这个真实 bug,`set_hackathon` / `set_project` 都要从 `record.hackathon.group` 重新取。

`HackathonPolicy#create?` 照抄 `PollPolicy#create?`,读 `can_create_hackathon`。默认 `manager`,与 poll/topic 的 `member` 不同 —— 办比赛是对外代表社群的事。

### 3.2 三层主体

| 主体 | 判定 | 能做什么 |
|---|---|---|
| 组织者 | `HackathonPolicy#manage?` = 创建者 或 `GroupPolicy#manage?` | 改设置、管赛道、审作品、标获奖、导 CSV |
| 参赛者 | 按 `can_submit_project` 三档 | 建/编辑/提交作品、进队 |
| 旁观者 | 任何人(含未登录) | 按 `projects_visibility` 看作品;点赞需登录 |

```ruby
def can_submit_project?
  return false if user.nil?
  return true  if manage?
  case record.can_submit_project
  when "participant"
    record.event_id.present? &&
      Participant.exists?(event_id: record.event_id, user_id: user.id, status: "attending")
  when "member"   then group_member?(record.group)
  else                 true
  end
end
```

**model 校验:`can_submit_project == "participant"` 时 `event_id` 必须非空**,否则 422 `participant tier needs a registration event`。这条校验在活动被删后(`event_id` 被 nullify)不会追溯触发 —— 所以 `can_submit_project?` 里也显式检查 `event_id.present?`,并且 blueprint 的 `can_submit` 字段让前端能把"报名活动已不存在"直接告诉组织者,而不是让参赛者收到无法解释的 403。

### 3.3 作品可见性与生命周期

```ruby
class HackathonProjectPolicy < ApplicationPolicy
  def show?
    return true if manage_hackathon?                 # 组织者永远可见
    return true if member?                           # 队员永远可见自己的
    return false if record.flagged?
    return false if record.submitted_at.nil?         # 草稿对外不可见
    case record.hackathon.projects_visibility
    when "always"       then true
    when "after_submit" then !record.hackathon.submission_open?
    else                     record.approved_at.present?
    end
  end

  def create?  = can_submit_project?
  def update?  = owner? || (member? && record.submitted_at.nil?)
  def submit?  = owner? && record.hackathon.submission_open? && record.submitted_at.nil?
  def unsubmit? = owner? && record.hackathon.submission_open? && record.submitted_at.present?
  def destroy? = owner? && record.submitted_at.nil?
  def review?  = manage_hackathon?                   # approve / reject / award
end
```

| `projects_visibility` | 含义 | 适用 |
|---|---|---|
| `always` | 提交即公开 | 开放式共建 |
| `after_submit`(默认) | 提交截止后才公开 | 防互相抄 |
| `after_review` | 组织者批准后才公开 | 需要过滤垃圾提交 |

"队员看自己的"和"组织者看全部"是硬例外,与 `PollPolicy` 里管理员对三轴可见性的硬例外同构。

- **`submit?` 里的 `submission_open?` 是服务端强制。** hometown 的 `can_submit?` 只查队长身份和状态,谁都能在结束后继续提交。
- **提交后锁定**,`update?` 从队员收紧到队长;截止前可 `unsubmit` 回草稿,截止后不行。不设宽限期(poll 有,因为首票产生了他人不可逆的行为;作品提交没有)。
- **`after_submit` 下 `submit_close_at` 为 null 意味着作品永远不公开。** model 校验:`projects_visibility == "after_submit"` 时 `submit_close_at` 必填。

### 3.4 PII

答卷 `form_answers.value` 是报名者的真实信息。保护已存在于 `GET /events/:id/form/submissions` 的权限判断里;本模块不新增读取答卷的路径。`HackathonProjectBlueprint` **不得**为显示"队员报名信息"去 join `form_answers`。

---

## 4. 路由与控制器

```ruby
resources :hackathons, only: %i[index show create update destroy] do
  member do
    post :publish / :unpublish
    post :flag / :unflag / :restore
    get  :export                 # 作品 CSV,仅组织者
    # 赛道:整体替换,body { tracks: [{id?, title, description, color}] }
    # 无 id = 新建(服务端发 id);有 id = 更新;缺席 = 删除(被引用则 422)
    patch :tracks
  end
end
# 列表:GET /hackathons?group_id=&status=

resources :hackathon_projects, only: %i[index show create update destroy] do
  member do
    post   :submit
    delete :submit               # unsubmit,截止前
    post   :review               # { decision: "approve"|"reject", note }
    post   :award                # { award: "最佳创意" | null }
    post   :star / delete :star
    delete :leave           # 成员自己退出;没有 join —— 队长直接加减成员
    post   :members              # 队长加人 { user_id }
    delete "members/:user_id"
    post   :transfer             # 转让队长 { user_id }
    post   :flag / :unflag
  end
end
# 列表:GET /hackathon_projects?hackathon_id=&track_id=&recruiting=&status=&sort=stars|newest
```

`tracks` 用"整体替换"而不是逐条 CRUD,和 `PollsController#replace_options!` 同一形状 —— 三五条配置一次 PATCH 比四个端点简单,且删除校验可以在一个事务里做完。

控制器形状对齐 `PollsController`:`skip_before_action :authenticate!, only: %i[index show]` + `authenticate_optional!`,列表走 `render_collection`。`create` 作品时在同一事务里写 owner 成员行并 `refresh_counts!` —— 计数**重算不自增**,成员会退、点赞会取消。

---

## 5. Blueprint 与导出

```ruby
# HackathonBlueprint 默认 view(列表)
:id, :group_id, :event_id, :title, :tagline, :cover_url, :status,
:start_at, :end_at, :submit_open_at, :submit_close_at, :projects_count
field(:submission_open)                            # 派生
association :user, blueprint: UserBlueprint

# :detail
:content, :projects_visibility, :can_submit_project, :tracks
field :can_manage / :can_submit                    # can_submit 含"报名活动已不存在"的情况
field :my_project                                  # 我在这场比赛里的作品 id 或 null(唯一索引保证至多一个)
association :event, blueprint: EventBlueprint      # 默认 view,报名入口用

# HackathonProjectBlueprint 默认 view(作品墙)
:id, :hackathon_id, :track_id, :title, :tagline, :cover_url,
:tech, :seeking, :recruiting, :submitted_at, :award, :stars_count, :members_count
field(:status)                                     # draft|submitted|approved|rejected,派生
association :user, blueprint: UserBlueprint        # 队长

# :detail
:content, :repo_url, :demo_url, :video_url
field :review_note                                 # 仅 owner || manage
association :members, blueprint: UserBlueprint
field :starred_by_me / :can_edit / :can_submit / :can_manage
```

**CSV 导出**:`GET /hackathons/:id/export`,仅 `manage?`,列 `title, track, status, award, owner, members, stars, repo_url, demo_url, submitted_at`。参赛者名单的导出已存在于 Event 侧,不重复。照抄 `PollsController#export` 的原则:宁可 403,不静默降级。

---

## 6. 评审(v1 不做,要做时怎么做)

v1 获奖 = 组织者填 `award` 自由文本 + 公开 `stars_count`。不做评分表。社群内部比赛的评审基本在线下完成,系统只需记录结果;一套完整评审会让表数量翻倍,而它的对错只有比赛当天那几小时能验证。

**要做时骨架已齐**:评委名单 = 报名活动上 `role: "judge"` 的 `EventRole`(§2.1,v1 就收好);打分 = 每个作品一个 `number` 类型的 poll,`results: "manager_only"`,`visibility: "secret"`。缺两样:

- **poll 的资格判定只认 `eligible_group_ids` / `eligible_team_ids`,不认 EventRole。** 决定(2026-09-09):**不改 poll,给评委建一个 `Team`**。组织者从黑客松落地页一键"生成评委 team"——服务端读 `EventRole.where(event_id:, role: "judge")` 里有账号的人,建一个 `archived: false, is_public: false` 的 team 并写入成员;无账号的评委(只有邮箱)进不了 team,页面上列出来提醒组织者。这是一次性快照,不做双向同步:评委名单变了就再点一次,服务端按 slug 找到已有 team 做 diff。poll 侧零改动。
- "N 个 poll 聚合成榜单"这一层读模型。

后者等真有比赛需要再做;前者的"生成评委 team"动作很小,可以随 v1 一起做,也可以等。

---

## 7. 前端(seastar-app)

### 7.1 目录结构(照抄 poll)

```
src/app/(normal)/event/[grouphandle]/
  HackathonPanel.tsx                          # 第四个 tab,client-side fetch
  hackathon/
    create/page.tsx / HackathonForm.tsx       # 建/编共用;含选择报名活动、提交窗口、可见性、赛道编辑
    [hackathonid]/
      data.ts / page.tsx / HackathonDetail.tsx # 落地页:简介、赛道、报名入口(跳活动页)、我的作品
      edit/page.tsx
      projects/
        page.tsx / ProjectGrid.tsx            # 作品墙:赛道筛选 + 热度/最新 + 组队中
        create/page.tsx / ProjectForm.tsx
        [projectid]/page.tsx / edit/page.tsx
```

`GroupEventHome.tsx` 的 tab:`'event' | 'discussion' | 'poll' | 'hackathon'`。

**报名、审核、签到、票务不写新页面** —— 落地页上的"报名"按钮 `router.push` 到活动页。选择报名活动的控件列出本群组 `status: published` 的活动,不新建端点。

### 7.2 SDK:`packages/sola-sdk/src/hackathon/`

```ts
getHackathons / getHackathon / createHackathon / updateHackathon / deleteHackathon
hackathonAction(id, 'publish'|'unpublish'|'flag'|'unflag'|'restore')
updateTracks(id, tracks)
getProjects({hackathonId, trackId, recruiting, status, sort}) / getProject
createProject / updateProject / deleteProject
submitProject / unsubmitProject
reviewProject(id, decision, note) / awardProject(id, award)
starProject / unstarProject
leaveProject / addMember / removeMember / transferOwner
exportProjectsCsv({hackathonId, authToken})   // 照抄 exportPollCsv:token 在 header,不能裸 <a href>
```

### 7.3 `hackathon_enabled` 的六处联动

一处不落,否则是"保存成功但没生效"的静默丢失(`group_params` 的 permit 列表默默丢弃未列字段,本仓库有过真实数据丢失):

| 层 | 位置 |
|---|---|
| Migration | `groups.hackathon_enabled` + `groups.can_create_hackathon` |
| Permit list | `groups_controller.rb` |
| Blueprint | `group_blueprint.rb` 的 `:card` view |
| SDK 类型 | `group/types.ts` 的 `GroupDetail` |
| SDK 请求体 | `group/group.ts` 的 `updateGroup` body |
| 前端开关 | `EditGroup.tsx` 的 Switch 那一排;档位在 `PermissonForm.tsx` |

### 7.4 i18n

紧邻 Poll 那段加扁平 key:`Hackathon` / `Create Hackathon` / `Registration Event` / `Submission window` / `Submissions open` / `Submission closed` / `Projects` / `Submit Project` / `Withdraw Submission` / `Looking for teammates` / `Join Team` / `Leave Team` / `Already in a team` / `Track` / `All Tracks` / `Award` / `Draft` / `Submitted` / `Under review` 等。**先确认 key 不在文件后面已存在** —— 重复 key 被后者静默覆盖。

---

## 8. 已拍板(2026-09-09)

- `hackathons` 独立表,一个 group 多场;`event_id` 可空、唯一、`on_delete: :nullify`,报名全交给该 Event;**`events` 一列不加**。
- `submit_open_at` / `submit_close_at` / `projects_visibility` / `can_submit_project` 都在 `hackathons`。
- 赛道 jsonb,不建表;服务端发 id,删除被引用赛道 422。
- 一人一场一作品:`hackathon_project_members` 冗余 `hackathon_id`,DB 唯一索引;由此作品不用 SoftDelete(§1.4)。
- 不做提醒,不新增 job。
- 不做评审(§6)。
- 报名活动的 `kind` 用已有的 `"hackathon"`,不加新值;`EventRole::ROLES` 加 `judge`,同时把 `EventPolicy#event_co_host?` 收成角色白名单,评委不得编辑活动(§2.1)。
- 评委参与打分时,不改 poll 的资格模型,给评委生成一个 `Team`(§6)。
- `can_create_hackathon` 默认 `manager`,与 poll/topic 的 `member` 不同 —— 办比赛是对外代表社群的事,有意的不一致。
- 作品审核(`review` / `approved_at` / `rejected_at`)保留。只在 `projects_visibility == "after_review"` 下有实际效果,其余两档是内部标记;成本是两个 timestamp 列和一个 action,对外公开的作品墙需要这道闸。

**没有剩余的开放问题,可以开分支。**
