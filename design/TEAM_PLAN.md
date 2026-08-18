# Team — 功能设计

Status: **实现中**（2026-08-17）。分支 `team`（`soon` 与 `seastar-app` 各一条），
**验证完成前不合并**。

一句话：**Team 之于 group 成员，等于 Track 之于 event** —— 把一个 group 的成员
分组，既是一种身份标识，也是以后其他功能可以挂靠的分组维度。

---

## 0. 五个已定的结论

1. **Team 属于 group，不是全站概念。** `teams.group_id` 非空，和 `tracks`、
   `categories` 一样。
2. **一个人可以在多个 team 里**，所以是 `team_memberships` 关联表，不是
   `memberships.team_id`。
3. **Team 内部没有角色。** 需求是"给每个人赋予一个或多个 team 的角色"——
   **team 本身就是那个角色**。`TrackRole` 有 `member/organizer/admin` 三档，
   这里不抄：一旦有了 team 内角色，"谁能改 team 成员"就有了第二个真相来源，
   而它已经由 `GroupPolicy#manage?` 回答了。真需要时再加一列比拆掉容易。
4. **进 team 必须先是 group 成员。** team 是对 group 成员的分组，模型层校验，
   并且**退出 group 时自动清掉 team 成员资格** —— 否则会留下一批"不在社群里
   却还挂着社群身份"的行。
5. **Team 取代 discussion 的 `category_members`。** 私有板块从"指定一批人"
   改成"指定一个或多个 team"。见 §3。

---

## 1. Schema

### `teams`

```ruby
create_table :teams, id: :string do |t|
  t.string   :group_id,     null: false
  t.string   :name,         null: false          # 展示名，可中文
  t.string   :slug,         null: false          # URL / 筛选参数，小写
  t.string   :description
  t.string   :color                              # 徽标底色，可空
  t.integer  :sort,         null: false, default: 0
  t.integer  :members_count, null: false, default: 0
  t.boolean  :archived,     null: false, default: false
  t.timestamps
  t.index [:group_id, :slug], unique: true
  t.index [:group_id, :sort]
end
```

`slug` **在 group 内唯一而非全局唯一** —— 这一点刻意不抄 `tracks`，那里
`t.index ["name"], unique: true` 是全局唯一，意味着两个社群不能各有一个叫
`core` 的东西。对 team 来说那是明显错误的约束。

`color` 可空：给了就用，没给就由 `getLabelColor(name)` 推导，和 tag / track 的
上色方式一致。

### `team_memberships`

```ruby
create_table :team_memberships, id: :string do |t|
  t.string :team_id, null: false
  t.string :user_id, null: false
  t.timestamps
  t.index [:team_id, :user_id], unique: true
  t.index :user_id
end
add_foreign_key :team_memberships, :teams
add_foreign_key :team_memberships, :users
```

没有 `role` 列，理由见 §0.3。

`members_count` 由 `Team#refresh_members_count!` 单点维护、重算而非增减——和
`categories.topics_count`、`topics.replies_count` 同一条规则。

### 改动的现有表

**`categories.visibility`**：`invited` 改名为 `team`。
**`category_members` 表删除**，代之以：

```ruby
create_table :category_teams, id: :string do |t|
  t.string :category_id, null: false
  t.string :team_id,     null: false
  t.timestamps
  t.index [:category_id, :team_id], unique: true
end
```

`categories` / `category_members` 都**尚未部署到任何环境**（`main` 已合并但没
deploy），所以这里是直接删表改值，不需要数据迁移。这是唯一能这么做的窗口。

---

## 2. 权限

> 全局的权限模型见 `design/PERMISSIONS.md` —— 那份是现状记录，本节只讲 team。

- 建 / 改 / 删 team、增删 team 成员：`GroupPolicy#manage?`
  （group 的 manager / owner，platform admin；**父 group 的管理员不算** ——
  与 2026-07-29 的收窄一致，见 `GroupPolicy` 注释）
- 看 team 列表与成员的 team 标签：能看到该 group 成员名单的人
  （`GroupPolicy#members?`：成员或管理员）

Team **不是**权限来源。它是身份标识和分组维度；唯一让 team 影响可见性的地方是
discussion 的私有板块（§3），而那是板块在引用 team，不是 team 在授权。

