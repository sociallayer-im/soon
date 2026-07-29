# sails → soon 生产迁移记录

**执行日期**：2026-07-29 ~ 07-30
**切换完成**：2026-07-29 18:39 UTC
**写冻结时长**：4 分 45 秒（18:02:25–18:07:10 第一次尝试，中止）+ 21 分钟（18:18:10–18:39 正式）
**结果**：成功。`api.sola.day` 由 soon 服务，数据校验 38 项全通过，零数据丢失。

本文是迁移的完整记录，重点在**故障根因和教训**——那是国内站（juluo.xyz）、
sola-event-dashboard、sola-cli 后续迁移时真正用得上的部分。
执行前的方案见 `MIGRATION_PLAN.md`（该文档在执行过程中被持续标注，
是工作记录；本文是可独立阅读的结论）。

---

## 1. 这次迁移为什么不是 dump/restore

sails（Rails 7.2）和 soon（Rails 8.1）不是同一个数据库的两个版本，而是两套 schema：

| 维度 | sails | soon |
|---|---|---|
| 主键 | 整数自增 | TSID 字符串（13 字符） |
| 表数量 | 60 | 34 |
| 用户表 | `profiles` | `users`，且做身份合并 |
| 路由前缀 | 根路径 `/event/create` | `/api/v1/` |

所以数据迁移必须走 ETL（`script/migrate_from_sails.rb`），它为每张表建立
`{旧整数id => 新TSID}` 的映射，再据此重写所有外键。ETL 还硬性拒绝远程目标
（检测到 host 或 `DATABASE_URL` 即中止），因为它会 TRUNCATE 目标表——
这个保护是对的，代价是 ETL 只能在本地跑，结果再导入生产。

**身份合并**：源库里有 66 个 `profiles` 行与更早的行共享 email/钱包/用户名/手机号。
soon 的唯一索引不允许它们共存，ETL 保留最早的一条作为幸存者，并把所有指向
重复身份的外键重定向过去。这也是 `participants` 少 19 行、`event_roles` 少 20 行的原因
（同一个人通过两个身份报名了同一个活动，合并后成为真正的重复）。

---

## 2. 时间线

### 准备阶段（07-29 白天 ~ 18:00）

| 内容 | 结果 |
|---|---|
| soon legacy token 兼容 | 10 个测试 |
| sails `MIGRATION_FREEZE` 冻结开关 | 4 个测试，基线对比确认零回归 |
| 校验脚本 `verify_migration.rb` | 38 项检查 |
| 前端分支合并 + `before-migration` 备份 | 两仓库均已 push |
| `soon/ginger.yml` + secret 映射 | 5 个 secret 逐项校验一致 |
| PlanetScale 建 `sola_soon_db` | 空库 |
| Cloudflare `soon-api` CNAME | 生效 |
| 全链路演练（真实生产数据） | 38 PASS / 0 FAIL，约 4 分钟 |
| soon 部署到 soon-api.sola.day | 冒烟通过 |

### 第一次切换尝试（18:02–18:07）— 中止并回滚

冻结 → dump → ETL → 本地校验全部成功（38 PASS），但导入 PlanetScale 时
**连接槽耗尽**。立即解冻恢复服务，生产未受影响。详见 §3.2。

### 第二次切换（18:18–18:39）— 成功

| 时刻 UTC | 步骤 | 耗时 |
|---|---|---|
| 18:18 | 开冻结（写 503 / 读 200） | — |
| 18:19 | 生产 `pg_dump` → 本地 | 19 秒 |
| 18:19 | restore 到本地镜像库 | 4 秒 |
| 18:19–18:20 | ETL | 32 秒 |
| 18:20 | 本地校验 | 38 PASS / 0 FAIL |
| 18:20–18:21 | 重建并导入 `sola_soon_db` | 44 秒 |
| 18:21 | 对生产库校验 | 38 PASS / 0 FAIL |
| 18:22 | sails 释放 `api.sola.day` | — |
| 18:23 | soon 接管 `api.sola.day` | — |
| 18:24–18:38 | 前端镜像构建 + 部署 | **14 分钟** |
| 18:39 | 生产冒烟 | 全绿 |

