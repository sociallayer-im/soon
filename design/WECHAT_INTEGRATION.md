# 微信集成调研报告 — 服务号网页登录 + 微信支付

调研日期：2026-07-31
状态：**§1 微信登录已实现（2026-07-31，未部署）**，方案 A；**§2 微信支付仍是方案**，
被 §2.2 的商户模式决策阻塞。

已实现部分与本文的差异：仅一处——用户信息不再单独调 `/sns/userinfo`，因为
`unionid` 已经在 code 换 token 的响应里返回，省掉一次请求。落地文件：
`soon` 的 `db/migrate/*_add_wechat_identity_to_users.rb`、`User#has_login_identity`、
`AuthController#trusted_signin` + `#wechat_user`；`seastar-app` 的
`src/app/api/wechat/{wechat.ts,signin,callback}`、`signin/WechatSignIn.tsx`、
`config.ts` 的 `WECHAT_LOGIN`。服务号「Sola活动平台」appid `wxdf1ef2c65db36224`，
网页授权域名 `www.juluo.xyz` 已于 2026-07-31 验证通过。
适用范围：CN 部署（`www.juluo.xyz` / `api.juluo.xyz`），即 `seastar-app` + `soon`
的 juluo 区域。SG（sola.day）不受影响。

参考：`design/PAYMENTS_PLAN.md`（Stripe 方案，本文大量复用其结构与结论），
`seastar-app/design/AUTH_INTEGRATION.md`。

---

## 0. 结论摘要

**登录**：技术上是最标准的一条路（服务号网页授权 OAuth2），没有意外。唯一的真实
约束是**域名**：微信只允许把 `redirect_uri` 落在公众号后台配置的「网页授权域名」
下，而 CN 现在只有 `www.juluo.xyz` 这一个前端域名，`api.juluo.xyz` 是另一个域名。
所以回调**必须**先落在 `seastar-app` 的 Next Route Handler 上，再由它调用 soon。
这恰好就是现存的 Google 登录形状（`seastar-auth/src/app/api/google-siginin/route.ts`
→ `POST /api/v1/auth/trusted_signin`），可以原样复用，成本很低。

**支付**：技术流程同样清晰（JSAPI 下单 → 调起支付 → 异步通知 → 查单对账 → 退款），
和已经实现的 Stripe 流程几乎一一对应，`ticket_items` 的状态机、sweeper、
reconciliation job 都能直接复用。

**但有一个必须先由业务决策的阻塞点**：Stripe 方案的核心是
「**每个组织者填自己的 key，钱直接进自己账户，平台不碰钱**」
（PAYMENTS_PLAN 决策 #2/#5）。**微信支付无法这样复制**——微信商户号需要营业执照、
结算账户、与 appid 的绑定审核，且调用需要商户私钥证书文件，不是「粘贴一个
API key」能完成的。可选路径只有三条（§3.1），每条都改变资金流和合规责任。
**这个决策决定了后面所有表结构，必须先定。**

---

## 1. 微信网页授权登录（服务号）

### 1.1 前提条件

| 项 | 要求 |
|---|---|
| 账号类型 | **服务号**，且已通过微信认证。订阅号没有网页授权接口 |
| 接口权限 | 公众号后台「接口权限 → 网页服务 → 网页授权获取用户基本信息」已开通 |
| 网页授权域名 | 后台配置，**只填域名不带协议**（`www.juluo.xyz`），需下载 `MP_verify_xxx.txt` 放到该域名根目录可访问 |
| 数量限制 | 网页授权域名最多 2 个；JS 接口安全域名（用于 JSSDK）另算 |
| 备案 | 域名需在中国大陆完成 ICP 备案（juluo.xyz 已在 CN 提供服务，应已具备，需确认） |

### 1.2 流程（已对官方文档核实）

**第一步 — 跳转授权页**

```
https://open.weixin.qq.com/connect/oauth2/authorize
  ?appid=APPID
  &redirect_uri=<urlencode 后的回调地址>
  &response_type=code
  &scope=snsapi_base|snsapi_userinfo
  &state=STATE#wechat_redirect
```

- `snsapi_base`：**静默授权**，用户无感知直接跳转，只拿到 `openid`。
- `snsapi_userinfo`：弹出授权页，用户点确认后可拿昵称、头像、地区，且返回
  `unionid`。
- `#wechat_redirect` 后缀不能省（微信客户端内直接打开时需要）。
- `state` 必须用于 CSRF 防护，并承载「登录后回到哪一页」的信息。

