# 权限模型

Status: 现状记录，随代码更新（最后核对 2026-08-18，对照
`app/policies/*`、`app/controllers/api/v1/memberships_controller.rb`、
`app/controllers/api/base_controller.rb`）。

这份文档写的是**当前代码真实的行为**，不是设想。每一条都能在上面那几个文件里
找到对应；有过变更的地方注明了日期和原因。

---

## 0. 四个主体

| 主体 | 判定 | 说明 |
|---|---|---|
| **平台管理员** | `users.admin = true`（或旧的 `permissions: ["admin"]`） | **只能在数据库里设**，不在任何 permit 列表中 |
| **owner** | `memberships.role = "owner"` | 一个 group 至少有一个，最后一个不能被移除 |
| **manager** | `memberships.role = "manager"` | 内部与 owner 合称 "group admin" |
| **member** | `memberships.role = "member"` | |

`memberships.role` 的合法值只有 `member | manager | owner`。
`db/schema.rb` 里 `groups` 那些 `can_*` 列的注释写的是
`manager | member | everyone`，那是**权限档位**，与角色名是两套词汇，不要混。

**父 group 的管理员是第五种主体**，见 §2。

### 底层两个判定

```ruby
# ApplicationPolicy
group_admin?(g)  # 该 group 的 manager 或 owner
group_member?(g) # 该 group 的任意成员

# GroupPolicy
manage?(g)       # 平台管理员 || group_admin?(g)      —— 不含父 group 管理员
members?(g)      # group_member?(g) || manage?(g)
```

`!!` 不是装饰：`user&.…` 对匿名访问者返回 `nil`，而这些值会进 blueprint 的
`can_edit` / `can_manage` 字段，客户端类型声明是 boolean —— `null` 和 `false`
不是一回事。

---

## 1. 角色的授予与撤销

一条规则，2026-08-18 定：**加身份谁都可以，去身份只有 owner。**

| 操作 | owner | manager | 父 group manager | member |
|---|:--:|:--:|:--:|:--:|
| 提升 member → manager | ✓ | ✓ | ✓ | ✗ |
| 降级 manager → member | ✓ | ✗ | ✗ | ✗ |
| 授予 / 变更 owner | ✓ | ✗ | ✗ | ✗ |
| 移除一个 member | ✓ | ✓ | ✗ | ✗ |
| 移除一个 manager | ✓ | ✗ | ✗ | ✗ |
| 移除一个 owner | ✓ | ✗ | ✗ | ✗ |
| 自己退出 | ✓* | ✓ | — | ✓ |

\* owner 退出受"最后一个 owner 不能移除"限制。

**为什么降级只有 owner：** 同级之间能互相摘身份，就是一个 manager 清掉其余所有
manager 的路径；而被摘掉的人自己无法恢复。提升是可加的、owner 随时能撤销，两者
不对称。

**移除跟着降级走**（同日）：移除比降级更彻底，如果 manager 能移除 manager，降级
那条规则就形同虚设。

实现在 `MembershipsController#can_change_role?` 与 `#can_remove?`，不在
`GroupPolicy` 里 —— 因为它们是"对某一行"的判断，需要看目标当前的角色。

---

## 2. 父 group 的管理员

`GroupPolicy#can_assign_manager?`。**唯一的能力是把子 group 的一个 member 提升
为 manager**，除此之外对子 group 没有任何权限：不能改设置、不能管场地/track/
徽章/邀请、不能碰 team、不能移除任何人。

- 2026-07-29 从"完整 `manage?`"收窄到"manager 角色的双向切换"，记录在
  `design/CHANGELOG.md`，明确是有意收窄而非疏漏。
- 2026-08-18 再收窄一半：**只剩提升**。降级归 owner，与 §1 同一条规则，不因
  站在哪里而不同。

`GroupPolicy#manage?` **不包含**父 group 管理员 —— 这一点在实现 discussion 时
出过一次错：`Category.visible_to` 曾让父 group 管理员看得见子 group 的私有板块，
而所有管理操作又都拒绝他们，于是能读、不能管。已修正为不可见。

---

## 3. Group 本身

| 操作 | 谁 |
|---|---|
| 看 group、看成员名单 | 任何人（名单是公开端点） |
| 改 group 设置 / 删除 | `manage?` |
| 冻结（下线） | **owner 或平台管理员**，manager 不行 |
| 建 group | 任何登录用户 |
| 邀请成员 | `manage?` |
| 直接加成员（非邀请） | `manage?`；授予 owner 需 owner |

⚠️ `group_params` 用 `params.require(:group).permit(...)`，**不在 permit 列表里
的字段静默丢弃**。这在本仓库造成过真实的数据丢失。加字段必须同时改
`GroupsController` 的 permit 列表**和** SDK 的 `updateGroup` 请求体，两处缺一
都表现为"设置页保存成功但值没落库"。

`PRIVILEGED_TAGS`（`pin` / `top` / `featured`）会从任何非平台管理员的更新里被
剥掉，所以 group 不能自我推荐上首页。

---

## 4. Team

Team **不是权限来源**，它是身份标识和分组维度。唯一让 team 影响可见性的地方是
引用了它的 discussion 板块，而那是板块在引用 team。

