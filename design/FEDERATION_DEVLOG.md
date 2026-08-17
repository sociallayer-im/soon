# Sola 联邦开发过程记录

> 配套文档：`FEDERATION_PLAN.md`（架构与分期）、`FEDERATION_INTEROP_VERIFICATION.md`
> （互操作验证方案与实测结果）、`FEDERATION_TEST_PLAN.md`（投递可靠性/格式/密码学
> 测试方案）。
>
> 本文档记录**过程**：做了什么、按什么顺序、为什么这么决定、踩到什么、以及
> 下一个人接手需要知道的东西。截至 2026-08-17，代码在两个仓库的 `federation`
> 分支上，**未合并、未上生产**；该分支已 rebase 到当日的 `main`（见 §13）。

---

## 1. 起点

四个参考项目的源码级分析（各派一个 agent 并行读）：

| 项目 | 读出来的结论 |
|---|---|
| **Mobilizon** 5.2.4 | 活动联邦的事实标准。Event 的 JSON-LD 词表、Join/Accept 报名流程、受众规则成为 sola 的直接蓝本 |
| **Mastodon** 4.7 | 互通的**硬性验收标准**。它的校验代码是判定我们对错的预言机 |
| **nebula/nebula** | Rails 原型。可借鉴 URL 生成模块与 S2S 测试架构；**入站签名验证完全没做**（匿名 POST 即可删帖），投递同步无重试 |
| **writefreely** | 最小可互通面的边界。同样不验签、无重试队列 |

两个原型的共同缺陷（不验签、无重试）直接决定了我们的第一条设计原则：**inbox 从第
一天起强制验签，投递从第一天起走 outbox 表 + 队列**。

---

## 2. 分期实施

### Phase 0 — 地基（`a69165e`）
密钥列（AR 加密、惰性生成、行锁保证并发只生成一次）、四张表、三个基础库
（`Urls` / `HttpSignature` / `HttpClient`）。签名负例矩阵与 SSRF 矩阵同批交付。

### Phase 1 — 发现面（`c2ca35b`）
webfinger / host-meta / nodeinfo / actor 文档 / 实例 actor / 事件 AP 视图。
断言全部编码 Mastodon 的接受规则（self link 精确类型串、`id == 请求 URI`、回环）。

### Phase 2 — 联邦层（`6f17fe7`）
inbox 的按成本排序拒绝链、Follow/Accept/Undo、outbox pattern + sweeper + 投递任务、
黑白名单 + 限流 + 结构化日志 + 域级统计 + 熔断。

**这里有一条刻意的排期决定**：治理与观测必须和 inbox **同批**上线，不留裸奔窗口。

### Phase 3 — 报名与评论（`d0486c6`）
远端参与者复用 `participants` 表（加列而非新表，让容量检查与审批 UI 只有一份
实现），Join/Accept/Reject/Leave 对齐 Mobilizon；远端评论复用 `comments` 表。

### Phase 4 — 出站方向（`c79dfd3`）
`fed_events` 镜像 + `fed_participations`（这个**用了独立表**——票务/表单/容量那套
本地机制对远端活动不适用）、出站 Follow/Undo/Join/Leave、给前端的 API。

### 前端（seastar-app 全部 7 个提交）
`/fediverse` 列表与详情、评论作者展示、My Events 的远端分区、关注管理。

---

## 3. 实验室

全部在 `sg.sola.day` 上，与生产完全隔离（容器内 `db:5432/soon`，无任何生产凭据；
生产在 `homepod.sola.day`）。

| 实例 | 域名 | 拓扑 |
|---|---|---|
| sola-A | `sola.seven.fan` / `api.seven.fan` | 经 Next rewrites 反代 |
| sola-B | `solab.seven.fan` | Traefik 直连 soon |
| Mobilizon 5.2.4 | `mob.seven.fan` | — |
| Mastodon 4.6.4 | `mas.seven.fan` | 含 AUTHORIZED_FETCH 严格模式 |