### 切换后修复（19:00–20:00）

- 旧整数 ID 链接 404（8 个活动）→ `find_by_id_or_legacy!`
- `/group/icalendar` 日历订阅 404 → 兼容路由

---

## 3. 事故与根因

### 3.1 `WEB_CONCURRENCY=1` 导致所有数据库请求永久挂起

**现象**：soon 首次部署后 `/up` 返回 200，但**所有碰数据库的端点无限挂起**——
不发 SQL、不报错、不超时。`pg_stat_activity` 显示只有 GoodJob 的 2 个 idle 连接，
容器内 `psql` 直连数据库秒回。日志停在
`Processing by Api::V1::EventsController#index` 之后就没有下文。

**根因**：Puma 把 `WEB_CONCURRENCY` 的**任何值——包括 `"1"`——都当作要求 cluster 模式**。
Rails 8 的 `config/puma.rb` 里没有 `workers` 指令，注释明确写着"只在你想要
2 个或更多 worker 时才设这个值，默认已经是 1"。我为了省内存设了 `WEB_CONCURRENCY=1`，
反而把 Puma 推进了 cluster 模式。

而 GoodJob 是 `execution_mode :async` 进程内运行，cluster 模式下它的调度器和
LISTEN 连接在 **fork 之前**的 master 进程里启动，fork 出的 worker 随后在第一个
碰数据库的请求上永久卡死。启动日志里 Puma 自己就警告了：

```
[20] ! WARNING: Detected running cluster mode with 1 worker.
[GoodJob] [20] GoodJob 4.19.2 started scheduler ...
[20] - Worker 0 (PID: 39) booted
```

**修复**：删掉 `WEB_CONCURRENCY`，不设即为 single 模式。

**最重要的教训**：`/up`（Rails 默认健康检查）**不碰数据库**，所以全程返回 200，
**Nomad 健康检查一直是绿的**——编排系统对这个故障完全不可见。
健康检查至少要碰一次数据库，否则这类故障只能靠人肉发现。

### 3.2 连接槽耗尽，第一次切换窗口中止

**现象**：`pg_restore -j 4` 报
`FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute`。

**根因**：PlanetScale 实例 `max_connections = 25`，减去 3 个 superuser 保留后
**只有 22 可用**。当时分布：`loop_prod` **10（全部 idle）**、后台 9、
`sola_sails_db` 5、`postgres` 2、`sola_soon_db` 2、`pscale_exporter` 1。
`-j 4` 再要 4 个直接打爆。

这是**"在 sails 现有实例上 `CREATE DATABASE`"这个选择的代价**——
连接预算是整个实例共享的，包括正在服务线上流量的 sails 库。
方案讨论时我把风险描述成"抢 IO 导致延迟尖峰"，实际更硬：是会直接报错的硬上限。

真正的阻塞点不是导入（`-j 1` 单连接就能过），而是**切换后的稳态容量**：
soon 承接全量流量需要约 6 个连接，加 sails 5、`loop_prod` 10、系统 3 ≈ 24 > 22。

**解决**：`loop_prod` 是 Elixir/Phoenix 应用，Ecto 的 `pool_size` 默认就是 10，
在启动时一次性建满并靠定时保活维持。采样确认那 10 个连接完全同步地每 2 秒
变一次状态、其中 9 个的 `query` 始终为空——**从未跑过应用查询**。
`config/runtime.exs` 已经是 `System.get_env("POOL_SIZE")` 驱动的，
所以加个环境变量 `POOL_SIZE=3` 即可，无需改代码，释放 7 个槽。
同时把 soon 的 `GOOD_JOB_MAX_THREADS` 从 3 降到 1（异步任务只有事务性邮件），
连接池 8 → 6。（该应用随后被整体下线，但这个设置仍然有效且仍然正确。）

**处置得当的地方**：发现问题后**立即解冻恢复服务**，没有让线上冻着等排查。
第一次窗口的真实影响是 4 分 45 秒的写冻结，凌晨低谷，可忽略。

### 3.3 首页 726KB / 9–10 秒（sails 同页面 16KB / 0.73 秒）

