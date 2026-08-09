# 微信集成调研报告 — 服务号网页登录 + 微信支付

调研日期：2026-07-31
状态：**§1 微信登录已实现并已上线**（2026-07-31，方案 A）；
**§2 微信支付已上线 CN 并完成真机验证**（2026-08-08，分支 `wechat-pay`，见 §5）。
§2.2 的商户模式按 **(a) 平台单一商户号** 落地，但代码形状按 (b) 服务商模式预留。
**分支未合入 main** —— 功能成熟前刻意保持分离，生产跑的就是分支镜像。

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

#### 1.3.1 生产现状：**尚未绑定开放平台**（2026-08-08 实测）

CN 生产库里唯一的真实微信账号 `wechat_unionid = nil`，`wechat_openid` 正常。
两次独立观察（7-31 与 8-08 的同一个微信号）结果一致，所以这不是偶发——**服务号
还没有绑定到微信开放平台账号**。

现在**没有**任何功能受影响：只有服务号一个 appid 时，openid 足以唯一识别一个人，
登录、合并、去重都正常。

风险全在扩展的那一刻。openid 按 appid 隔离，一旦新增小程序 / PC 扫码登录 / 第二个
公众号，同一个人在新入口会拿到**不同的 openid**，而没有 unionid 可以关联，于是
又是一个重复账号——正是 `bind_email` 合并要消除的问题换了个形态，而且这次连自动
识别的依据都没有（靠邮箱验证码的人工合并路径仍在，但不会自动发生）。

**所以绑定要趁早。** `AuthController#wechat_user` 已经写好了 back-fill：某次登录
一旦带回 unionid，它会补写到已有账号上（`claimable?` 只填空、绝不覆盖别人的标识），
不会另建账号。也就是说——

- **现在绑定**：存量账号在各自下次登录时自动补齐 unionid，零人工。
- **加了第二个入口之后再绑**：那之前产生的重复账号已经存在，只能手工合并。

##### 绑定步骤

1. **注册微信开放平台账号** — <https://open.weixin.qq.com>（与公众平台是两套账号
   体系，不能复用公众号的登录态）。
2. **完成开发者资质认证** — 「账号中心」→「开发者资质认证」。这是**绑定的前置
   条件**，不是可选项，费用 300 元/年。
3. **绑定公众号** — 「管理中心」→「公众账号」→「绑定公众号」，填入**服务号的
   登录邮箱与密码**，再用**服务号管理员的微信**扫码确认。

需要留意的约束：

- **主体**：相同或关联主体可直接绑定；不同主体也允许，但整个开放平台账号只能绑
  5 个不同主体的公众号（同主体/关联主体上限 50 个）。
- **一个公众号只能绑定一个开放平台账号**，绑错了要先解绑，所以第 1 步注册时就要
  确认主体选对。
- 绑定生效后，`snsapi_userinfo` 网页授权的返回里就会带 `unionid`；**已经授权过的
  存量用户也会返回**，无需重新授权，这正是 back-fill 能生效的原因。
- 我们用的 scope 已经是 `snsapi_userinfo`（见 `wechat.ts`），无需改代码——绑定
  完成后什么都不用动，unionid 会自己出现。