两个 sola 节点**刻意用不同拓扑**，各验证一种设计文档允许的接入方式。

搭建时的坑：Mobilizon 5.2.4 的 2019 年迁移在 **PG18 上失败**（`ALTER TABLE ADD
PRIMARY KEY` 的 NOT NULL 语义收紧），单独给它配了 PG16+PostGIS；PG18 镜像改了挂载
约定（挂 `/var/lib/postgresql` 而非其 `data` 子目录）；服务器上残留的**过期 GHCR
凭据**导致所有 ghcr 拉取报 denied，而 curl 匿名 token 却正常。

---

## 4. 真机联调发现的缺陷

这是本次开发最重要的产出。**全部 8 个缺陷都是在单元/集成测试全绿的情况下发现的**
——发现第 1 个时已有 870 例测试通过。

| # | 缺陷 | 为何单测发现不了 | 提交 |
|---|---|---|---|
| 1 | 反代改写 `Host`，签名验证必失败 | 单测直接打控制器，没有反代这一层 | `387c919` |
| 2 | `uuid` 发 TSID，Mobilizon 强类型 cast 失败**整条活动被丢弃** | 需要对端的 schema 才会暴露 | `381a9f2` |
| 3 | 评论签名者 ≠ 归属 actor，Mastodon 静默丢弃 | 我们自己的验签不做这项检查 | `33243b7` |
| 4 | 实例 actor 无法被 webfinger，**严格模式下所有签名 GET 被 401** | 默认模式完全不触发 | `851724c` |
| 5 | `/comments/:id` 未进反代白名单 | 单测里路由是全的 | `bcec831` |
| 6 | 删除远端 actor 会把评论/报名变成孤儿 | 需要真实的删除操作触发 | `d363835` |
| 7 | 伪造 keyId 洪泛可放大成出站请求 | 文档写了、代码没实现，无人对照 | `0c17e99` |
| 8 | actor id 绑定可变 handle，改名即断联邦 | 需要对照 Mastodon 的 URL 形状才看得出 | `0d9cfcf` |

另有一条**非缺陷但极易误判**：Mastodon 账号 `approved=false` 时它的 actor 端点
404，导致我们取不到公钥、验签失败——排查时看起来完全像签名 bug。

### 两条对端行为（不是缺陷，但会误导）

- **Mobilizon 只允许关注 Group 和实例**，Person 关注返回 `:person_no_follow`。
  我们的出站 Follow 正确地停在 `pending`——不臆造 Accept 是对的。
- **Mobilizon 的 `fetch_and_create` 对已存在的活动只返回缓存不更新**。状态同步
  只能靠推给关注者的 Update，重新抓取无效；测同步必须先建立关注关系。

---

## 5. 关键决策与理由

**规范域选 `app.sola.day`（前端域）而非 API 域** —— actor 身份要落在用户认知的
域上。代价是引入反代，而反代正是缺陷 #1 的来源。值得，但要记住这个代价。

**actor id 用不可变 TSID，不用 handle** —— 最初用了 handle，复查时发现改名会
断联邦。Mastodon 用 `/ap/users/<numeric id>` 正是为此。实测确认 Mobilizon 对
`(preferred_username, domain)` 有唯一约束，**已缓存旧身份的实例会拒绝新身份**
——actor id 是一扇单向门，上线后再改等于要求全网手工清缓存。赶在上生产前改掉。

**`uuid` 选择省略而非伪造** —— 编一个 UUID 等于发布一个不指向任何东西的标识符；
`id` 本来就是权威标识。

**远端参与者复用 `participants` 表、远端报名用独立表** —— 方向不同：入站要复用
本地的容量检查和审批 UI；出站的本地票务机制根本不适用。

**验签的候选 host 不采信 `X-Forwarded-Host`** —— 它可伪造，采信它就等于允许把
签给别家实例的请求重放进我们的 inbox。只用"收到的 Host + 配置的规范域"。

