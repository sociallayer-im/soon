# Sola as an OAuth 2.0 / OIDC provider — 功能规划

Status: **一期后端 + 前端已实现，未部署、未提交**（2026-08-15）。
示例应用未做；端到端已用 curl 跑通真实回合。见 §10 实现进度。Written 2026-08-15.
Reference implementation: `/Users/jiang/dev/semi` (`oauth_report.md` +
`semi-backend/app/controllers/oauth_controller.rb`, 5 models, 5 migrations).

目标：`sola.day` 和 `juluo.xyz` **各自**成为独立的 OAuth 2.0 / OIDC 授权服务器，
第三方应用可以 "Login with Social Layer" 接入，并按用户授权读取其身份、社群成员
资格、活动与徽章数据。

---

## 0. 相对 semi 的关键差异（先说结论）

semi 的实现可以直接借鉴结构（模型划分、PKCE、code 原子认领、refresh 轮换），但
**不能照抄**。有五处必须为 sola 重新决定：

1. **双部署、双 issuer。** semi 只有一个 `api.semi.im`。sola 的 SG / CN 是两套
   独立的 Postgres 和独立的镜像，因此天然是**两个互不相通的授权服务器**：
   client 在 SG 注册后在 CN 不存在，签名密钥不同，discovery 文档不同。
   `issuer` 必须来自环境变量（复用已有的 `WEB_URL` / 新增 `OAUTH_ISSUER`），
   绝不能硬编码 —— 这与 `CANONICAL_ORIGIN` 那次踩的坑是同一类问题。
2. **Access token 有效期。** semi 设成 **10 年**，理由是"应用不必频繁刷新"。
   这不该带进 sola：一个 10 年不过期的 bearer token 一旦泄漏，撤销依赖数据库
   查询而非过期。建议 access token **1 小时**、refresh token 30 天并轮换。
   semi 的 token 是不透明随机串（每次请求都查库），所以短 TTL 不增加成本。
3. **Scope 需要重新设计。** semi 的 `wallet` / `token:read` 对应链上资产；
   sola 的价值在 group / event / ticket / badge，见 §3。
4. **前端落点不同。** semi 有独立的 Nuxt 应用；sola 的登录已经并入
   `seastar-app`（`seastar-auth` 已退役），所以授权同意页、应用管理、授权管理
   都应放进 `seastar-app` 的 `(auth)` / `(normal)` route group。
5. **semi 自己列出的未修缺陷不要继承**（`oauth_report.md` §11）：
   `/oauth/admin/applications` **没有任何鉴权**（`admin_list_applications`
   不调用 `authenticate_user`，任何人可枚举全部应用及其 owner）；无审计日志；
   无应用审核。sola 的对应端点必须走 Pundit + `users.admin`。

---

## 1. 端点规划

全部挂在 `/api/v1/oauth/*` 之下，与 soon 现有约定一致（`config/routes.rb` 的
唯一例外只有 `GET /group/icalendar`）。两个例外必须放在根路径，因为规范要求：

```
GET  /.well-known/openid-configuration     # OIDC Discovery（规范强制根路径）
GET  /.well-known/jwks.json                # 公钥集合

GET    /api/v1/oauth/authorize             # 返回同意页所需的 app 信息（JSON）
POST   /api/v1/oauth/authorize             # 用户同意 / 拒绝，返回 code
POST   /api/v1/oauth/token                 # code / refresh_token 换 token
GET    /api/v1/oauth/userinfo              # OIDC UserInfo
POST   /api/v1/oauth/revoke                # RFC 7009 撤销
POST   /api/v1/oauth/introspect            # RFC 7662（可选，二期）

GET    /api/v1/oauth/applications          # 开发者：自己的应用
POST   /api/v1/oauth/applications
PATCH  /api/v1/oauth/applications/:id
DELETE /api/v1/oauth/applications/:id
POST   /api/v1/oauth/applications/:id/rotate_secret   # semi 缺，一期就做

GET    /api/v1/oauth/grants                # 用户：已授权的应用
DELETE /api/v1/oauth/grants/:id            # 撤销授权（连带吊销 token）

GET    /api/v1/oauth/admin/applications    # 平台管理员：全部应用 + 审核
PATCH  /api/v1/oauth/admin/applications/:id
```

