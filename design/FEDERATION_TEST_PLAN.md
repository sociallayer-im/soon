# Sola 联邦测试验证方案：投递可靠性 · 格式验证 · 密码学验证

> 配套文档：架构见 `FEDERATION_PLAN.md`；对外互操作性验证（以 Mastodon/Mobilizon
> 为预言机的五层验证）见 `FEDERATION_INTEROP_VERIFICATION.md`。
>
> 分工：INTEROP 文档回答"**和别人**通不通"；本文档回答"**系统本身**在分布式
> 环境下是否正确"——消息投递的可靠性与容错、入站格式的接受/拒绝边界、
> 密码学层的正确性。三者都是纯 sola 侧可测的性质，不依赖对方实例在场。
>
> 状态：待确认，随 FEDERATION_PLAN 各分期落地（映射见 §5）。

---

## 1. 投递语义模型（先声明，再验证）

联邦投递的目标语义，测试围绕它展开：

- **at-least-once 投递 + 接收端幂等 = 观测上的 exactly-once**。
  发送端允许重发（重试、崩溃恢复都会导致），接收端以活动 `id` 去重兜底。
- **不保证顺序**。同一对象的 Create/Update/Delete 可能乱序到达，接收端必须
  乱序容忍（见 §2.5）。
- **业务与投递原子**（outbox pattern）：业务事务提交 ⇔ `fed_deliveries` 行存在。
  不存在"活动发布了但没进队列"或"业务回滚了却发出去了"。
- **失败分级**：可恢复（网络错误、401/408/429、5xx 除 501）→ 指数退避重试；
  永久（其余 4xx、501）→ `failed_permanent` 终态，不再消耗资源。
  与 Mastodon `response_error_unsalvageable?` 语义一致。

---

## 2. 消息投递可靠性与容错验证

载体：§2.1-2.3 单元/集成测试（minitest + mock HTTP）；§2.4-2.6 进程内 S2S
harness 的故障注入模式（见 INTEROP §3.2）。

### 2.1 状态机穷举

`fed_deliveries.status`: `pending → delivering → delivered | pending(重试) | failed_permanent`。

| # | 转换 | 触发 | 断言 |
|---|---|---|---|
| DL-1 | pending→delivered | mock 返回 200/202 | attempts+1，last_error 清空 |
| DL-2 | pending→pending | 返回 500/502/503/429/408/401、超时、连接拒绝 | `next_attempt_at = now + attempts⁴ + 15 + jitter`，退避序列单调递增 |
| DL-3 | pending→failed_permanent | 返回 400/403/404/410/413/422/501 | 不再出现在 sweeper 捞取集合中 |
| DL-4 | 重试上限 | 第 10 次失败 | 转 failed_permanent（不无限重试） |
| DL-5 | delivering 孤儿回收 | 行处于 delivering 且超过投递超时上限（模拟进程崩溃） | 下轮 sweeper 视同 pending 重捞（崩溃恢复 = 重发，由接收端幂等兜底） |
| DL-6 | 429 + Retry-After | 带 Retry-After 头 | next_attempt_at 尊重该头（不早于） |
| DL-7 | 410 Gone | actor 级 410 | 该投递 permanent + 触发 follower 清理钩子 |

### 2.2 并发与竞态

- **sweeper 并发保护**：两个 sweeper 同时跑（模拟 cron 重叠）→ 同一行只被派发一次
  （`FOR UPDATE SKIP LOCKED` 或等价机制的显式测试）。
- **同一活动多 inbox**：一个 Create 对 5 个 inbox 的 5 行投递互不影响——
  1 行 permanent 不拖累其余 4 行。
- **入队与投递竞态**：事务提交前 sweeper 不可见该行（隔离级别验证——
  outbox 行必须在业务事务内插入）。

### 2.3 outbox 原子性（崩溃一致性核心）

| # | 场景 | 断言 |
|---|---|---|
| OB-1 | 发布活动的事务中途抛异常回滚 | events 无变更 **且** fed_deliveries 无新行 |
| OB-2 | 发布成功 | 事务提交后 fed_deliveries 行数 = 去重后目标 inbox 数 |
| OB-3 | 受众展开（followers → inboxes）在入队时快照 | 入队后新增的 follower 不追补、退关的不撤回（快照语义，与 Mastodon 一致） |
| OB-4 | shared inbox 去重 | 同域 3 个 follower（同 sharedInbox）→ 1 行；其中 1 个无 sharedInbox → 2 行 |