**投递必须限速排空** —— 生产只有 1 个后台线程、6 个数据库连接。裸 fan-out 会
饿死验证码邮件。这条约束贯穿整个投递设计（含 HTTP 期间释放 AR 连接）。

---

## 6. 测试策略

三层，互补而非重复：

1. **923 例常规套件**（`bin/rails test`，全部进程内、无 docker 依赖，每次提交必跑）
2. **契约夹具池**（`23520d9`）——11 份从参考仓库拷来的**真实载荷**走完整入站路径
   （含验签）。`SOURCE.md` 记了 upstream commit，升级参考仓库时 diff 即知协议漂移。
   Gancio 那份专门留着因为它**够糟**（location 无 type 无 address），Mobilizon
   容忍我们也必须容忍。
3. **真机三方实验室** —— 唯一能发现上述 8 个缺陷的层。

写契约测试时真实载荷打脸两次，两次都说明系统在正常工作：一次是我的夹具处理没把
`actor` 对齐签名者，被我们自己的检查挡下 401；一次是 Mobilizon 的 Join/Leave 两份
夹具共用同一个活动 id，被幂等账本当重放丢弃。

**一条防复发措施**（`efb39c7`）：Rails 路由表与 `next.config.mjs` 代理清单的交叉
断言。"后端加路由忘了加代理白名单"已经犯了两次（`/comments/:id`、`/actor/outbox`），
现在会在测试里被抓住。

---

## 7. 已验证的互操作场景

- **发现**：Mastodon 与 Mobilizon 均解析 sola 的 Group/Person 并保存公钥
- **关注**：双向；Mastodon 取关；sola 出站关注 Mobilizon 群组；**AUTHORIZED_FETCH
  严格模式全流程通过**
- **内容**：Create/Update/取消三向同步。Mastodon 渲染为
  `<h2>标题</h2> + summary + 回链`（证实 `summary` 是它唯一能显示的结构化信息）；
  Mobilizon 完整解析结构化字段（时区/joinMode/容量/地址/经纬度 lon-first）
- **评论**：sola ↔ Mastodon 双向，`inReplyTo` 正确挂在活动上
- **报名（入站）**：free 立即落座、restricted 走现有审批 UI、满员与购票活动 Reject、
  Leave 释放席位
- **报名（出站）**：sola 用户报名 Mobilizon 原生活动，对方参与者列表出现
  `alice@sola.seven.fan`
- **sola↔sola**：关注、内容镜像、跨节点报名全通（SG↔CN 的预演）
- **三方广播**：一次发布，三个 inbox 全部一次投递成功，各自按能力渲染
- **健壮性**：26/26 经公网+反代（签名九项负例、载荷四项、幂等三项、黑白名单、限流）
- **投递可靠性**：真实实例 29 条全成功；不可解析域累计 218 次失败，正确退避并触发
  域级熔断

---

## 8. 未完成

- **群组成员联邦**（Member/Invite/Remove + 七集合爬取）——Mobilizon 最复杂子系统
- **中继（relay）**
- **RFC 9421 出站签名**（只按 cavage 签；入站两种都收）
- **LD Signatures / 对象完整性证明**——因此不支持经第三方转发的活动
- **公网真实实例验证**（INTEROP §6）——上生产前的必要一步，且**必须用一次性测试
  群组**，因为 actor id 被公网缓存后即固定

---

## 9. 接手须知

**部署实验室改动**：