出处：[开放平台绑定应用账号](https://developers.weixin.qq.com/doc/oplatform/developers/product/open/bind.html)、
[UnionID 机制说明](https://developers.weixin.qq.com/miniprogram/dev/framework/open-ability/union-id.html)、
[微信开放平台如何绑定公众号](https://developers.weixin.qq.com/community/develop/doc/000accd60a86384de8e1db10761809)

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

微信注册的用户没有邮箱。已有的 `bind_email` 流程（`auth_controller.rb:118`）
正是为「钱包优先账号补邮箱」设计的，微信优先账号可以复用它。

> **2026-08-08 更新：原文说「可以原样服务，无需新建流程」，这一句不准确。**
> 复用是对的，但有一处必须改：`bind_email` 原本在邮箱已被占用时直接
> `render_error("email is already in use")`。对钱包账号那是合理的，对微信账号
> 却正好制造了本文档要避免的重复账号——同一个人用微信登录拿到一个空账号，而他
> 的邮箱账号早就存在，两者无法合并。
>
> 现在这种情况会**合并**：微信身份挪到邮箱账号上，空账号删除，下次微信登录直接
> 命中合并后的账号。合并会删账号，所以只在三个条件同时成立时允许（见
> `AuthController#mergeable?`）：账号是微信优先的、`name` 仍为空（尚未完成注册）、
> 目标账号自己没有微信身份。
>
> **`name` 为空是这个窗口的判据，因此邮箱必须问在用户名之前。** 原先前端的顺序是
> `/register` → `/bind-email`，那样绑邮箱时 `name` 已有值、窗口早已关闭，合并路径
> 根本走不到。前端已对调为 `/bind-email` → `/register`（`onboardingTarget()`）。
>
> 注意这里**不能**用「账号没有数据」来判断是否可合并：后端没有任何地方要求
> `name` 存在才能写入（`EventPolicy#create?` 完全不看 `name`），所以一个从不设
> 用户名的钱包账号可能既没 `name` 又有大量数据。把合并限定在微信账号正是为此。

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

---

## 5. 实现记录（2026-08-08，分支 `wechat-pay`）

商户模式选 **(a) 平台单一商户号**：票款进平台商户号，再与组织者线下结算。
组织者侧无需任何配置，加一个「微信支付」收款方式即可。
**二清合规仍未由法务确认**（§4.2），这是上线前唯一的非技术阻塞项。

代码按 (b) 服务商模式的形状写：`wechat_pay_settings` 是一张表而不是几个 env
变量，订单快照 `wechat_pay_setting_id`，`sub_mchid` 列预留。将来要迁到服务商
模式是插入数据行 + 下单多传 `sub_mchid`，不是对着线上订单做迁移。
`WechatPayGateway` 对 `sub_mchid` 存在时**直接抛异常**，不猜 partner 端点的字段名。

### 5.1 与本文原方案的差异

- **`payment_methods.currency` 变成真字段**。原先这一列存在但没人读写，订单的
  `currency` 是硬编码的 `"usd"`。现在由 `PaymentMethod::RAIL_CURRENCY` 按渠道
  填充（stripe→usd、wechat→cny），下单时**快照**到订单上——退款必须按收款时
  的币种发起，重新推导会改写历史订单。
- **`STRIPE_MIN_CENTS` 变成 `MIN_PRICE` 按渠道的 map**（stripe 400、wechat 1）。
  $4 门槛的理由是 Stripe 每笔 $0.30 固定费，微信没有固定费，照搬会把每一张
  ¥4 以下的票都禁掉。
- **`Coupon#get_discounted_price` 的 ×10000 缩放改按 `FIAT_CHAINS` 集合判断**。
  原先写的是 `chain == "stripe"`，微信订单会落进 crypto 分支，固定额优惠券被
  放大 10000 倍、再被 clamp 到订单金额——**结果是订单归零**。这是本次发现的
  真实隐患，与微信是否上线无关，已单独提交。
- **`set_payment_status` 改为拒绝整个 `FIAT_CHAINS`**，不再只挡 `"stripe"`。
  该端点只有 NEXT_TOKEN 认证、不做任何支付校验，漏一个渠道就等于把「凭空造
  已付订单」的能力交给持有该 token 的人。
- **前端 `PAYMENTS_ENABLED` 必须或上 `WECHAT_PAY_ENABLED`**。CN 的 crypto 与
  stripe 都是 false，漏掉这一行的话票价 UI 在唯一需要它的部署上整体消失，而
  症状会表现为「微信支付没反应」。
- **新增 openid 补全流程**（本文原方案没有）。JSAPI 下单必传 `payer.openid`，
  而邮箱注册的 CN 用户没有。`wechat_prepay` 返回 `code: "OPENID_REQUIRED"`，
  前端据此走 `/api/wechat/bind-openid` 的 `snsapi_base` 静默授权再回到结账页。
  绑定由 `POST /api/v1/auth/bind_wechat` 完成，**同时要求 JWT 与 NEXT_TOKEN**：
  JWT 说明是哪个账号，NEXT_TOKEN 说明 openid 来自刚用 AppSecret 换过码的服务端。
  只凭用户认证的话，任何人都能声称一个陌生人的 openid，从而接管其下次微信登录。
- **不实现「复用未过期的下单」**。Stripe 那边要复用 Checkout Session 是因为两个
  session 都能被支付；微信按 `out_trade_no`（即订单 id）唯一，同一订单只可能有
  一笔成功支付，重新下单是覆盖而不是并存。
- **sweeper 必须先关单再过期**。Stripe 的 session 会自己过期，微信订单不会——
  先释放库存再关单会留出一个「票已释放但仍可支付」的窗口。

### 5.2 落地文件

后端 `soon`：
`db/migrate/20260808120000_create_wechat_pay_settings.rb`、
`20260808120001_create_wechat_pay_events.rb`、
`app/models/{wechat_pay_setting,wechat_pay_event,payment_method,coupon}.rb`、
`app/services/wechat_pay_gateway.rb`、
`app/services/ticketing/quote.rb`、
`app/controllers/api/v1/{tickets,wechat_pay_webhooks,auth}_controller.rb`、
`app/jobs/{wechat_pay_webhook,ticketing_sweeper}_job.rb`、
`lib/tasks/wechat_pay.rake`、`ginger.cn.yml`。

前端 `seastar-app`：
`src/app/config.ts`、`src/utils/{payment_setting,wechat_pay}.ts`、
`src/app/api/wechat/{wechat.ts,bind-openid/route.ts,bind-openid/callback/route.ts}`、
`src/components/client/DialogTicket.tsx`、
`src/app/(normal)/event/[grouphandle]/create/TicketForm.tsx`、
`src/app/(normal)/event/detail/[eventid]/PaymentReturn.tsx`（原 `StripePaymentReturn`，
现在两条渠道共用）、`packages/sola-sdk/src/wechat/`、`src/lang/{en,zh}.ts`。

### 5.3 已验证 / 未验证

已验证（`bin/rails test` 849 runs 全绿，另有对真实运行中的服务器的探测）：

- 签名 / 验签 / AES-256-GCM 解密全部用真实密钥对与真实 APIv3 密钥往返，不是 stub。
- 完整链路测试 `wechat_purchase_journey_test.rb`：建票 → 下单 → 预支付 →
  签名回调确认 → 退款 → 退款回调结算，库存恰好回收一次。
  **这个测试抓到了一个真 bug**：`build_paid_ticket_item` 漏写
  `wechat_pay_setting_id`，导致每一笔真实订单在预支付时都会因商户为空而失败。
  各单元测试都通过，因为它们各自直接构造了带商户的订单。
- 对真实 HTTP 服务器：签名回调 → 204 且资源解密正确（验证了 header 大小写在
  Rack 下的映射）、重复投递 → 204 且只入库一次、篡改报文 → 401、
  15 分钟前的有效签名（重放）→ 401。
- `wechat_pay:install` 首次创建、二次更新不重复建行、单行 PEM 的 `\n` 转义能
  还原并真正签名成功；把**证书**误填成私钥会被拒绝并给出改法。

**对真实商户 API 的只读探测**（2026-08-08，凭据齐备后补做，未产生任何订单）：

- `GET /v3/pay/transactions/out-trade-no/<不存在的订单号>` →
  `404 {"code":"ORDER_NOT_EXIST","message":"订单不存在"}`。
  **签名被接受**——这是本地测试永远证明不了的一件事：本地签名与验签用的是同一
  套代码，规范化串（canonical string）的布局写错了也会自洽通过。
- **这次探测抓到一个真 bug**：`query_order` 里判断的是 `ORDERNOTEXIST`（v2 时代
  文档里的拼写），真实接口返回的是 **`ORDER_NOT_EXIST`**。不匹配的话，未支付
  订单会被当成「问不到」而不是「没付」，sweeper 于是**永远跳过它、库存永不释放**，
  并且每 5 分钟打一条警告。已改为同时接受两种拼写，并补了 sweeper 层的断言。
- `POST /v3/pay/transactions/jsapi` 用一个伪造 openid（真实与畸形两种都试过）→
  `400 {"code":"PARAM_ERROR","message":"无效的openid"}`，**没有**
  `APPID_MCHID_NOT_MATCH`、**没有** `NOAUTH`。
  可以确定的是：签名通过、商户号被识别。至于 appid 关联与 JSAPI 权限，
  微信的参数校验顺序没有文档，所以这只是**强证据而非证明**——唯一的结论性验证
  是拿一个真实 openid 下一次单。

**真机验证：核心链路已全部跑通**（2026-08-08，微信内置浏览器，真实收款与退款）：

| 环节 | 状态 |
|---|---|
| JSAPI 下单 → 调起支付 → 真实付款 | ✅ |
| 支付回调确认，订单转 succeeded | ✅ |
| sweeper 超时**关单**并释放库存 | ✅（那笔 timeout 订单） |
| 退款 → 退款回调 → 释放座位、取消参与者 | ✅ |
| 与微信侧对账（`query_order` 返回 `REFUND`） | ✅ |

仍未真机验证的一条：**`snsapi_base` 静默授权补 openid**。几次付款都是用已有
openid 的账号做的，邮箱注册账号那条路还没跑过——它也是这次唯一全新写、且完全
没被真实流量走过的链路。

> 参照 Stripe 那次的经验（PAYMENTS_PLAN §7.4），真实接口总会有字段级出入。这次
> 一共撞到两处，都不是靠读文档能预见的：`ORDER_NOT_EXIST` 的拼写（§5.3 上文），
> 和退款接口的响应压缩（§5.7）。前者一次只读查询就暴露了，后者要等到真的退一笔钱。

### 5.4 部署前必须完成

1. **凭据补齐** —— 状态（2026-08-08 复核）：

   | 凭据 | 状态 |
   |---|---|
   | 商户号 `1115981704` | ✅ |
   | appid `wxdf1ef2c65db36224` | ✅ |
   | 证书序列号 | ✅ 与证书内 serial 实测一致 |
   | APIv3 密钥 | ✅ 32 字节 |
   | 微信支付公钥 `wxpay_pub_key.pem` + `PUB_KEY_ID_…` | ✅ 2048-bit RSA，已实测能经转义 env 往返并被 `notify_public_key` 加载 |
   | 商户 API 证书私钥 `apiclient_key.pem` | ✅ 位于 `cert/1115981704_20260808_cert/`，已实测 |

   私钥核对结果（`openssl`，2026-08-08）：未加密的 PKCS#8、2048-bit、modulus 与
   `apiclient_cert.pem` **及**文档里那张证书三者完全一致，签名能被证书公钥验证
   通过（`Verified OK`），证书 serial 与 `WECHAT_PAY_CERT_SERIAL` 一致。
   随后用它对真实商户 API 发起的只读查询被微信接受（见 §5.3）。

   > 留档，因为这个坑很容易再踩一次：同一个目录里的三个文件只有一个能签名，
   > `wechat_credentials.md` 先后贴过的两种都不行。
   >
   > - `-----BEGIN CERTIFICATE-----` 是 **`apiclient_cert.pem`**（证书），装的是
   >   **公钥**那一半——`openssl rsa -check` 对它的回答就是 "Could not find
   >   private key"。证书是给对方验签用的，签不了任何东西。
   > - `-----BEGIN CERTIFICATE REQUEST-----` 是 **CSR**（证书请求），是「公钥 +
   >   主体信息，再用私钥签个名」，交给 CA 换证书用的。**同样不是私钥。**
   >   CSR 的存在只说明私钥当时确实生成过。
   >
   > 能签名的是 `-----BEGIN PRIVATE KEY-----` 开头的 `apiclient_key.pem`。三个
   > 文件都由商户平台的证书工具**一次性在本地生成**，所以手上有 CSR 或证书，
   > 私钥基本就在同一个目录里——先去那里找，不要急着重新申请（重新申请会让旧
   > 证书失效，`WECHAT_PAY_CERT_SERIAL` 得跟着换）。核对是否配套：
   >
   > ```bash
   > openssl rsa  -in apiclient_key.pem  -noout -modulus
   > openssl x509 -in apiclient_cert.pem -noout -modulus   # 两条必须完全相同
   > ```

   写入 `.env.cn.production` 时 PEM 要压成单行（`\n` 转义），已实测可还原：

   ```bash
   echo "WECHAT_PAY_PRIVATE_KEY=$(awk '{printf "%s\\n", $0}' apiclient_key.pem)"
   echo "WECHAT_PAY_PUBLIC_KEY=$(awk '{printf "%s\\n", $0}' wxpay_pub_key.pem)"
   ```
2. **商户平台配置** —— APPID 关联服务号 `wxdf1ef2c65db36224`（支付 appid 必须
   与签发 openid 的 appid 一致）、开通 JSAPI 支付、支付授权目录填
   `https://www.juluo.xyz/`。
   §5.3 的下单探测**没有**报 `APPID_MCHID_NOT_MATCH` 或 `NOAUTH`，说明前两项
   很可能已经配好了；但微信的参数校验顺序无文档，所以**仍需在商户平台上目视
   确认一遍**，尤其是支付授权目录——那一项在下单阶段根本不会被校验，只在浏览器
   调起支付时才生效，探测不到。
3. **`api.juluo.xyz` 的 ICP 备案确认** —— notify_url 域名要求备案（§4.3 至今未核实）。
4. **`rails wechat_pay:install`** —— 部署后手动执行一次；`ginger.cn.yml` 已注入
   所需的 `WECHAT_PAY_*`。凭据轮换时重跑同一条命令。
5. **`NEXT_PUBLIC_WECHAT_PAY_ENABLED="true"` 写入 `seastar-app/.env.cn.production`**
   （gitignored，不在本仓库里）。SG 的 `.env.production` **不加**。
6. **二清合规确认**（§4.2）。

> `wechat_credentials.md` / `wxpay_pub_key.pem` 都在工作区根目录下。根目录本身
> 是个 git 仓库，此前**没有 .gitignore**，`git add .` 会把 APIv3 密钥直接提交
> 进去。已补上（`soma/.gitignore`：凭据、`*.pem`、`.env*`、数据库 dump）。
> 长期正确的位置仍是 `.env.cn.production`。

### 5.5 CN 上线记录（2026-08-08）

**分支未合并。** 生产跑的是 `wechat-pay` 分支的镜像，`main` 保持在
`soon 9aeb803` / `seastar-app 38b31d5`。功能成熟前不并入 main，是刻意的。

```
soon         09e178d → registry.juluo.xyz/soon:09e178d          Nomad healthy
seastar-app  c528229 → registry.juluo.xyz/seastar-app:c528229   Nomad healthy
商户          1115981704 → wechat_pay_settings 3mskt7jn6gi63
```

部署命令（两个仓库各自根目录，**必须带 `-c ginger.cn.yml`**，不带就部到 SG 了）：

```bash
cd soon        && ginger deploy -c ginger.cn.yml
ssh root@juluo.xyz 'docker exec <soon 容器> bin/rails wechat_pay:install'
cd seastar-app && ginger deploy -c ginger.cn.yml
```

顺序有意义：先后端、装商户、再前端。反过来的话组织者能看到「添加微信支付」
按钮但保存会失败（没有商户可挂）。

上线后的生产实测：

- 容器内 `query_order` → `{"trade_state"=>"NOTPAY"}`，即生产环境的签名被微信接受。
- `notify_url` = `https://api.juluo.xyz/api/v1/webhooks/wechat/3mskt7jn6gi63`，
  公网 POST 无签名报文 → `401 {"code":"FAIL",...}`，未知商户 id → `unknown merchant`。
- 前端镜像内 `.env.production` 含 `NEXT_PUBLIC_WECHAT_PAY_ENABLED="true"`；
  客户端 bundle 里 inline 了 `api.juluo.xyz`，证明构建确实读的是 CN 那份 env
  （即微信渠道没有被开关过滤掉——编译产物里是 `"wechat"===a&&!z.UQ`）。

#### 一个会静默毁掉私钥的坑：.env 里的 PEM 必须**单引号**

写成不带引号的 `WECHAT_PAY_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\nMIIE…`，
dotenv 会把 `\n` 的**反斜杠当转义符吃掉、又不插入换行**：

```
写进去:  -----BEGIN PRIVATE KEY-----\nMIIEvQIBADA…
读出来:  -----BEGIN PRIVATE KEY-----nMIIEvQIBADA…      ← 每个换行变成字母 n
```

私钥直接报废。单引号的值 dotenv 不做任何转义处理，字面 `\n` 原样送到
install 任务再还原。`wechat_pay.rake` 里的 `pem()` 会专门认出这种「换行变成
字母 n」的形态并指名道姓地报错——否则模型层给出的是「请用 apiclient_key.pem
而不是证书」，会把人引到完全错误的方向。

### 5.6 上线后立刻暴露的两个老问题

CN 在微信支付之前**从来没有过可购买的票**（crypto 与 Stripe 都关着），所以这
两个 main 上早就存在的问题今天才第一次被撞到。都已修复并部署
（`seastar-app c528229`）。

1. **票价单位写死成 USD** —— `displayTicketPrice`（`utils/index.ts`）直接在返回
   字符串里拼 `USD`。¥1 的票渲染成 `1 USD`，在买家做决定的那块屏幕上把价格说
   错了近 7 倍。现在单位取自 `payment_method.currency`，加密货币回落到 token
   名；**不同币种不合并成区间**（可用 ¥1 或 5 USDT 支付是两个报价，合并等于
   凭空发明汇率）。单位读 `currency` 而非 token 表，是因为那才是实际扣款/退款
   的币种，而且后端从不强制 `token_name`。

2. **「加入活动(RSVP)」按钮根本没连到支付** —— 它是个
   `<a href="?tab=tickets">`，同一个页面加个查询参数，按下去看着就是刷新，而
   它展开的票列表在首屏之下。买家读到的信息是「按钮坏了」。
   现在是客户端按钮：只有一种票时直接打开购票弹窗，多种票才跳 tab。未登录也
   放行——弹窗里有登录按钮，比一个点了没反应的按钮更能说明下一步。

   > 教训留档：**微信 JSAPI 只在弹窗的「支付」按钮之后调用**
   > （`invokeWechatPay` → `WeixinJSBridge.invoke('getBrandWCPayRequest')`，
   > 全前端仅此一处）。排查「没有调起微信支付」时，先确认流程是否真的走到了
   > 那一步，而不是先怀疑签名或配置。

### 5.7 退款 500：一个只有真实退款才会暴露的坑

第一次真实退款返回了 **500**,但**钱退成功了**——回调把订单、座位、参与者全部
正确收尾了。异常发生在**读响应**这一步,发生在微信已经受理退款之后。

```
Zlib::DataError (incorrect header check)
  app/services/wechat_pay_gateway.rb:in 'request'
```

`Net::HTTP` 默认发 `Accept-Encoding: gzip…` 并自动解压回包。查单和下单的响应
没有被压缩,所以一路正常;退款接口回的东西它解不开,于是抛异常。

关键在于**这个默认值关不掉**——除非在**构造函数的 initheader 里**传
accept-encoding:

```ruby
Net::HTTP::Post.new(uri)                      # 之后再 req["Accept-Encoding"]= 无效
Net::HTTP::Post.new(uri, {"Accept-Encoding" => "identity"})   # 只有这样才行
```

`@decode_content` 在构造时就定死了。「事后赋值来不及」这件事不可发现,也正是它
躲过 review 的原因。

#### 比 500 更危险的那一半

修的时候差点犯一个更严重的错误:把 `Zlib::DataError` 直接归进
`WechatPayGateway::Error`。那样控制器会走这条分支——

```ruby
rescue Stripe::StripeError, WechatPayGateway::Error => e
  refund.update!(status: "failed", ...)
```

——把一笔**已经成功**的退款记成 `failed`。组织者看到失败会再点一次,**部分退款
就会退两次**(全额退有 `index_refunds_one_live_full_refund_per_item` 唯一索引挡
着,部分退没有)。

所以现在分成两个类:

| 类 | 含义 | 处理 |
|---|---|---|
| `WechatPayGateway::Error` | 微信答复了,并且拒绝 | 记 `failed`,释放索引,可重试 |
| `WechatPayGateway::Unreachable` | 请求发出去了,**读不到答复** | 保持 `pending`,返回 `awaiting_confirmation`,交给回调/对账,**绝不暗示重试** |

`Unreachable < Error`,所以 `query_order` / `close_order` 里既有的 `rescue Error`
仍然把它读成「问不到」,行为不变。这和文档里早就在用的
**「问不到 ≠ 没付」**是同一条原则,只是这次施加到了退款上。

#### 换成 httpx

`Net::HTTP` 还有第二个静默默认值:

```ruby
Net::HTTP.start(host, port, use_ssl: true)   # p_addr 默认 :ENV
```

它**读 `http_proxy`**。开发机上三个代理变量都设着(见根 CLAUDE.md 的「本地环境
陷阱」),也就是说本地每一次调微信的请求都在走 SOCKS 代理。生产没设所以没出事,
但这是随时会咬人的。

`httpx` 本来就在 `Gemfile` 里且**无人使用**,而这个文件是全项目最后一个
`Net::HTTP` 调用者,所以换掉的成本是零。它:

- 不读代理环境变量,除非显式要;
- 把传输故障作为 `HTTPX::ErrorResponse` **返回**而不是抛异常——正好对上上面
  那个 `Unreachable` 划分,它覆盖的一切(连接失败、超时、TLS、body 截断)含义
  都是「说不准」;
- `Accept-Encoding: identity` 仍然显式发送。不要钱,而且写出意图比赌某个库的
  默认值不变要好。

上线后对真实接口复验:空 body(不存在的订单号)和有内容的 body(真实已付订单)
都读得回来——退款那个 500 是读**非空**响应时炸的,只测空响应证明不了什么。
随后的真实退款返回 200,微信侧 `query_order` 返回 `REFUND`,两边对上。