---

## 3. 与 discussion 的关系

`categories.visibility` 四档变成：

| 值 | 谁能看 |
|---|---|
| `public` | 任何人 |
| `member` | 该 group 的成员 |
| `manager` | 该 group 的 manager / owner |
| `team` | 该板块关联的一个或多个 team 的成员 |

外加一条在实现时被验证清单逼出来的规则：**manager / owner 看得见本 group 的
每一个板块，无论 visibility。** 一个板块唯一关联的 team 被删除后，它匹配不上
任何一条分支——帖子还在，却没人能再打开它，包括唯一有权修复它的人。

比原来的 `invited` 好在：**名单有名字**。原方案里"谁能看这个板块"是一串没有
含义的用户 id；现在它是"核心团队"或"志愿者"，而且这批人的定义在别处也能复用。

维护成本也低一档：把人加进 team 一次，他就获得了所有该 team 可见的板块，而不是
每个板块各加一次。

`Category.visible_to` 的 `team` 分支：

```ruby
teamed = TeamMembership.where(user_id: user.id).select(:team_id)
... .or(scope.where(visibility: "team", id: CategoryTeam.where(team_id: teamed).select(:category_id)))
```

---

## 4. API

```
GET    /teams?group_id=              该 group 的 team 列表（成员可见）
POST   /teams                        建 team（manager）
PATCH  /teams/:id
DELETE /teams/:id                    有成员也可删——见下

GET    /teams/:id/members            team 成员
POST   /teams/:id/members            加人（manager），body: {user_id}
DELETE /teams/:id/members/:user_id
```

**删 team 允许有成员**，与"有帖的板块不能删"相反。理由：删掉一个 team 只是取消
一种分组，成员本身、成员的 group 身份都还在，没有孤儿数据；而板块被删会让帖子
的 `category_id` 无处可指。删除时级联清掉 `team_memberships` 和
`category_teams`，被引用的私有板块会退化成"没有关联 team"——所以 UI 上要警告
这一点。

`MembershipBlueprint` 默认视图加 `teams`（用 `TeamRefBlueprint`：id / name /
slug / color）。成员名单是**一次请求返回全量**的（`GroupBlueprint#detail` 内嵌
memberships），所以筛选在前端做，不需要新端点——和现有的按名字搜索同一处。

⚠️ 这会给每个 membership 增加一个关联。`GroupBlueprint` 的注释里记着一次教训：
把 memberships 全量内嵌曾让首页响应到 726KB。所以 `MembershipBlueprint` 的
teams 必须是 ref 形状，且查询必须 `includes(:teams)` —— 2407 个 membership 各
查一次 team 就是 2407 次查询。

---

## 5. 前端

**创建与管理**：`/event/[grouphandle]/teams`，从 group setting 页进入（与
Venues / Event Programs 并列）。列表 + 新建 + 编辑 + 成员增删。

**成员名单**：`/group/[handle]?tab=members`
- 每个人名字后面显示其所属 team 的彩色小徽标
- 顶部加一行 team 筛选 chip（"全部" + 每个 team），与现有的搜索框并存，
  两者是 AND 关系
- 筛选在客户端做，因为名单本来就是全量拿到的

---

## 6. 分期

**一期**：teams CRUD、成员增删、成员名单展示与筛选、discussion 私有板块改用
team。
**以后**：team 作为 event 的协作者分组、team 专属日程、按 team 群发邮件 ——
都不在这次范围内，但 schema 不需要再改。

---

## 7. 验证清单（合并前）

- [ ] `bin/rails test` 全绿
- [ ] `npx tsc --noEmit` 干净
- [ ] 非 group 成员不能被加进 team（模型层拒绝）
- [ ] 退出 group 后 team 成员资格自动消失
- [ ] 非管理员不能建 / 改 / 删 team，也不能增删 team 成员（403）
- [ ] `team` 可见性的板块：team 成员看得到，非成员 404
- [ ] 删 team 之后，引用它的板块不再对任何人可见（除管理员）
- [ ] 成员名单接口没有 N+1（查询数与成员数无关）
- [ ] 成员名单页 team 徽标与筛选正确，与搜索框可叠加