**根因有两层**：

1. `GroupBlueprint` 的 `:detail` 视图走 5 个关联（parent/children/tracks/venues/memberships），
   而 `discover` 的查询没有 `includes` → 每条记录 N+1。跨网络的数据库，
   这就是上百次往返而不是毫秒。
2. 更根本的是 `:detail` 把每个 popup city 的**完整成员名单**塞进了首页：
   21 个 group 共 **2407 条 membership**（单组最多 712），而前端的
   `toPopupCity` 只读 10 个标量字段，一条都没用。

**修复**：把 `:detail` 拆成 `:card`（纯标量）+ `:detail`（`include_view :card` + 关联），
`discover` 用 `:card`，`groups#show` 保留 `:detail` 但走 `Group.with_detail_associations`。

**结果**：726KB → 62KB，9–10.7 秒 → 0.92 秒。

**教训**：为"详情页"设计的序列化视图不能直接用在列表上。这个 bug 在本地测试里
永远不会暴露——测试数据每个 group 只有几个成员。

### 3.4 旧整数 ID 链接全部 404

**现象**：切换后 15 分钟的日志里，81 个非健康检查请求中有 24 个 404，
其中 **9 个是不同的整数 ID 活动查询**（`/api/v1/events/11399` 等）。

**根因**：这些是真实用户在点切换前生成的链接——书签、分享出去的消息、
搜索引擎结果。整数永远不可能匹配 TSID 主键。

**修复**：`ApplicationRecord.find_by_id_or_legacy!` 先按 TSID 查，
失败后**仅当标识符全为数字**时回退到 `ref_id`（迁移时保留的旧整数）。
全数字的标识符本身不可能是 TSID，所以回退无歧义；额外那次查询走 `ref_id`
的部分索引，且只在 legacy 路径上发生。迁移后新建的记录 `ref_id` 为 NULL，
不会被数字命中。已接入 events / badges / badge_classes / vouchers 和日历订阅。

### 3.5 `/group/icalendar` 日历订阅失效

**为什么这条比其他旧路由更严重**：订阅 URL 存在用户的 Apple Calendar /
Google / Outlook 里，**发出去就再也改不了**，所以这条路径需要长期保留而不只是
过渡期兼容。而且它是**静默失败**的——订阅者只会看到日历悄悄不再更新，
永远收不到任何错误提示，也就永远不会有人来报。
日志里那次 404 是唯一的发现途径。

**修复**：路由挂在 `/api/v1` 命名空间之外（订阅 URL 就长在那个位置），
接受 sails 原来的 `group_name`（slug）和 `group_id`（整数）两种参数，
输出与 `/api/v1/groups/:id/calendar.ics` 逐字节相同（有测试断言，防止两条路径漂移）。

UID 仍用 soon 的 `event-<tsid>@host` 而非 sails 的 `sola-<整数>`：
订阅日历是整份 feed 同步的，换 UID 只会让客户端替换一次条目，
这比为同一批活动长期维持两套 UID 方案要好。

**验证**：修复后日志里出现真实 Apple 日历客户端（UA `macOS/dataaccessd`）
拿到 200。

### 3.6 前端镜像没有预先构建（流程缺陷）

18:24–18:38 这 **14 分钟**里，`api.sola.day` 已经是 soon，
而 `app.sola.day` 上跑的还是对着 sails API 写的旧前端——这段时间前端是坏的。

写接口从 18:23 起就可用了，所以**真正的用户可见中断是这 14 分钟的前后端不匹配，
而不是 5 分钟的写冻结**。

**下次怎么做**：窗口开始前先 `ginger deploy` 把前端镜像构建并推送到 registry，
窗口内只做 `--skip-push` 的滚动，可把这段压到 1 分钟以内。

---

## 4. 三项前置改造

### 4.1 Legacy JWT 兼容（防全员登出）

**这是整个迁移里风险最高的一项。** sails 签发的 token payload 是
`{id: <整数>, address_type, hasura claims}` 且**无 `exp`**，
而 soon 的 `authenticate!` 读 `payload["user_id"]`（TSID）。
仅仅让 `JWT_SECRET` 与 sails 的 `JWT_SECRET_KEY` 一致是不够的——
签名能验过，但用户身份解不出来，**所有已登录用户会在切换瞬间被登出**。