```bash
# 后端
rsync -az --exclude='.git' --exclude='node_modules' --exclude='tmp' --exclude='log' \
      --exclude='.env*' soon/ root@sg.sola.day:/opt/fedlab/src/soon/
ssh root@sg.sola.day 'cd /opt/fedlab/src/soon && docker build -q -t fedlab/soon:dev . && \
  cd /opt/fedlab && docker compose up -d --no-deps --force-recreate soon soon-b'

# 前端（rewrites 编译进 routes-manifest.json，改配置必须重新 build，重启无效）
ssh root@sg.sola.day 'cd /opt/fedlab && docker compose stop seastar mastodon-sidekiq && \
  docker run --rm -v /opt/fedlab/src/seastar-app:/app -w /app \
    -e NODE_OPTIONS=--max-old-space-size=1800 oven/bun:1.3.14 \
    sh -c "bun install --frozen-lockfile --ignore-scripts && bun --bun run build" && \
  docker compose up -d --no-deps seastar mastodon-sidekiq'
```

构建前端要先停掉 sidekiq 腾内存（那台机器只有 3.9 GB）。

**几个反复踩到的点**：

- `docker exec -e VAR=x ... mobilizon rpc` 的环境变量**到不了** rpc——它连的是已
  运行的节点。参数要写进脚本。
- `--force-recreate` 会换掉容器，之前 `docker cp` 进去的临时脚本随之丢失。
- Mobilizon 的运行时日志不进 stdout，排查要用 `rpc` 分步执行。
- 语言文件里键有加引号和不加引号两种写法，查重复必须两种都覆盖。
- 不要用 `destroy_all` 删对端实例的数据（我在 Mastodon 上这么做，留下了
  `account_stats` 孤儿）。Mastodon 有 `tootctl accounts delete` 走正规流程。

**开关**：`FEDERATION_ENABLED` 默认关闭，所有联邦路由 404。这是灰度与回滚的总闸，
关掉后已铸造的 actor id 与密钥保留，重开身份连续。

## 10. 外部 review 整改（2026-08-02）

一份独立 review 对照代码提出 19 项。其中约半数（评论出站、集合分页、keyId 负
缓存、远端 Event 镜像、出站 Follow/Join、Accept/Reject/Update/Delete、联邦前端）
在其撰写后已实现；核实后确认真实存在并修复的六项：

| # | 缺陷 | 修复 |
|---|------|------|
| 1 | 入站账本在 Job 运行前就标 `processed`，处理失败的活动被永久丢失（远端重投被当成重复） | 状态机 `received → processed/ignored/failed`；`failed` 行在重投时被原子认领重跑；入队失败标 `failed` 并回 500 让远端重试 |
| 2 | 业务保存后才写 delivery，出站异常被吞掉——本地成功、联邦静默丢失；多 inbox 扇出可能写一半 | Event 更新/取消/审批、评论、报名审批全部与 outbox 行同事务提交；`enqueue` 扇出整体一个事务；不再吞异常，失败回滚业务变更 |
| 3 | 远端 Join 的容量检查在事务外，并发可超卖 | 事务内 `event.lock!` 后重查容量，锁外保留廉价预检 |
| 4 | 429 的 Retry-After 被忽略；POST 跟随重定向会把签名请求重放到新 host | Retry-After（秒数/HTTP-date，封顶一天）与自身退避取大；POST 遇 3xx 不跟随、按永久失败处理；GET 跨 host 跳转剥掉 Signature/Date/Digest |
| 5 | Event activity id 用秒级 `updated_at`，同秒两次更新 id 相同，被对端幂等丢弃 | 毫秒 + 随机后缀 |
| 6 | `fed_instance_keys` 无数据库级单例约束，`rescue RecordNotUnique` 背后没有唯一索引 | `singleton_guard` 常量列 + 唯一索引，并发首建确定性收敛为一行 |

每项都有对应回归测试（`federation_hardening_test.rb` 等，套件 942 例全绿）。
仍有效的遗留项：公网真实实例验证（上线前置）、生产 `FEDERATION_ENABLED`
灰度方案、S2S harness 的故障注入扩展。

## 11. 第二轮外部 review 整改（2026-08-03）

18 项 P1 + 10 项 P2。核实后修复的（每项带回归测试，套件 951 例全绿）：