**第二步 — code 换 token**

```
GET https://api.weixin.qq.com/sns/oauth2/access_token
  ?appid=APPID&secret=SECRET&code=CODE&grant_type=authorization_code
```

返回：

```json
{
  "access_token": "...",   // 网页授权专用，非全局 access_token
  "expires_in": 7200,
  "refresh_token": "...",  // 30 天
  "openid": "...",
  "scope": "snsapi_userinfo",
  "unionid": "...",        // 仅 snsapi_userinfo 且已绑定开放平台时返回
  "is_snapshotuser": 1     // 快照页用户，无有效 openid 语义，需拒绝
}
```

`code` 只能用一次，5 分钟过期。

**第三步（仅 snsapi_userinfo）— 拉用户信息**

```
GET https://api.weixin.qq.com/sns/userinfo?access_token=&openid=&lang=zh_CN
```

### 1.3 openid / unionid 的选择

- `openid` 是**每个 appid 独立**的用户标识。同一个人在服务号、小程序、PC 扫码
  登录里的 openid 互不相同。
- `unionid` 在同一「微信开放平台」账号下的所有应用间一致。
- **建议：把 `unionid` 作为主身份，`openid` 作为该 appid 下的辅助标识并同时存储。**
  只存 openid 的话，将来加小程序或 PC 扫码登录时会造成同一个人两个账号，且事后
  无法合并（没有共同标识）。这需要注册微信开放平台账号并把服务号绑上去
  （开放平台认证 300 元/年）。

### 1.4 全局 access_token 与 jsapi_ticket 的缓存问题

网页授权的 access_token 与**全局 access_token** 是两回事。后者
（`/cgi-bin/token`）用于 JSSDK 的 `jsapi_ticket`、模板消息等，且：

- 有效期 7200 秒，**每天调用次数有限**，且获取新 token 会使旧 token 失效；
- 因此必须**集中缓存、单点刷新**，不能每个请求去取。

soon 的运行形态对这件事是有利的：Puma 单进程模式（`ginger.yml` 明确禁止
`WEB_CONCURRENCY`），GoodJob 在进程内 async 执行。所以一个 `Rails.cache` +
GoodJob 定时刷新任务就够了，不需要额外的 Redis。若将来改为多进程/多实例，
必须换成数据库表（带行锁）或 Redis，否则会互相踢掉 token。

### 1.5 接入 soon 的两种形状

**方案 A（推荐）：Next Route Handler 中转 + `trusted_signin`**

沿用现有 Google 登录的形状，不改 soon 的认证核心：

```
浏览器（微信内）
  └─ GET www.juluo.xyz/api/wechat/authorize        (Next Route Handler)
       └─ 302 → open.weixin.qq.com/connect/oauth2/authorize?redirect_uri=www.juluo.xyz/api/wechat/callback
            └─ 微信回调 → www.juluo.xyz/api/wechat/callback?code=&state=
                 ├─ 服务端用 code 换 openid/unionid（AppSecret 只在服务端）
                 └─ POST api.juluo.xyz/api/v1/auth/trusted_signin
                      {next_token, wechat_unionid|wechat_openid}
                      └─ 返回 JWT → 写 cookie → 302 回 state 里的页面
```

优点：
- **满足网页授权域名约束**（回调落在 www.juluo.xyz，无需把 api.juluo.xyz 也配上，
  网页授权域名总共只有 2 个名额）；
- 复用已有且已加固的 `trusted_signin`（`auth_controller.rb:97`，NEXT_TOKEN 共享
  密钥），soon 侧只需扩展它接受 `wechat_unionid` / `wechat_openid`；
- AppSecret 与 NEXT_TOKEN 都只存在于服务端。

需要注意：`NEXT_TOKEN` 能为**任意**身份签发 session，这条路径的安全性完全依赖
它不泄漏。CN 的 `.env.cn.production` 已经在做这件事，沿用同一套约束即可
（绝不能变成 `NEXT_PUBLIC_`）。

**方案 B：soon 原生实现**

在 soon 加 `GET /api/v1/auth/wechat/authorize_url` 和
`GET /api/v1/auth/wechat/callback`。更内聚，但回调地址在 `api.juluo.xyz`，
会占掉一个网页授权域名名额，而支付相关的 JSSDK 又需要 `www.juluo.xyz` 作为
JS 安全域名——名额紧张。**除非将来只保留后端一个入口，否则不建议。**

### 1.6 数据模型改动

`users` 表（`db/schema.rb:656`）目前的身份列是 `email` / `eth` / `sol` /
`phone`，各自 unique index。需要新增：