`Api::BaseController#user_from_payload` 优先读 `payload["user_id"]`，
缺失时回退到 `payload["id"]` 并按 `User.find_by(ref_id:)` 查。
JWT gem 对无 `exp` 的 payload 不做过期校验，所以旧 token 天然长效，
行为与 sails 一致。

测试覆盖：跨格式认证、无 `exp` 不被拒、错密钥拒绝、`ref_id` 为空的新用户
不会被空 id 命中、`user_id` 优先于 `id`、可选认证降级为匿名。

**生产验证**：用生产 `JWT_SECRET_KEY` 铸造 sails 格式 token（profile id=1），
soon 正确解析为迁移后的用户 `zfd`，TSID、钱包地址、nickname、权限全部吻合。
切换后日志里真实用户的 `/api/v1/users/me` 返回 200。

### 4.2 冻结开关

`ApiController#block_during_migration!` 检查 `MIGRATION_FREEZE`
（未设或 `0/false/no` 即关闭），挂在 sails 的 `EventController` 和
`RecurringController` 的 `create`/`update` 上，返回 503 + `Retry-After: 600`。

**用环境变量而非代码常量**：解冻或回滚时只改 secret 重新提交 job，
不需要重新构建镜像。默认关闭，所以可以提前部署好待命。

**一个 ginger 的坑**：`secrets.inject` 是精确名单且**会校验非空**，
直接写 `MIGRATION_FREEZE` 会让冻结未启用时的每次部署都失败。
改用 glob `"MIGRATION_*"`，缺失时是 no-op。

### 4.3 校验脚本

`script/verify_migration.rb`，只读，双库对照，38 项检查，四段：

1. **行数对照** — 目标行数 = 源行数 − 可独立解释的损失
2. **身份合并可达性** — 每个源 profile 都必须能解析到某个目标 user
3. **去重后精确计数** — participants 和 event_roles 的期望值由 `ref_id`
   映射在内存中精确计算，不是估算
4. **完整性** — 必填外键悬空扫描、6 张表 × 300 行字段级 diff、业务不变量

**刻意不复用 ETL 的 spec**：共享同一套假设的校验器会以同样的方式出错。
预期损失全部从源数据重新推导。这个决定立刻有了回报——第一版脚本报了
4 张表有无法解释的损失，追下去发现根因是
**ETL 的 `req:` 检查作用于映射后的值**，所以源库中"非 NULL 但指向已不存在
父行"的外键，和 NULL 一样会让整行被跳过（本地数据里有 7 行是这种情况）。
预期规则据此改成检查**可解析性**而非是否为 NULL。

---

## 5. 数据结果

生产数据规模与校验结果：

| 表 | 行数 | 说明 |
|---|---:|---|
| users | 34225 | 源 34291，66 个身份合并，**0 人不可达** |
| groups | 453 | |
| events | 18181 | 源 18184，3 行 `group_id` 为 NULL |
| participants | 55424 | 源 55443，19 行因身份合并成为真重复 |
| event_roles | 12705 | 源 13213，244 行 `item_type` 为 NULL + 264 行去重 |
| memberships | 3795 | |
| badges | 3661 | |
| domains | 31303 | |

**所有行数差为 0**（即实际值与独立推导的期望值完全一致），
必填外键 0 悬空，6 张表 × 1800 行字段级 diff 全等，
schema 对象数与本地基准完全一致（36 表 / 152 索引 / 279 约束）。

所有"损失"都是源库既有的数据质量问题（NULL 的必填外键、悬空外键），
或身份合并的正确结果，不是迁移脚本的缺陷。

---

## 6. 最终状态

| 项 | 状态 |
|---|---|
| `api.sola.day` | soon（`/api/v1/` 前缀） |
| `app.sola.day` | seastar-app `ef2a67b` |
| `auth.sola.day` | seastar-auth `808df0e` |
| `soon-api.sola.day` | soon（保留，用于冒烟） |
| `sails-old.sola.day` | sails，保持冻结，回滚通路 |
| 数据库 | `sola_soon_db`（与 `sola_sails_db` 同实例，不同库） |
| 连接占用 | 10 / 22 |
| soon 容器内存 | 268MB / 640MB 上限 |