`authorize` 拆成 GET（取信息）+ POST（决策）是 semi 的做法，好处是同意页可以是
纯前端页面、后端不渲染 HTML；代价是它不是标准的浏览器重定向端点，第三方 SDK
不能直接把用户丢给它。**建议保留这个拆分，但额外提供一个标准的
`GET /oauth/authorize` 浏览器入口**，由后端 302 到
`https://<canonical>/oauth/authorize?...`（前端同意页），这样标准 OIDC 客户端
库（如 `openid-client`、NextAuth）无需改造即可接入。这是 semi 没做、而 sola
若要对外开放生态就必须做的一步。

---

## 2. 数据模型

沿用 semi 的五表划分，字段按 soon 的约定调整（主键是字符串 TSID，不是 bigint）：

| 表 | 说明 | 相对 semi 的改动 |
|---|---|---|
| `oauth_applications` | 注册的第三方应用 | 增加 `group_id`（应用可归属某个 group 而非仅个人）、`logo_url`、`homepage_url`、`description`、`confidential`(bool)、`trusted`(bool)、`reviewed_at` |
| `oauth_grants` | 用户 × 应用的授权记录 | 不变；`(user_id, application_id)` 唯一 |
| `oauth_authorization_codes` | 一次性授权码，60s | 增加 `nonce`（OIDC id_token 必需，semi 漏了） |
| `oauth_access_tokens` | 访问令牌 | **存 `token_digest`（SHA-256）而非明文**；TTL 1h |
| `oauth_refresh_tokens` | 刷新令牌，30d，轮换 | 同上；增加 `family_id` 用于泄漏检测 |

要点：

- **不存明文 token。** semi 把 access/refresh token 明文写进数据库
  （`t.string :token` + 唯一索引），一次库泄漏等于全部会话泄漏。改成存
  SHA-256 摘要并对摘要建唯一索引，查询成本相同。
- `confidential: false` 的公开客户端（SPA / 移动端）**不下发 client_secret**，
  只靠 PKCE；`token_endpoint` 对这类 client 不校验 secret。semi 强制要求
  secret，等于把 SPA 排除在外，或逼开发者把 secret 放进前端。
- `trusted: true` 的一方应用（sola 自己的子站、未来的移动端）跳过同意页。

---

## 3. Scope 设计

| Scope | 返回 / 授予 | 数据来源 |
|---|---|---|
| `openid` | `sub`（`users.id`，TSID） | — |
| `profile` | `handle`(name)、`nickname`、`image_url`、`bio`、`social_links` | `UserBlueprint` |
| `email` | `email`、`email_verified` | `users.email` |
| `phone` | `phone`、`phone_verified` | `users.phone`（仅 CN 有意义） |
| `wallet` | `eth`、`sol` | `users.eth/sol` |
| `groups:read` | 用户所属 group 及角色列表 | `Membership` + `GroupBlueprint` (`:card`) |
| `events:read` | 用户参与/主办的活动 | `Participant` / `EventBlueprint` |
| `badges:read` | 用户持有的徽章 | `Badge` / `BadgeBlueprint` |
| `tickets:read` | 用户的票据 | `Ticket`（最敏感的一项：含付费记录。一期即开，但同意页单独加粗提示，见 §9） |

原则：**scope 只放宽、绝不绕过 Pundit。** OAuth token 换算出的
`current_user` 之后，一切读取仍走现有 policy；scope 是在 policy 之上再叠一层
收窄。这样"给某个第三方应用开了 groups:read"永远不可能读到该用户自己也读不到
的 group。

`GroupInvite#receiver_address` 之类 PII 在任何 scope 下都不下发。

---

## 4. Token 与签名

- **Access token**：不透明随机串（32 字节 hex），1 小时。资源端点用摘要查库，
  因此撤销是即时的。
- **ID token**：JWT，**RS256**，含 `iss`/`sub`/`aud`/`exp`/`iat`/`nonce`。
- **密钥**：每个部署一把 RSA 私钥，从 `OAUTH_RSA_PRIVATE_KEY` 注入（SG 走
  `ginger.yml` 的 `secrets.inject`，CN 走 `ginger.cn.yml`）。**SG 和 CN 必须是
  不同的两把密钥** —— 同一把密钥会让两个 issuer 的 token 可互相伪造。
  注意 CLAUDE.md 记录的 ginger 非 ASCII 双重编码问题：PEM 是纯 ASCII，不受影响，
  但 PEM 含换行，注入后要在容器内 `printenv | od` 验证换行没被吃掉。