```ruby
add_column :users, :wechat_openid,  :string
add_column :users, :wechat_unionid, :string
add_index  :users, :wechat_openid,  unique: true, where: "wechat_openid IS NOT NULL"
add_index  :users, :wechat_unionid, unique: true, where: "wechat_unionid IS NOT NULL"
```

注意现有的 `index_users_on_email` 是**无条件 unique**。Postgres 的 unique 索引
允许多个 NULL，所以微信优先注册（无 email）的账号不会冲突——但要确保写入的是
`NULL` 而非空字符串。

微信注册的用户没有邮箱。**已有的 `bind_email` 流程（`auth_controller.rb:118`）
正是为「钱包优先账号补邮箱」设计的，可以原样服务于微信优先账号**，无需新建流程。

### 1.7 前端改动

`seastar-app/src/app/config.ts` 已经是构建期特性开关的唯一来源。加一个：

```ts
// 微信内置浏览器登录。仅 CN 构建开启（服务号 + 网页授权域名只在 juluo.xyz 备案）。
export const WECHAT_LOGIN = process.env.NEXT_PUBLIC_WECHAT_LOGIN === 'true'
```

**极性用 opt-in**（`=== 'true'`），与 `THIRD_PARTY_LOGIN` / `STRIPE_ENABLED` 一致：
这个功能依赖只有 CN 才有的配置（appid/secret/备案域名），缺配置时就该消失，不该
默认存在。与之相对，`WALLET_LOGIN` / `CRYPTO_PAYMENT_ENABLED` 是 opt-out，原因是
它们本来就无条件可用、且 `.env.production` 被 gitignore（见 config.ts 注释）。

登录页 `src/app/(auth)/signin/page.tsx` 已经按 `alternatives` 计数决定分隔线与
栅格列数，加一个开关会自然纳入该逻辑。

另外建议：在微信内置浏览器里（UA 含 `MicroMessenger`）**把微信登录置顶或直接静默
授权**，因为微信内无法唤起钱包，邮件验证码在微信内置浏览器里体验也差（要切出去
收信）。

---

## 2. 微信支付（JSAPI）

### 2.1 支付方式的选择

| 方式 | 场景 | 是否需要 openid | 适用性 |
|---|---|---|---|
| **JSAPI** | 微信内置浏览器 H5 | 是 | **主方案**——用户已通过 §1 登录，openid 现成 |
| **Native** | PC / 非微信环境，展示二维码 | 否 | 桌面端 fallback，建议同时做 |
| **H5** | 微信外的手机浏览器 | 否 | 需单独申请，且不能在微信内调起。优先级低 |
| 小程序 / APP | — | — | 不适用 |

**建议：JSAPI 为主 + Native 作为 PC 端 fallback。** 这两种共用同一套下单/通知/
查单/退款接口，只是下单 URL 和调起方式不同，增量成本很小。

### 2.2 商户资质与模式 —— 阻塞性决策

Stripe 方案（PAYMENTS_PLAN 决策 #2/#5）是「每个组织者存自己的 secret key，
钱直接进自己的 Stripe 账户，平台不做资金中介」。**微信支付做不到同构的事**，
因为接入一个商户号需要：营业执照、对公结算账户、微信认证的 appid 与商户号
互相关联（需审核）、下载 `apiclient_key.pem` 私钥文件与证书序列号、设置 APIv3 密钥。
这不是组织者能在设置页里「粘贴一个 key」完成的。

三条路径：

**(a) 平台单一商户号收款**
所有票款进平台的商户号，平台再线下结算给组织者。
- 优点：实现最简单，一套配置，与现有 `payment_methods.stripe_setting_id` 的
  「每单快照收款账户」机制兼容（收款方恒定）。
- 代价：平台成为资金归集方，涉及**二清（无证经营支付业务）**的合规风险，并且
  发票/税务责任落到平台。**需法务确认。**

**(b) 服务商（合作伙伴）模式**
平台申请成为微信支付**服务商**，每个组织者作为**特约商户**进件，下单时传
`sp_appid` / `sp_mchid` / `sub_mchid`，钱直接结算到子商户。
- 优点：这是与 Stripe 方案**语义最接近**的路径——钱不经过平台。
- 代价：需要平台自身具备服务商资质，且每个组织者要走进件流程（营业执照等）。
  接入周期以周计。