**回滚边界**：切换后已有用户写入 soon（日志里有报名 201），
**反向 ETL 不存在**——TSID 转不回整数、合并掉的 66 个身份拆不开。
整体切回 sails 等于放弃切换后产生的全部数据。
镜像层面的 `ginger rollback` 仍然可用，那解决的是"soon 新镜像有 bug"，
不是"切回 sails"。

---

## 7. 未做的事与已知遗留

### 未做

**前端主流程从未实测。** 早先一次对抗性审计发现的 17 个前后端集成 bug
至今只经过代码审查。后端在部署过程中连着暴露了三个只有真跑才发现的问题
（§3.1、§3.3、§3.4），前端大概率也有类似的。
建议尽快人工走一遍：登录、建活动、报名、群组管理、徽章、售票。

### 已知并接受

- **juluo.xyz 国内站**：继续跑 sails + `before-migration` 分支前端，后续单独迁移。
  注意 CN 部署（`ginger.cn.yml`）下次部署前要 checkout `before-migration`。
- **sola-event-dashboard / sola-cli**：打 `api.sola.day` 的根路径旧路由会 404，
  后续迁移时一并升级。
- **`/comment/list` 404**：来自切换前打开、尚未刷新的浏览器标签页
  （旧 bundle 调 `/comment/list`，新 bundle 调 `/comments`）。刷新即自愈，不补。
- **`edgepatagonia` 这个 group 的 handle 变了**：sails 按 `handle` 解析公开 URL，
  但 ETL 把 soon 的 `name` 定义成 `username || handle`。全库只有这一个 group
  两者不同（handle `edgepatagonia` vs username `edgpatagonia`，疑似笔误），
  于是它的旧链接 404。该 group 有 1007 个活动。
  修法是一条 `UPDATE groups SET name='edgepatagonia' WHERE ref_id='3635'`，
  经判断影响不大，决定不修。
- **未迁移的 sails 表**（votes、points、orders、estores、map_checkins 等 26 张）
  数据留在旧库，soon 无对应功能。

### 观察期建议

sails 容器和 `sola_sails_db` 保持不动、冻结开关开着，7 天内每日检查
soon 日志、GoodJob 失败任务、内存水位、连接数（应稳定在 ~10/22）。
7 天无恙后再下线 sails 容器（镜像与数据库仍保留）。

---

## 8. 给下次迁移的清单

1. **健康检查必须碰数据库。** `/up` 不碰数据库，导致 §3.1 的故障对编排系统完全不可见。
2. **前端镜像在窗口开始前构建好**，窗口内只做 `--skip-push` 滚动。
3. **先查数据库连接预算**（`max_connections`、每个库的占用、是否共享实例），
   再决定新库建在哪里。共享实例的连接槽是硬上限，不是软性能问题。
4. **不要设 `WEB_CONCURRENCY`**，除非真的要 2 个以上 worker。
5. **列表端点不要用详情页的序列化视图。** 本地测试数据量太小，永远测不出来。
6. **校验脚本不要复用 ETL 的假设**，预期值从源数据独立推导。
7. **旧 ID 和旧路由的兼容要提前想好**，尤其是日历订阅这类
   URL 发出去就改不了、且静默失败的东西。
8. **JWT 兼容不只是密钥对齐**，payload 结构也要能解析。
9. **窗口内出问题先恢复服务**，不要让线上冻着等排查。

---

## 附录 A：本次迁移的提交

**soon**（`sociallayer-im/soon`，本次迁移期间新建的仓库）

```
bb78651  feat: accept legacy sails JWTs during the cutover
b839381  chore: migration tooling and deploy config for the sails cutover
a09c4a4  fix: do not set WEB_CONCURRENCY — it forces Puma cluster mode
89da5ca  perf: eager-load GroupBlueprint's :detail associations
426b940  perf: stop embedding member rosters in the homepage payload
2428a8e  chore: one GoodJob thread — the connection budget is shared and tight
716f3af  chore: soon serves api.sola.day
9b96840  fix: resolve records by the legacy sails integer id
ea07c9d  fix: keep serving the legacy /group/icalendar feed
```