- JWKS 暴露 `kid`，为将来轮换留出空间（一期只有一把）。

---

## 5. 安全要求（一期即做）

从 semi 直接继承的：PKCE 强制 S256、authorization code 用
`update_all(used: true)` 原子认领、refresh token 轮换、拒绝授权时先校验
`redirect_uri` 防开放重定向、client_secret 用 BCrypt 存储。

在 semi 之上必须补的：

1. `redirect_uri` **精确字符串匹配**，禁止通配；本地开发的 `http://localhost:*`
   单独白名单，其余强制 https。
2. `state` 参数在同意页往返中原样带回；前端负责校验。
3. 授权码 replay 检测：命中已使用的 code → 吊销该 (user, app) 的全部 token
   （semi 在 refresh 路径做了，code 路径没做）。
4. `/oauth/token` 与 `/oauth/authorize` 加速率限制（按 client_id + IP）。
5. **审计日志**：授权、发码、换 token、撤销各记一条，含 client_id / user_id /
   scope / IP。semi 明确列为缺失项。
6. `/oauth/admin/*` 走 `users.admin`（`platform_admin?`），不是"任何登录用户"。
7. 同意页必须显示：应用名、owner（个人或 group）、每个 scope 的中/英文人话解释、
   redirect_uri 的域名。

---

## 6. 前端规划（seastar-app）

| 路由 | 归属 route group | 说明 |
|---|---|---|
| `/oauth/authorize` | `(auth)` | 同意页。未登录先走现有登录流程再回来 |
| `/oauth/apps` | `(normal)` | 开发者门户：创建/编辑/删除应用，secret 仅创建时显示一次 |
| `/oauth/grants` | `(normal)` | 用户的已授权应用列表与撤销 |
| `/admin/oauth` | `(normal)` | 平台管理员：全部应用 + 审核 |

- 所有请求走 `@sola/sdk` 新增的 `oauth/` 域模块，`request.ts` 统一传输，
  auth-gated 一律 `noCache: true`。
- i18n key 同时加进 `src/lang/en.ts` 和 `zh.ts`，加之前先确认 key 未重复定义。
- 同意页新增 `metadataBase` 无关，但要 `robots: noindex`。

---

## 7. 分期

**一期（MVP，可对内演示）**
- 5 张表 + 模型；`/authorize`（GET+POST）、`/token`、`/userinfo`、`/revoke`、
  `/jwks`、discovery
- **全部 scope**：`openid profile email phone wallet groups:read events:read
  badges:read tickets:read`（§8 决策 2）
- 开发者门户 + 用户授权中心 + 管理员列表（带鉴权）+ 管理员 `disable` 应用
- §9 的反冒充与同意页要求
- 一个示例接入应用（对标 semi 的 Hola），验证完整回合
- 单元 + 请求测试；`bin/rails test` 全绿

**二期（对外开放）**
- 标准浏览器 `GET /oauth/authorize` 302 入口，兼容通用 OIDC 客户端库
- 审计日志、速率限制、secret 轮换
- 集成文档 + JS SDK

**三期（生态）**
- 写权限 scope（如代表用户报名）
- 移动端 / 原生应用支持（公开客户端 + PKCE）
- 与 ActivityPub 联邦身份的关系梳理（`fed_*` 字段已在 users 表）

---

## 8. 已定的决策（2026-08-15）

1. **任何登录用户都可以创建 OAuth 应用**，无需平台审核即可自行置为 `active`
   （与 semi 一致）。见 §9 —— 免审核把防钓鱼的责任整个压在同意页上，所以
   同意页的几项要求从"建议"升级为一期必做。
2. **一期 scope 全开**：`openid profile email phone wallet groups:read
   events:read badges:read tickets:read`。原 §7 里推迟到二三期的 scope 全部
   前移到一期。
3. **CN 与 SG 的应用不同步注册** —— 两套独立注册，文档需写明，否则第三方会
   以为一次注册处处可用。
4. 跨部署联邦登录（`sola.day` 作为 CN 用户登录源）：**否**。

## 9. 免审核带来的必做项

任何人都能注册应用、且无人审核，意味着**同意页是唯一的防线**。以下在一期是
硬性要求，不是"建议"：