| Review | 修复 |
|---|---|
| P1-1 | 出站签名身份在 **enqueue 时快照**进 `fed_deliveries`（`signing_key_id`/`signing_key_pem`，加密）——被删 Group 的 Delete 公告仍用它自己的 key 签名；group destroy 与公告同事务，不再吞异常 |
| P1-2 | Follow/Unfollow/Join/Leave 的关系变更与 outbox 行同事务 |
| P1-3 | 活动 id 按**尝试**铸造：pending 复用（幂等重发），rejected/cancelled 后重试铸新 id——否则对端按 id 去重永久丢弃重试 |
| P1-4 | 入站账本绑定 actor+type（不匹配 → 403 conflict）；body digest 存档、漂移仅告警（重试可能重新序列化，不能误杀合法重投） |
| P1-5 | "已写 received、未入队"的进程崩溃窗口：超过 15 分钟的 received 行可被远端重投原子认领重跑 |
| P1-6 | 同 host 接管：attributedTo 必须等于验签 actor；已存在镜像的 owner 不可被 Update 更换 |
| P1-7 | 只镜像 to/cc 含 `as:Public` 的事件（完全无 addressing 的旧对端除外） |
| P1-8 | public→private/draft 发 Tombstone Delete；评论 remove 联邦 Delete(Note) |
| P1-9 | DeliveryJob 发送前重查开关与域策略：域被封 → `suppressed`，开关关 → 回 pending 稍后恢复 |
| P1-11 | `remote_updated_at` 单调屏障：旧 Update 不回滚新状态，Delete 后旧活动不复活 |
| P1-12 | actor 文档强校验（publicKey.id 同源、owner 一致、PEM 可解析、inbox 为 URL）；畸形文档统一进负缓存而非 500/绕缓存 |
| P1-14(部分) | 补 IPv6 特殊段（::/128、ff00::/8、64:ff9b::/96 等）；socket 级 IP pinning 仍遗留 |
| P1-15 | 全局 discovery 预算（域轮换绕不过）；域名统一 canonicalize |
| P1-16 | 出站 Follow/Join 前统一域策略检查；discovery cache-hit 路径同 |
| P1-17 | `FedEvent.visible` scope：封禁 actor/域后已镜像内容从公共 list/detail 消失 |
| P1-18 | 验签成功但 metadata 过期 → 异步 ActorRefreshJob（限流 2/5min/域） |
| P2-2 | FedDomainStat 计数改单语句 SQL 自增（消除 lost update） |
| P2-3 | 集合分页 page clamp 到真实页数（拒绝任意深 OFFSET） |
| P2-6 | 远端 Note 指向非 public 本地事件 → ignored |
| P2-7 | 非法 FEDERATION_MODE fail-closed（按 allowlist 处理） |
| P2-9/10 | seastar：pending 统一为"取消申请"；外链 noopener,noreferrer |

**明确遗留**（不阻塞实验室，上线前评估）：P1-10（GoodJob 队列隔离与 token-bucket 出站限速——生产单线程约束下需要独立设计）、P1-13（HTTP 响应流式硬上限——httpx 层）、P1-14 的 DNS rebinding socket pinning、P2-1（账本/投递留存策略）、P2-5（handle 复用的 tombstone 策略）、P2-8（migration preflight 惯例）。

## 12. Move / FEP-8b32 / 自定义域名（2026-08-03）

一轮把 PLAN §9.4/§9.6 从规划变为实现，全部经 sg.sola.day 实验室真机验证
（INTEROP §11）。commits `05ab911`（实现+测试）、`cee9467`/`cb76e01`（实测记录）。

**Move**：入站在 `InboxService#handle_move`——只认 actor 自述（object 必须等于
已验签的 sender uri），target 新鲜抓取后核对 `alsoKnownAs` 互指，通过才重指
本地关注（旧边销毁、向继任者发全新 id 的 Follow）；target 是本地 actor 时走
local-target 分支，核对的是本地的 `fed_also_known_as`。出站
`OutboxService.move_actor` 先抓 target 验证认领（不通过抛 `NotAttested`），
广播事务内写 `fed_moved_to`。API：`POST /api/v1/federation/groups/:id/aliases`
与 `/move`（GroupPolicy#manage?）。