**(c) 组织者自带商户号（直连）**
组织者在设置页上传自己的 `mchid` + 证书 + APIv3 密钥。
- 技术上可行，但**要求上传私钥文件并由平台明文保管**——比 Stripe 存明文 key
  （PAYMENTS_PLAN 已接受的风险）严重得多，且要求组织者自己有企业资质与关联
  appid 的能力（appid 是平台的服务号，关联需平台配合）。**不推荐。**

> 现有 Stripe 代码的一个有利事实：`ticket_items.stripe_setting_id` 已经在下单时
> **快照**了收款账户（`tickets_controller.rb:595`），退款与验单都用它。无论选
> (a) 还是 (b)，同样的快照结构都能容纳 `wechat_pay_setting_id` / `sub_mchid`。

### 2.3 APIv3 密钥体系

| 凭据 | 用途 |
|---|---|
| 商户私钥 `apiclient_key.pem` + 证书序列号 | 给**发出**的请求签名（`Authorization: WECHATPAY2-SHA256-RSA2048 ...`）|
| 微信支付平台证书 / 平台公钥 | 验证**收到**的回调签名 |
| APIv3 密钥（32 字节） | AES-256-GCM 解密回调中的 `resource` 密文 |
| AppSecret | 属于公众号侧（§1），与支付无关 |

Ruby 生态可用 `wechat-pay` gem，但需评估其对 APIv3 与平台公钥模式的支持程度；
必要时直接用 `Net::HTTP` + `OpenSSL` 自己实现签名/验签/解密，逻辑量不大
（约 150 行），且比依赖一个维护不确定的 gem 更可控。**建议自建一个
`app/services/wechat_pay_gateway.rb`，与已有的 `app/services/stripe_gateway.rb`
同构。**

### 2.4 支付流程（已对官方文档核实）

**① JSAPI 下单（服务端）**

```
POST https://api.mch.weixin.qq.com/v3/pay/transactions/jsapi
{
  "appid": "...", "mchid": "...",
  "description": "活动门票 - <event title>",
  "out_trade_no": "<ticket_item.id>",      // 6~32 位，TSID 满足
  "notify_url": "https://api.juluo.xyz/api/v1/webhooks/wechat/<setting_id>",
  "amount": { "total": 1000, "currency": "CNY" },   // 单位：分
  "payer": { "openid": "..." },
  "time_expire": "<RFC3339>"               // 与 reserved_until 对齐
}
→ { "prepay_id": "..." }                   // 有效期 2 小时
```

**② 调起支付（浏览器内，微信 JSBridge）**

```js
WeixinJSBridge.invoke('getBrandWCPayRequest', {
  appId, timeStamp, nonceStr,
  package: 'prepay_id=' + prepayId,
  signType: 'RSA',
  paySign            // 对 appId\ntimeStamp\nnonceStr\npackage\n 用商户私钥 RSA 签名
}, res => { /* res.err_msg: get_brand_wcpay_request:ok | cancel | fail */ })
```

`paySign` **必须在服务端算**（需要商户私钥）。前端回调 `err_msg` **不可信**，
只能用来决定 UI 跳转，**绝不能据此标记订单已付**——这与 DialogTicket.tsx 现有
Stripe 路径的注释是同一条原则（"Never mark paid client-side"）。

**③ 支付结果通知（notify_url）**

- 微信 **POST** 到 `notify_url`（必须 HTTPS，公网可达，不能带参数）。
- 请求头：`Wechatpay-Serial`、`Wechatpay-Signature`、`Wechatpay-Timestamp`、
  `Wechatpay-Nonce`。用「时间戳\n随机串\n报文主体\n」构造验签串，以平台证书验签。
- `resource` 为密文：`algorithm=AEAD_AES_256_GCM`，用 APIv3 密钥 + `nonce` +
  `associated_data` 做 AES-256-GCM 解密，得到 `transaction_id`、
  `out_trade_no`、`trade_state`、`amount`、`payer` 等。
- 成功返回 **200/204 空体**；失败返回 4XX/5XX 且体为
  `{"code":"FAIL","message":"..."}`。
- **重试策略**：5 秒内无响应即视为失败，按 15s / 15s / 30s / 3m / 10m / 20m /
  30m×3 / 60m / 3h×3 / 6h×2 重试，最多 15 次、覆盖 24 小时。
  **因此回调处理必须幂等。**

现有 `StripeWebhooksController` 的模式（验签 → 以事件 id 为主键落库做幂等
→ 入队 → 快速 200）可以**原样照搬**，把 `stripe_events` 换成
`wechat_pay_events`，主键用 `resource.transaction_id` + `event_type`。