- **应用名反冒充**：创建/改名时拒绝含 `sola`、`social layer`、`聚落`、
  `juluo` 等保留词的名字（除非 owner 是平台管理员）。否则"Social Layer 登录"
  这个名字任何人都能注册。
- 同意页必须显示 **owner 的真实 handle** 和 **redirect_uri 的域名**，
  且对未经审核的应用显示"该应用由第三方开发者提供，Social Layer 未审核"。
- **`trusted: true` 只能由平台管理员在数据库里设置**，不进任何 permit list ——
  与 `users.admin` 同一处理方式。自助注册的应用永远不能跳过同意页。
- 每用户的应用创建数量限流（如 10 个），防止批量注册。
- `tickets:read` 既然一期就开，同意页对它单独加粗提示；它能读出用户的付费记录。

免审核也意味着**吊销通道必须存在**：管理员可以把任意应用置为 `disabled`，
连带吊销其全部 token。这条从"二期审核流程"里拆出来，一期就要有。

---

## 10. 实现进度（2026-08-15）

### 已完成（soon 后端，1040 tests / 0 failures）

迁移 5 张表、模型 5 个、服务 3 个、控制器 4 个、blueprint 2 个：

```
db/migrate/20260815120000..4_*                 5 张表
app/models/oauth_{application,grant,authorization_code,access_token,refresh_token}.rb
app/models/concerns/oauth_digestible.rb        SHA-256 摘要存储
app/services/oauth_config.rb                   每部署的 issuer / RSA 密钥 / JWKS
app/services/oauth_claims.rb                   scope → claims 映射 + 中英文说明
app/services/oauth_id_token.rb                 RS256 id_token
app/controllers/well_known_controller.rb       discovery / jwks / 浏览器 authorize 入口
app/controllers/api/v1/oauth_controller.rb     authorize / token / userinfo / revoke
app/controllers/api/v1/oauth_applications_controller.rb
app/controllers/api/v1/oauth_grants_controller.rb
app/controllers/api/v1/oauth_admin_applications_controller.rb
```

相对原计划的实现决定：

- **浏览器入口提前到一期**（原列在二期）。`GET /oauth/authorize`（根路径）302
  到前端同意页，携带原查询串；同意页再调 `GET /api/v1/oauth/authorize` 取信息。
  校验只在后者做一次 —— 两处校验意味着两处对"什么是合法请求"的定义。
- **三种凭证一律只存 SHA-256 摘要**，包括授权码。SHA-256 而非 BCrypt：这是
  256 位随机串不是口令，没有字典可拖慢，而每个 API 请求都要查一次。
- **client_secret_basic 与 client_secret_post 都支持**，公开客户端用 `none`。
- **refresh 轮换不延长有效期**：家族仍在用户授权后 30 天整体死亡，否则被盗的
  refresh token 可以无限续成永久会话。
- **重放检测两条路径都做了**：授权码二次兑换会吊销它已产出的 token；
  refresh token 二次使用会烧掉整个 family（RFC 6819 §5.2.2.3）。

### 已完成（seastar-app 前端，`npx tsc --noEmit` 干净）

```
packages/sola-sdk/src/oauth/{oauth,types,index}.ts   SDK 域模块
src/app/(auth)/oauth/authorize/{page,data,ConsentForm}.tsx      同意页
src/app/(normal)/oauth/apps/{page,data,OauthApps}.tsx           开发者门户
src/app/(normal)/oauth/grants/{page,data,OauthGrants}.tsx       授权管理
src/app/(normal)/admin/oauth/{page,data,AdminOauthList}.tsx     管理员列表
src/lang/{en,zh}.ts                                              新增 ~45 个 key
packages/sola-sdk/src/request.ts   SolaApiError 增加 description（error_description）
```

scope 的中英文说明**不进前端字典**，由 `OauthClaims::DESCRIPTIONS` 随
authorize 响应下发 —— 否则同一句话有两个来源，迟早不一致。

### 端到端验证（本地，curl 实跑）

discovery → 浏览器 302 入口 → authorize info → 同意 → code 换 token →
userinfo → refresh 轮换 → 重放已用 refresh → 整条 family 被烧（连合法客户端
刚拿到的 token 一并失效）。id_token 的 `kid` 与 JWKS 一致，`nonce` 原样带回。

### 待做

- [ ] **示例接入应用**（对标 semi 的 Hola）。curl 回合已经覆盖了它要证明的
      东西，所以这是演示用，不是正确性缺口。