| 操作 | 谁 |
|---|---|
| 看 team 列表 | `members?`（成员或管理员） |
| 建 / 改 / 删 team、增删 team 成员 | `manage?`（**不含**父 group 管理员） |

两条模型层约束：

- **进 team 必须先是该 group 的成员**（`TeamMembership` 校验）
- **退出 group 自动退出其所有 team**（`Membership#after_destroy`）——否则会留下
  "已不在社群、却仍带着社群身份、并通过 team 私有板块仍有访问权"的行

### team 徽标的可见性：每个 team 自己决定

`teams.is_public`，**默认 false**。成员名单是公开端点，所以这一列决定 team 名字
是否随名单一起对外。

| 访问者 | 看得到 |
|---|---|
| 匿名 / 非成员 | 只有 `is_public = true` 的 team |
| 该 group 的成员 | 全部 |
| 平台管理员 | 全部 |

实现在 `MembershipBlueprint`，靠控制器传入 `member_group_ids`（每请求解析一次，
不是每行一次）。**任何渲染 membership 的端点都必须传它** —— 漏传是"安全但错误"
（徽标被隐藏），曾导致 group owner 看不见自己的私有 team。

`groups#show` 因此会按访问者个性化，这是安全的：`cache_when_anonymous!` 一旦有
`current_user` 就不写缓存头（匿名 `max-age=30, public`，登录后
`max-age=0, private`）。

前端同样要传 token：`getGroupDetailByName/ById` 的 `authToken` 是可选的，但**凡
是要展示名单的调用都必须传**，否则拿到的是匿名视角。

---

## 5. Discussion

两级开关，AND 关系，任一关闭都返回 **404 而非 403**（功能没上线就该看起来不
存在）：

1. 部署级 `DISCUSSION_ENABLED`（env）
2. group 级 `groups.discussion_enabled`（默认 `false`）

group 级开关必须**对照记录所属的 group 检查，而不是请求参数** —— 只按参数检查
会让所有按 id 寻址的端点在 group 关闭论坛后依然可读可写（实现时的真实缺陷，见
`DiscussionGate`）。

### 板块可见性

| `categories.visibility` | 谁能看 |
|---|---|
| `public` | 任何人 |
| `member` | 该 group 的成员 |
| `manager` | 该 group 的 manager / owner |
| `team` | 关联 team 的成员 |

**外加：manager / owner 看得见本 group 的每一个板块，无论 visibility。** 两个
理由：管理员打不开就无法执行管理操作；而一个板块唯一关联的 team 被删除后，它
匹配不上任何一条分支，帖子还在却没人能再打开它。这也不构成保密边界 —— 管理员
本来就能 PATCH 任意板块的 visibility。

### 帖子与回复

| 操作 | 谁 |
|---|---|
| 看 | 板块可见 **且** 未被 flag（作者与 manager 例外） |
| 发帖 / 回复 | `groups.can_post_topic` 档位 **∩** 板块可见性（取交集） |
| 编辑 / 删除自己的 | 作者 |
| 锁帖 | 作者或 manager |
| 置顶 / 隐藏 / 恢复 / 移动板块 | manager |

可见性是**三层组合，缺一层就是漏洞**：

```ruby
Topic.in_visible_categories(user)  # 板块
     .visible_to(user)             # flag
     # deleted_at 由 SoftDelete 的 default_scope 挡掉，不在这里重复
```

三层刻意不重叠：`deleted_at` 只在一个地方被过滤。所有读路径都必须走这个组合，
包括按 id 直取、楼层、搜索、收藏列表、按作者过滤、通知。

flag 与软删的区别是**给谁看**：被 flag 的内容作者仍看得见并看得到原因（凭空消失
是管理争议的起点）；软删对所有人不可见，包括作者。两者独立，可同时存在。

---

## 6. 端点鉴权的两条硬规则

**公开读端点必须 `skip_before_action :authenticate!`。** SDK 不带 token 调用的
读端点如果不 skip，直接 401。需要按人个性化时再加 `authenticate_optional!`
（它永远不会 401）。

**看不见的东西返回 404，不返回 403。** 403 等于确认"这里有个东西但你看不到"，
对私有板块而言板块名本身往往就是内容。同一条原则适用于关闭的功能开关。

---

## 7. 改这套东西时最容易踩的四个坑

1. **permit 列表**（§3）—— 静默丢弃，表现为"保存成功但没生效"。
2. **`member_group_ids` 漏传**（§4）—— 安全但错误，表现为"我自己的 team 不见了"。
3. **策略返回 `nil` 而不是 `false`** —— `user &&` 对匿名短路成 `nil`，进到
   blueprint 就是 `can_edit: null`，而客户端类型写的是 boolean。
4. **`UserMerger` 忘了新表** —— 加了带 `user_id` 外键的表却没登记，合并账号时
   直接抛 `PG::ForeignKeyViolation` 整个失败；若模型上是 `dependent: :destroy`，
   则更糟：数据被删而不是转移。`team_memberships` 还要注意**顺序**——它必须在
   memberships 去重**之前**转移，否则 `Membership#after_destroy` 会把还没交接的
   行删掉，合并成功而 team 静默消失。