**④ 查单（对账，权威来源）**

```
GET https://api.mch.weixin.qq.com/v3/pay/transactions/out-trade-no/{out_trade_no}?mchid={mchid}
```

与 Stripe 方案的结论一致：**回调是优化，查单才是可信来源**
（`stripe_webhooks_controller.rb:6` 的原话："webhooks are an optimization,
the sweeper is what's trusted"）。已有的 `StripeReconciliationJob` /
`TicketingSweeperJob` 需要一个微信版本，或改造成按 `payment_provider` 分派。

**⑤ 关单与退款**

- 关单：`POST /v3/pay/transactions/out-trade-no/{out_trade_no}/close`
  —— sweeper 在订单超时释放库存时应同时关单，否则用户仍可能付款成功，
  造成「已释放库存却收到钱」。**这是 Stripe 路径没有的额外步骤**
  （Stripe 的 Checkout Session 会自己过期），不能漏。
- 退款：`POST /v3/refund/domestic/refunds`，需 `out_refund_no`（自己生成，
  可用 `refund.id`）、`transaction_id`、`amount{refund,total,currency}`、
  独立的 `notify_url`。退款同样是**异步**的，由退款回调最终确认——这与
  PAYMENTS_PLAN 决策 #10/#11 的「写 pending Refund，回调/对账才落地副作用」
  完全同构，`refunds` 表和 `apply_refund_success!`（`ticket_item.rb:160`）
  可以直接复用。

### 2.5 金额与币种

- 微信金额单位是**分**（整数），与现有 `payment_methods.price`（bigint）、
  `ticket_items.amount`（integer）单位一致，无需换算层。
- 币种固定 `CNY`。`ticket_items.currency` 已存在，写 `"cny"` 即可。
- **最低金额**：微信支持到 1 分，没有 Stripe 那样的费率下限问题
  （费率约 0.6%，无固定手续费）。因此
  **不要照搬 `PaymentMethod::STRIPE_MIN_CENTS`（400）** —— 那个 $4 门槛的理由是
  Stripe 的 $0.30 固定费用，对微信不成立。微信侧的下限设为 1 分即可，
  优惠券 100% 抵扣归零仍走免费路径（决策 #9 的结构保留，阈值不同）。

---

## 3. 落地方案（映射到具体文件）

### 3.1 后端 `soon`

| 改动 | 说明 |
|---|---|
| 迁移 | `users`：`wechat_openid` / `wechat_unionid`（partial unique index） |
| 迁移 | 新表 `wechat_pay_settings`（对应 `stripe_settings`）：`mchid`、`sub_mchid`、`cert_serial`、`private_key`、`apiv3_key`、`notify_secret`、`status`、`name`、`user_id`。若选定 §2.2(a) 单商户模式，可退化为 env 变量、不建表 |
| 迁移 | `payment_methods.wechat_pay_setting_id`；`ticket_items.wechat_pay_setting_id` |
| 迁移 | 新表 `wechat_pay_events`（幂等落库，对应 `stripe_events`） |
| `PaymentMethod` | `SUPPORTED_CHAINS` 增加 `"wechat"`；`kind: fiat`；新增 `wechat_method_has_a_setting` 校验（对应 `stripe_method_has_a_key`）；**不套用 `STRIPE_MIN_CENTS`** |
| `TicketItem` | `payment_provider` 注释增加 `wechat`；状态机**无需改动** |
| `app/services/wechat_pay_gateway.rb` | 新建，与 `stripe_gateway.rb` 同构：`create_jsapi_order` / `query_order` / `close_order` / `create_refund` / 签名 / 验签 / 解密 |
| `app/services/wechat_api.rb` | 网页授权 code→openid、全局 access_token 缓存、jsapi_ticket |
| `TicketsController` | 新增 `POST tickets/wechat_prepay`（对应 `checkout_session`，同样带 `with_lock` 防重）；`refund` 按 `payment_provider` 分派；`set_payment_status` 增加对 `wechat` 的拒绝（同 `:209` 对 stripe 的处理，否则 NEXT_TOKEN 持有者可凭空造已付订单） |
| `Api::V1::WechatPayWebhooksController` | 照搬 `StripeWebhooksController` |
| `WechatPayWebhookJob` / `WechatReconciliationJob` | 照搬对应 Stripe job |
| `TicketingSweeperJob` | 超时释放时**追加关单调用** |
| `BaseController` | `wechat_pay_enabled? = ENV["WECHAT_PAY_ENABLED"] == "true"`，与 `stripe_enabled?`（`:28`）并列 |
| `AuthController#trusted_signin` | 接受 `wechat_unionid` / `wechat_openid` 分支 |
| `ginger.cn.yml` | `env: WECHAT_PAY_ENABLED: "true"`；secrets 注入 appid/secret/mchid/证书等。**SG 的 `ginger.yml` 不加**——与 `STRIPE_ENABLED` 只在 SG 的镜像关系正好相反 |