### 2.4 故障注入矩阵（harness 模式）

mock 远端按脚本注入，逐项断言状态机走向与**无资源泄漏**：

连接拒绝 / DNS 解析失败 / TLS 证书无效 / 连接超时(>5s) / 读超时(慢响应>10s) /
响应中途断连 / 响应体超 1MB / 重定向循环 / 重定向次数超限(>3) /
返回非 JSON body（投递只看状态码，不解析 body——断言不崩）/
mock 完全宕机后恢复（S6 场景：积压→补投全部送达，无丢失无重复入库）。

资源断言（每项故障后检查）：无泄漏的文件描述符/连接；**HTTP 调用期间 AR 连接
已释放**（测法：把连接池缩到 1，注入 10 秒慢响应，并发另一个 DB 查询必须
不被阻塞——这是对 `release_connection` 包裹的直接验证）；`:mailers` 队列的
邮件任务在投递风暴中延迟不超阈值（饿死回归测试）。

### 2.5 乱序与重复（接收端容错）

| # | 场景 | 期望 |
|---|---|---|
| OO-1 | 同一活动 id 收到两次 | 第二次 202、零副作用（fed_inbound_activities 幂等） |
| OO-2 | Update 先于 Create 到达 | Update 时对象不存在 → 按对象 id 解引用拉取或暂弃（不 500）；随后 Create 到达正常建立 |
| OO-3 | Delete 先于 Create | 记录 tombstone 语义（借鉴 Mastodon 6h delete-arrived-first）：其后的 Create 被拒 |
| OO-4 | Accept(Join) 先于本地 Join 状态可见（网络回环快于事务） | 按 join uri 查不到 → 重试一次/暂弃，不误创建 |
| OO-5 | 重复 Follow（对方重发） | 不产生重复 follower；重新回 Accept（Mastodon 对重复 Follow 的两种分支语义） |
| OO-6 | Undo(Follow) 但本地无此 follow | 202 静默，无副作用 |

### 2.6 投递完全性、准确性与恢复对账

上面各节验证单条投递的行为；本节验证**总账不变量**——消息不丢、不错、
不漏投，故障后能收敛回一致。方法是把 harness 的投递记录仓当作对账账本：

**三条不变量（每轮混沌测试结束后全量断言）：**

1. **完全性（no loss）**：对每个出站活动，
   `预期收件箱集合（受众展开快照） = mock 实收集合 ∪ failed_permanent 集合`，
   且 permanent 的每条都有明确的 4xx 依据。不存在既未送达也无终态记录的
   "消失的消息"。
2. **准确性（no corruption）**：mock 实收的每个 payload 与入队时的
   `fed_deliveries.payload` **逐字节一致**（签名头随重发变化，body 不变），
   活动 `id` 与 Digest 均匹配。
3. **有界重复（bounded duplication）**：同一 (活动 id, inbox) 的实收次数 ≥1
   且 ≤ attempts；接收端幂等用例（OO-1）保证重复不产生副作用。

**恢复演练脚本（harness 混沌轮，随 P2 交付）：**

| # | 演练 | 收敛断言 |
|---|---|---|
| RC-1 | 目标不可达 30 分钟（连接拒绝）→ 恢复 | 积压全部补投，三条不变量成立，最老消息延迟 < 退避上限 |
| RC-2 | 间歇性故障（每 3 次请求失败 2 次，随机） | 最终 100% 送达，退避不放大（无重试风暴） |
| RC-3 | 投递中途 kill 进程（delivering 悬挂）→ 重启 | 孤儿行重捞补投；对方多收的重复在幂等范围内 |
| RC-4 | 混合负载：50 个活动 × 10 个 inbox，其中 2 域宕机、1 域慢响应、1 域返回 4xx | 健康域不受拖累按时送达；对账后每条消息可归因（delivered/permanent+原因） |
| RC-5 | DB 重启（连接闪断）发生在 sweeper 派发中 | 无行丢失/无双派发，任务失败重跑后收敛 |
| RC-6 | 入站方向：sola 重启时对方持续投递 | 对方按 5xx 重试语义补投，sola 恢复后 `fed_inbound_activities` 无缺口（用 mock 主动方的发送账本对账） |

实现要点：mock 投递记录仓给每条实收记录附 (活动 id, inbox, 收到次数, body
hash, 时间戳)，对账函数是 harness 的一等公民——**每个混沌用例结尾必须调用**，
而不是只断言"没抛异常"。