**sails**

```
d71c53e  feat: add MIGRATION_FREEZE kill switch for the soon cutover
ca43fb8  chore: sails releases api.sola.day to soon
```

**前端**：`seastar-app` main=`ef2a67b`（备份 `before-migration`=`8fa4bcf`）、
`seastar-auth` main=`808df0e`（备份 `before-migration`=`7cb5a48`）

**loop-backend**：`6166769 chore: cap Ecto pool at 3`

## 附录 B：Secret 映射（仅变量名）

| sails | soon | 说明 |
|---|---|---|
| `JWT_SECRET_KEY` | `JWT_SECRET` | **必须同值**，否则全员登出 |
| `NEXT_TOKEN` | `NEXT_TOKEN` | **必须同值**，trusted_signin / Stripe 回调共用 |
| `SECRET_KEY_BASE` | `SECRET_KEY_BASE` | 同值 |
| `RESEND_KEY` | `RESEND_API_KEY` | 同值，变量名不同 |
| `CLOUDFLARE_ACCOUNT_ID` | `CLOUDFLARE_ACCOUNT_ID` | 同值 |
| `CLOUDFLARE_IMAGE_API_KEY` | `CLOUDFLARE_IMAGES_TOKEN` | 同值，变量名不同 |
| `DATABASE_URL` | `DATABASE_URL` | **不同**，指向 `sola_soon_db` |
| `AWS_*` / `S3_URL` / `SKYLIGHT_*` / `ALCHEMY_*` | — | soon 不用，未迁 |

## 附录 C：迁移流水线（可复用）

```bash
# 1. 冻结（sails/.env.production 加 MIGRATION_FREEZE=1）
cd sails && ginger deploy --skip-push

# 2. 生产 dump → 本地（约 19 秒 / 67MB）
pg_dump "$SAILS_URL" -Fc -Z 6 --no-owner --no-acl -f cutover.dump

# 3. restore 到本地镜像库（约 4 秒；hypopg 的 2 个报错可忽略）
psql -d postgres -c "DROP DATABASE IF EXISTS sails_prod_mirror" \
                  -c "CREATE DATABASE sails_prod_mirror"
pg_restore -d sails_prod_mirror -j 4 --no-owner --no-acl cutover.dump

# 4. ETL（约 32 秒）
cd soon && SOURCE_DB=sails_prod_mirror bin/rails runner script/migrate_from_sails.rb

# 5. 本地校验（必须 0 FAIL 才继续）
SOURCE_DB=sails_prod_mirror bin/rails runner script/verify_migration.rb

# 6. 导出 stage —— 必须排除 dev 残留数据
pg_dump sails_db_development -Fc -Z 6 --no-owner --no-acl \
  --exclude-table-data=auth_codes --exclude-table-data='good_job*' -f stage.dump

# 7. 重建目标库并导入（-j 1，共享实例的连接槽不够并行）
psql "$SAILS_URL" -c "select pg_terminate_backend(pid) from pg_stat_activity
                      where datname='sola_soon_db' and pid<>pg_backend_pid()" \
                  -c "DROP DATABASE IF EXISTS sola_soon_db" \
                  -c "CREATE DATABASE sola_soon_db"
pg_restore -d "$SOON_URL" --no-owner --no-acl stage.dump

# 8. 对生产库校验（必须 0 FAIL 才切域名）
DATABASE_URL="$SOON_URL" SOURCE_DB=sails_prod_mirror \
  bin/rails runner script/verify_migration.rb

# 9. 域名交接（Traefik 按 Host 规则路由，必须先摘后挂）
cd sails && ginger deploy --skip-push   # proxy.hosts 改为 sails-old.sola.day
cd soon  && ginger deploy --skip-push --tag <已构建的tag>   # 加上 api.sola.day

# 10. 前端（镜像应已预先构建好）
cd seastar-app  && ginger deploy
cd seastar-auth && ginger deploy
```