### 3.2 SDK `packages/sola-sdk/src/`

- 新增 `wechat/wechat.ts`：`createWechatPrepay`（返回 JSAPI 调起参数）、
  `getWechatJsConfig`（JSSDK 签名，若需要分享/扫码能力）。
- `index.ts` 再导出。
- 与 `stripe/stripe.ts` 一样，在模块头注释里写明「这些端点只在
  `WECHAT_PAY_ENABLED` 的部署上存在，CN 以外会 404，调用前先看构建期开关」。

### 3.3 前端 `seastar-app/src/`

- `app/config.ts`：新增 `WECHAT_LOGIN`、`WECHAT_PAY_ENABLED`（均为 opt-in
  `=== 'true'`），并把 `PAYMENTS_ENABLED` 改为
  `CRYPTO_PAYMENT_ENABLED || STRIPE_ENABLED || WECHAT_PAY_ENABLED`
  —— **漏改这一行会导致 CN 开了微信支付后票价 UI 仍然整体隐藏**
  （CN 目前 crypto/stripe 皆为 false）。
- `components/client/DialogTicket.tsx`：
  - 渠道过滤（`:125`）增加 `wechat` 分支；
  - `handlePay`（`:290`）增加 `chain === 'wechat'` 分支：调
    `createWechatPrepay` → `WeixinJSBridge.invoke` → 无论回调如何都跳到
    「等待确认」态并轮询后端（与 Stripe 路径一致，绝不客户端标记已付）；
  - 非微信浏览器需检测 UA 并给出提示或 Native 二维码。
- `.../create/TicketForm.tsx`：组织者侧的收款方式选择，按 §2.2 选定的模式决定
  是「选一个自己的微信商户配置」还是「无需配置，平台代收」。
- `.env.cn.production`：`NEXT_PUBLIC_WECHAT_LOGIN="true"`、
  `NEXT_PUBLIC_WECHAT_PAY_ENABLED="true"`。SG 的 `.env.production` **不加**
  （opt-in 极性下，不写即关闭）。
- `lang/en.ts` + `lang/zh.ts`：两边都要加 key（CLAUDE.md 约定）。

### 3.4 建议分期

1. **P0 — 微信登录**。独立于支付，不依赖任何商户资质，可立即启动。产出：
   服务号配置 + 网页授权域名验证 + Next 回调路由 + `trusted_signin` 扩展 +
   users 表两列。
2. **P1 — 商户模式决策 + 资质申请**。这是纯业务/合规工作，周期最长，
   应与 P0 并行启动而不是排在其后。
3. **P2 — JSAPI 支付**（下单/调起/回调/查单/关单）。
4. **P3 — 退款 + 对账 job + Native 二维码 fallback**。

---

## 4. 风险与待确认事项

1. **§2.2 的商户模式未定** —— 阻塞 P2 及之后的全部表结构设计。
2. **二清合规** —— 若选 (a) 平台单一商户号，需法务确认资金归集的合规性。
3. **juluo.xyz 的 ICP 备案状态** —— 网页授权域名与支付回调域名都要求备案，
   需确认现状（本次调研未核实）。
4. **网页授权域名只有 2 个名额** —— 已在 §1.5 据此推荐方案 A。若将来要给
   `api.juluo.xyz` 也开授权，需重新规划。
5. **微信内置浏览器的既有登录体验** —— 邮箱验证码在微信内需切出去收信，钱包
   登录完全不可用（CN 已关闭）。微信登录上线前，CN 微信内的转化率大概率很低。
6. **本报告的微信接口细节已对官方文档核实**（网页授权 URL/scope/返回字段、
   JSAPI 下单端点与字段、调起支付参数、回调验签/解密/重试策略）。但商户资质
   政策、费率、服务商进件流程随时可能变化，**实施前需重新核对
   pay.weixin.qq.com 与 developers.weixin.qq.com 当期文档**。
7. **Ruby 侧 SDK 未评估** —— 建议自建 gateway（§2.3），但若决定用现成 gem，
   需先验证其对 APIv3 平台公钥模式的支持。
