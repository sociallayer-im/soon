# Sola 联邦开发过程记录

> 配套文档：`FEDERATION_PLAN.md`（架构与分期）、`FEDERATION_INTEROP_VERIFICATION.md`
> （互操作验证方案与实测结果）、`FEDERATION_TEST_PLAN.md`（投递可靠性/格式/密码学
> 测试方案）。
>
> 本文档记录**过程**：做了什么、按什么顺序、为什么这么决定、踩到什么、以及
> 下一个人接手需要知道的东西。截至 2026-08-02，代码在两个仓库的 `federation`
> 分支上，**未合并、未上生产**。

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