- [ ] **部署配置**：两个部署各生成一把 RSA 私钥，写进各自的
      `.env.production` / `.env.cn.production` 并加进 `ginger.yml` /
      `ginger.cn.yml` 的 `secrets.inject`：

      ```
      OAUTH_ISSUER=https://api.sola.day        # CN: https://api.juluo.xyz
      OAUTH_RSA_PRIVATE_KEY=<PEM>              # 两地必须不同
      ```

      注意：**inject 列表里出现但 .env 里没有的键会让 deploy 直接失败**
      （"secrets.inject keys not set"），所以这两步必须同时做。PEM 含换行，
      ginger 注入后应在容器内 `printenv OAUTH_RSA_PRIVATE_KEY | od -c | head`
      确认换行没被吃掉 —— `OauthConfig` 会把字面量 `\n` 还原，但不该依赖它。
      未配置密钥时服务照常启动，只是 `id_token` 不签发、JWKS 返回空数组。
- [ ] 速率限制与审计日志（二期）

---

## 11. 上线前 code review 与风险评估（2026-08-15）

### 复查中发现并已修的真实缺陷

1. **外键会阻断用户合并与社群删除（严重）。** 五张 OAuth 表都对 `users` 有活
   外键，`oauth_applications` 还对 `groups` 有一条。没有 `dependent:` 时，
   `UserMerger` 的 `from.destroy!` 会以 `ActiveRecord::InvalidForeignKey` 失败
   —— 只要那个用户曾经授权过任何应用；删除社群同理。这与 `UserMerger` 注释里
   已经记过的 `fed_participations` 是同一个坑。已修：`User` 上对凭证/授权表加
   `dependent: :destroy`（合并不能把第三方访问权转移到存活账号上），
   `UserMerger` 里把用户**拥有的应用**改为 repoint（开发者的应用跟着开发者
   走），`Group` 上用 `dependent: :nullify`（删社群不该顺手弄坏一个第三方
   集成）。回归测试 `test/models/oauth_cascade_test.rb`，已验证去掉修复后确实
   报 `PG::ForeignKeyViolation`。

2. **布尔参数字符串化。** `params[:confidential] == false` 在 HTTP 上永远为假，
   因为传过来的是字符串 `"false"`。后果：一个申请做公开客户端的应用会被静默
   下发一个它只能泄漏的 secret。同一处错误也在管理员的 `review` 上。已改用
   `ActiveModel::Type::Boolean` 强转，两处都有测试。

3. **id_token 静默缺失。** discovery 文档承诺 OIDC，但没配签名密钥时 token
   端点会返回一个不含 `id_token` 的 200，标准客户端库报一个既不提本服务也不提
   密钥的错。已改为：生产环境缺密钥则以 `server_error` 明确失败；开发/测试自动
   生成临时密钥，本地不会再出现"半可用"状态。

4. **保留词误伤。** `/sola/i` 会连带拒绝 "Solana Wallet"、"Solar Punk Club"。
   已改为词边界匹配，并加了反向测试。

5. discovery 里的 `service_documentation` 指向一个不存在的 `/oauth/docs`，已删。

### 已确认无误的部分

授权码只能兑换一次（原子 `update_all`，二次兑换会吊销它已产出的 token）；
code 与 client 绑定，别的 client 拿去兑换会失败**且不会烧掉合法持有者的
code**；PKCE 恒定时间比较；拒绝路径同样校验 `redirect_uri`（否则是开放重定向）；
OAuth access token 打不进 `/api/v1` 的其余端点，sola 会话 JWT 也打不进
`/oauth/userinfo`（双向都有测试）；三种凭证只存 SHA-256 摘要；client_secret
仅在创建与轮换时各出现一次，任何 blueprint view 都不含它；`/oauth/admin/*` 走
`users.admin`（semi 的对应端点完全没有鉴权）；`trusted` 不在任何 permit list。

### 上线仍存在的风险