**FEP-8b32**（eddsa-jcs-2022）：`lib/federation/{jcs,multibase,integrity_proof}.rb`
自实现（RFC 8785 + base58btc，无新 gem）。每个 actor 第二对密钥（Ed25519，
私钥 encrypts，公钥即 Multikey 串），actor 文档以 `assertionMethod` 发布。
出站 Event/Note 带 proof，`created` 锚定 `updated_at` 使序列化确定；因 proof
绑定 `@context`，活动改为**整体嵌入对象**（Mastodon/Mobilizon 实测不受影响）。
入站校验 warn-only——对端重试时重序列化是合法行为。

**自定义域名**：`groups.custom_domain`（唯一、normalizes 小写、不进
group_params——绑定是运维动作）。WebFinger 双向闭环：绑定域只应答自己群组的
精确 name；规范域对该群组也报自定义域 subject。`Urls.acct` 按 actor 分派。

**实测教训**：

- Mastodon 4.6 规范 actor id 是 `/ap/users/<数字id>`；`/users/<handle>` 文档的
  id 与请求 URI 不同，被我们的 `id == fetched uri` 校验正确拒绝。**Move target
  必须用对端规范 id。**
- 实验室 DNS：`*.seven.fan` 泛解析已整体指到 172.81.108.136（cf CLI 修改），
  `hi.seven.fan` 走 Traefik + LE，Mastodon 端到端发现/关注/投递全通，canonical
  acct 归属自定义域。
- 已知未做：迁移后的旧群组未禁止继续发布（Mastodon 会冻结已迁移账号）；
  User 侧无 alias/move API（服务层支持，入口只开了 Group）。

测试：966 runs / 3056 assertions / 0 failures（新增 15 例）。

---

## 13. Rebase 到 main，以及交界处暴露的三个缺陷（2026-08-17）

分支自 2026-08-12 起落后 main 21 个提交（soon）/ 42 个（seastar-app），期间 main
上线了 OAuth provider、独立表单、以及**统一的 handle 规则与 `domains` 注册表**。
本轮把 `federation` rebase 到 `main`：soon 46 个提交全部重放 + 1 个集成修复
（`816a136`）+ 1 个缺陷修复（`3669433`）；seastar-app 15 个 + 1 个修补（`f4d4bf8`）。
rebase 前的分支保留为 `federation-pre-rebase-2026-08-17`。

**`db/schema.rb` 用临时合并驱动处理**。46 个提交每个都改这个生成文件，逐个手工
合并既无意义又易错。做法是 `git config merge.keepours.driver true` +
`.git/info/attributes` 让它全程保持 upstream 版本，rebase 结束后在全新数据库上从零
迁移（54 个 migration）并与提交的 schema 逐字节比对，一致。**驱动和 attributes
事后已删除**——留着会在将来静默吞掉真正的 schema 冲突。

**migration 顺序**：`24abdf5` 当初把联邦 migration 重编号为"排在 main 之后"，
rebase 后 main 又多了 8 个（`20260812120000`～`20260816120000`），联邦的
`202608121000xx` 反而排在前面。实测从零迁移无依赖问题（联邦 migration 只碰
users/groups/participants/comments 这些既有表），但**那个提交的意图已不成立**，
若要恢复需再编号一次。

### 交界处的三个缺陷（都不是冲突，是自动合并"成功"后的语义错误）

**① 座位计数双写。** main 把 `participant_count` 移进了 `Participant#transition!`
内部，而联邦侧仍保留手写的 `increment!`/`decrement!`。测试直接抓到：远端 Leave 让
计数变成 **-1**，远端 Join 多加一次。合并后的规则是**新建行走 `save!` 自己记计数，
状态流转由 `transition!` 记**——`ParticipationService.join` 的 `increment!` 因此移进
新建分支，`leave` 的 `decrement!` 整行删除。