---

## 3. 格式验证：接受正确的，拒绝错误的

原则：**每个拒绝用例配一个最小修正后的接受用例**（防"全拒"假绿，同
INTEROP §3.1 的对照原则）。全部表驱动，放 `test/federation/format_*`。

### 3.1 传输层拒绝（inbox 入口，未验签前就该挡住的）

| # | 输入 | 期望 |
|---|---|---|
| FR-1 | 非 JSON body | 400 |
| FR-2 | Content-Length > 1MB | 413（在读 body 前判断） |
| FR-3 | JSON 嵌套深度 > 限值（JSON 炸弹） | 400，解析器带深度上限 |
| FR-4 | Content-Type 非 activity+json/ld+json | 接受（Mastodon/Mobilizon 实际都不严查入站 CT——宽进）但记日志 |
| FR-5 | 重复的超长键 / NUL 字节 / 非法 UTF-8 | 400，不入库 |

### 3.2 活动结构层（验签后、分发前）

| # | 输入 | 期望 |
|---|---|---|
| FS-1 | 缺 `@context` 或不含 AS 命名空间 | 拒（202+忽略，记日志——学 Mastodon 静默丢弃，不给攻击者探测信号） |
| FS-2 | 缺 `type` / `type` 为未知值 | 202+忽略 |
| FS-3 | 缺 `id` / `id` 非 http(s) / `id` 为相对 URI | 202+忽略 |
| FS-4 | **`object.id` 的 host ≠ `actor` 的 host** | 拒——跨域对象伪造（Mastodon `non_matching_uri_hosts?` 语义），安全关键 |
| FS-5 | payload `actor` ≠ 验签得到的 keyId 属主 | 拒（身份以签名为准） |
| FS-6 | `object` 为字符串（引用） | 仅在白名单场景解引用（Join 的 object=event url 等），解引用限定同源 |
| FS-7 | `type` 为数组（["Create","sc:Event"]） | 取首个已知值（宽容解析） |
| FS-8 | to/cc 为字符串而非数组 | 归一化为数组后处理（writefreely 的 @context 字符串/数组教训同理） |

### 3.3 领域字段层（Event/Join/Note 的 as_to_model 转换）

四态表驱动：对每个字段测 **缺失 / null / 错误类型 / 边界值**。重点行：

| 字段 | 拒绝/降级行为 |
|---|---|
| `startTime`/`endTime` | 非 ISO8601 → 整对象拒；endTime < startTime → 拒；23:59:59 启发式（Mobilizon 语义）正确应用 |
| `location.latitude/longitude` | 非 float（整数 0、字符串 "45.7"）→ **静默丢弃坐标、保留其余**（对齐 Mobilizon `address.ex` 宽容语义） |
| `location` 缺 `type`/缺 `address` | 宽容解析（gancio 夹具回归） |
| `content`/`summary`/`name` | HTML 一律 sanitize（白名单标签）；超长截断到列上限而非 500；`<script>`/`onerror` 注入用例必须清洗 |
| `maximumAttendeeCapacity` | 负数/非整数 → 视为无限制 |
| `joinMode` | 未知值 → 降级 `free`（Mobilizon 默认）|
| `tag`/`attachment` | 数组元素类型混杂 → 逐元素宽容，坏元素跳过不整体拒 |
| 图片/链接 URL 字段 | 非 http(s)（`javascript:`、`data:`）→ 丢弃该字段 |

### 3.4 出站格式（自身正确性）

- **词表白名单快照**：每类出站对象的键集合与 FEDERATION_PLAN §2.4 形状快照
  diff——多一个键、少一个键都算失败（防序列化器腐化）。
- 所有日期 UTC ISO8601 带 Z；`to`/`cc` 恒为数组；`@context` 与快照逐字节一致；
- 分页集合：`totalItems` 为**真实总数**而非当前页大小（nebula `outboxes_controller.rb:14`
  的 bug 作为回归用例）。

---

## 4. 密码学验证

### 4.1 密钥生命周期