| 风险 | 评估 | 处置 |
|---|---|---|
| **无速率限制** | `/oauth/token` 未认证可打，且 BCrypt 每次约 100ms CPU —— 既是 client_secret 爆破面，也是廉价的 CPU 放大攻击面。soon 目前**整体**没有 rack-attack，所以这不是 OAuth 引入的新缺口，但 OAuth 把它变得更值得打。 | 二期。上线后观察 `/oauth/token` 的请求量。 |
| **无审计日志** | 出问题时无法回答"哪个 client 在什么时候读了谁的什么"。 | 二期。 |
| **免审核 + scope 全开** | 钓鱼客户端的唯一防线是同意页。已有反冒充、owner 展示、redirect 域名展示、未审核提示、`tickets:read` 加粗、每人 10 个上限、管理员一键 disable 并连带吊销。 | 接受（这是明确的产品决策）。建议上线后定期看一眼 `/admin/oauth`。 |
| **admin 列表的 N+1** | `active_token_count` / `grant_count` 每个应用两条查询，100 个应用 = 200 条。 | 接受：仅管理员、仅一个页面。应用数上千时再改成聚合。 |
| **id_token 内联 phone/wallet claim** | 只走 code 流程，id_token 只出现在 POST 响应体里，不进 URL。 | 接受。 |
| **密钥轮换** | JWKS 目前只发一把 key。轮换需要同时发布新旧两把、等旧 id_token 过期（1 小时）再撤。 | 结构上已留好（`kid` 由密钥自身派生）。真要轮换时按此步骤。 |
| **两地密钥必须不同** | 已生成两把不同的 2048 位密钥，分别写入 `.env.production` / `.env.cn.production`，并加入各自的 `secrets.inject`。已核对两者 `kid` 不同。 | 已处置。 |

### 部署注意

- `OAUTH_ISSUER` 与 `OAUTH_RSA_PRIVATE_KEY` **必须同时**存在于 `.env` 和
  inject 列表：inject 里有而 .env 里没有会让 deploy 直接失败，反过来则被静默
  忽略（`ALLOWED_SIWE_DOMAINS` 和 `WEB_URL` 都曾这样悄悄失效过）。
  `ginger config -c ginger.yml` 已确认两地都能解析到这两个键。
- 私钥以 **base64 单行**存放，绕开 .env 解析器对多行值的分歧；`OauthConfig`
  同时接受 base64、字面量 `\n`、和真正的多行 PEM，三种都有测试。因为是纯
  ASCII，不受 ginger 那个非 ASCII 双重编码问题的影响。
- **本次部署会跑 5 个建表迁移**，全部是新表、无数据回填，对现有表零改动。
  但注意 `ginger rollback` 只换镜像不回滚迁移 —— 回滚后这五张表会留在库里
  （空表，无害）。

### 12. 规范符合性复查（部署 sola.day 前）

对照 RFC 6749 / 6750 / 7009 / 7636 与 OIDC Core 逐条过了一遍。**已补的四处：**

- **`Cache-Control: no-store`**（RFC 6749 §5.1 是 MUST，6750 §5.3 对资源端点
  重申）。之前 token 与 userinfo 响应没有这个头，代理或浏览器有权留一份别人的
  access token。
- **UserInfo 必须同时支持 GET 和 POST**（OIDC Core §5.3.1），之前只有 GET。
- **缺 bearer token 时要回 `WWW-Authenticate`**（RFC 6750 §3），否则客户端分不清
  "凭证不对"和"根本不知道要什么"。
- **refresh 时的 scope 收窄**（RFC 6749 §6）。之前传了 `scope` 会被静默忽略并
  返回原样的全量 scope；现在支持收窄、拒绝扩大，两个方向都有测试。

**已知且有意保留的偏离一处：** 授权端点在参数出错时（如 `invalid_scope`）不把
错误重定向回 client 的 `redirect_uri`，而是在同意页上显示。规范说在
`redirect_uri` 已确认合法的前提下 SHOULD 重定向回去。这里选择显示：本实现的
同意页是前端页面，错误对开发者可见更有用，且少一条可被诱导的重定向路径。
代价是标准客户端库在这种情况下会一直等着不返回。如果将来接入方反馈，再改。

**逐条确认无误：** `expires_in` 为秒；`scope` 始终回传；错误码用 RFC 规定的那组
（`invalid_grant` 是客户端丢弃 refresh token 的信号）；未知 token 的 revoke 返回
200（否则是令牌有效性预言机）；PKCE 强制 S256 且恒定时间比较；只支持 code 流程，
所以 `id_token` 只出现在 POST 响应体、不进 URL；`token_endpoint_auth_methods`
三种都真的支持（basic / post / none）。