**② handle 带连字符后联邦全线失效。** main 把用户名规则从 `[a-z0-9_]{6,30}` 改成
6-20 且**用连字符取代下划线**，并把生产上所有下划线名字做了转换。而旧规则被抄了
四份，其中三份会真的失效：`/users/:handle` 的路由约束、webfinger 的 URI 解析、
inbox 的 URI 解析——**路由 404，入站活动被静默丢弃**。现统一到
`Federation::Urls::HANDLE_SEGMENT`，并刻意比 `HandleName::FORMAT` 宽：规则约束
"能取什么名"，这里必须匹配"实际存在什么"（含 canonical id 与历史遗留的 42 字符
大写 `0x` 钱包名）。

**③ `UserMerger` 遇到联邦报名 500。** `fed_participations.user_id` 是活外键且无
ON DELETE，而 federation 从未在 `User` 上声明关联。main 的注释早就预言了
（"revisit once federation lands"）。**两条销毁路径都要修**：`UserMerger`（管理员
合并）在 `destroy!` 前做去重 repoint——`unique(user_id, fed_event_id)` 决定了不能
盲目 repoint；`AuthController#merge_wechat_account!`（丢弃无名微信壳账号，而账号
在取名前完全可以先报名远端活动）靠新增的 `has_many :fed_participations,
dependent: :destroy`。**顺序是刻意的**：repoint 必须先于 destroy，否则 dependent
会把本该转移的记录直接删掉。

**③ 剩下的远端缺口（已知未做）**：源站按 `from` 的 actor URL 记录这次 Join，而该
URL 由 user id 推导，`from` 一销毁就不再解析。本地 repoint 让 `into` 在 My Events
里仍看得到，但他之后发出的 Leave 带的是 `into` 的 actor，Mobilizon 按 actor +
object 匹配，不会认。要真修需在合并前以 `from` 退出、以 `into` 重新加入，代价是
报名退回 pending 等源站重新 Accept——**产品决定，不在 bug 修复范围内**。

### 前端需要人工判断的三处

- **认证 cookie**：两侧修的是同一类"影子 cookie"的不同变体——main 清除无 Domain
  属性的 host-only 版本，联邦清除写在父域上的版本。**两个驱逐互补，都保留**。
- **参与者列表**：main 改为不再随活动详情下载参与者、走单独接口，联邦则在旧结构上
  加了远端作者兜底。核对确认 `participants#index` 返回远端参与者（`active` 只按
  status 过滤，`ParticipantBlueprint` 把 `user` 当可空并输出 `remote_author`），
  故采用 main 的数据源 + 联邦的兜底渲染。联邦那段 `filteredParticipants` 是只赋值
  从不读取的死代码，丢弃。
- **语言字典重复 key**：`Search` 两侧值相同（无害但 TS 报错），`Name` 两侧**值不同**
  ——CSV 里的人名（姓名）vs DNS 记录名（名称）。直接合并会让其中一处静默变错，
  故 DNS 那个改名为 `Record name`。

### 验证与未验证

`bin/rails test` **1378 runs / 0 failures**；前端 `tsc` / `lint` / `build` 干净；
从零迁移与 schema 比对一致。另做了**双向逐行核对**（两侧原本新增的每一行是否都在
合并结果中），soon 缺 2 行、seastar-app 缺 3 行，全部是上述有意替换。

**未验证：任何双实例互操作**。§7 记录的那些场景在本轮 rebase 后一次都没有重跑，
`HANDLE_SEGMENT` 与计数修复只有单元/集成测试背书。分支上生产前必须重跑 §7。
另：`participants#index` 已补 `:fed_actor` 预加载（原本渲染 `remote_author` 是 N+1）。