| # | 检查 | 断言 |
|---|---|---|
| KY-1 | 惰性生成 | 首次 webfinger/被关注触发；2048-bit RSA；并发首次访问只生成一次（行锁/upsert） |
| KY-2 | 落库加密 | 直接 SQL 读 `fed_private_key` 列 → 是 AR 加密密文，**不含 `BEGIN RSA PRIVATE KEY` 明文**；模型层读出可解析 |
| KY-3 | 公钥出站格式 | PEM SubjectPublicKeyInfo，能被 `OpenSSL::PKey::RSA.new` 与 Mobilizon `prepare_public_key`（单 PEM entry 要求）接受 |
| KY-4 | keyId 稳定 | 恒为 `<actor id>#main-key`，actor id 永不变 |
| KY-5 | 远端密钥缓存 | 首次验签失败 → **重抓一次**再验（对方轮换密钥场景，Mastodon `:61-66` 语义）；重抓仍失败 → 401 且短期内不再重抓（防抓取风暴） |

### 4.2 签名生成正确性（交叉验证）

核心手段：**测试内嵌入两个独立验证器**做交叉验证——
(a) 按 Mastodon `signed_request.rb` 的算法在测试里重实现的验证器；
(b) 按 Mobilizon `http_signatures` plug 语义的验证器。
sola 签出的每个请求必须同时通过两者。这比"自签自验"强一个数量级
（nebula 的 `test_federation_s2s.rb:513-530` 自签自验证明不了任何互通性）。

逐字节断言项（正例）：signing string 的行序与头名小写、`(request-target)` 含
query、host 无默认端口、Digest 先于签名计算、Signature 头的参数转义。

### 4.3 验签负例矩阵（入站，安全关键）

在 INTEROP §3.1 基础上补全密码学侧：

| # | 攻击/畸形 | 期望 |
|---|---|---|
| SV-1 | 用 actor A 的有效密钥签名、payload 声称 actor B | 401/拒（与 FS-5 同源，双保险） |
| SV-2 | 签名有效但覆盖头集合不含 digest（POST） | 401（强度要求） |
| SV-3 | 签名有效、digest 头被替换为另一个合法 body 的摘要 | 401（digest 必须匹配当前 body） |
| SV-4 | `algorithm=hs2019` | 按 rsa-sha256 尝试（接受）|
| SV-5 | `algorithm=rsa-sha1` / `hmac-sha256` | 401 |
| SV-6 | Signature 头 base64 含 `,`（参数解析边界） | 正确解析（nebula `parse_signature_header` split(",") bug 的回归） |
| SV-7 | headers 参数含大写头名 / 多余空格 / 引号变体 | 宽容解析（实现间差异区） |
| SV-8 | keyId 片段变体：`#main-key`、`/publickey` 后缀、无片段 | 都能解析到 actor（Mobilizon `key_id_to_actor_url` 兼容集） |
| SV-9 | Date 恰好 +59min / +61min（时间窗边界值） | 前者过、后者 401 |
| SV-10 | `(created)` 与 Date 同时存在且矛盾 | 以 (created) 为准（hs2019 语义） |
| SV-11 | 2048 位以下弱密钥（512-bit） | 拒（最小密钥长度策略） |
| SV-12 | keyId URL 指向私网地址 / 重定向到私网 | 不发起抓取（SSRF 防护，同 http_client 通用规则） |
| SV-13 | keyId 域在屏蔽表 | 403，不抓取 |
| SV-14 | 同一坏签名重复轰炸 | 密钥抓取有负缓存/熔断（Mastodon Stoplight 语义），不放大出站流量 |

### 4.4 Digest 专项

错误算法名（SHA-512=…）→ 401；`sha-256=` 小写键 → 接受（大小写不敏感）；
多值头 `SHA-256=x, SHA-512=y` → 取 SHA-256 验证；base64 解码非 32 字节 → 400；
空 body 的 GET 带空摘要 → 接受（writefreely 兼容）。

---

## 5. 落地载体与分期

| 分期 | 交付 |
|---|---|
| P0 | §4 全部（密钥+签名与实现同 PR）；§3.1/3.2 传输与结构层 |
| P2 | §2 全部（状态机、outbox 原子性、故障注入随 fed_deliveries 实现）；§3.4 出站快照 |
| P3 | §3.3 领域字段四态表（随 Event/Join 转换器实现）；§2.5 乱序矩阵 |
| 持续 | 每修一个公网互通 bug，先补对应负例夹具再修（回归池只增不减） |

CI 门禁：本文档全部用例属于 `bin/rails test` 常规套件（mock 全部进程内，
无 docker 依赖），**每次提交必跑**；与 INTEROP 文档的实验室场景（周期性、
重量级）分层互补。

通过标准：矩阵全绿 + 负例/正例配对完整 + 覆盖率上不做指标要求（矩阵穷举
本身就是覆盖定义）。
