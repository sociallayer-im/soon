# WiConnect 使用 Surf 身份

## 接口

`GET /api/v1/oauth/identity?group_id=<Surf群组ID>`

使用用户授权给调用应用的 OAuth Access Token：`Authorization: Bearer <access_token>`。不是 Surf 小程序的登录 JWT，不是客户端管理员密钥。必须获得 `openid` scope；读取群组关系另需 `groups:read`，读取昵称头像另需 `profile`。所有响应禁止缓存。

示例响应（示例 ID，无真实用户数据）：

```json
{
  "issuer": "https://surf-api.sola.day",
  "subject": "SURF_USER_ID",
  "username": "example-user",
  "nickname": "示例用户",
  "avatar_url": "https://example.com/avatar.png",
  "expires_at": 1793451600,
  "scope": "openid profile groups:read",
  "group": {
    "id": "SURF_GROUP_ID",
    "member": true,
    "role": "member",
    "expires_at": null
  }
}
```

- 主体稳定标识为 `(issuer, subject)`，不是用户名或昵称。issuer 来自部署的 `OAUTH_ISSUER`，部署前必须设为 `https://surf-api.sola.day`，不可使用开发默认 localhost。
- 没有 profile 授权时不返回 username/nickname/avatar_url；无用户名的账号也可能返回空值，调用方可用 subject 作为内部标识。
- 不传 group_id 时不查询或返回群组信息。传入的是 ID，不是显示名称/handle。
- 有效成员：memberships.active=true、expires_at 为空或在未来、角色为 owner/manager/member，且群组 active=true、review_status=approved。
- 没有成员关系、关系失效、群组不存在/未批准/停用时统一返回 `member:false,role:null,expires_at:null`，不泄露群组是否存在。平台超级管理员不自动算所有群组成员。
- 顶层 expires_at 是 OAuth token 到期时间，group.expires_at 是成员资格到期时间；都为 UTC Unix 秒。无到期的成员资格为 null。
- 不返回手机号、邮箱、微信 openid、支付记录、平台管理员身份或全量群组列表。

## WiConnect 对接流程

1. 在 Surf 注册 WiConnect OAuth 应用，固定准确的 HTTPS callback 地址，仅申请 `openid profile groups:read`。现有接口 `POST /api/v1/oauth/applications`，应用管理/激活沿用 `OauthApplicationsController`。生产 client_secret 只保存到 WiConnect 服务端。
2. 用户在 Surf 登录并授权；沿用 `/api/v1/oauth/authorize`、`/api/v1/oauth/token` 授权码 + PKCE S256 流程。不要在 WiConnect 收集/转发 Surf 用户密码。
3. WiConnect 服务端在本地登录会话中保存授权 token，将其交给 `/api/v1/oauth/identity`；如果需要某个群组资格，传网关配置中固定的 group_id。不可让浏览器自行选择另一个允许上网的群组。
4. 验证 issuer、读取稳定 subject；按 WiConnect 自己的规则判断 group.member 与角色。Surf 返回身份事实，不直接授予网络权限。
5. 仍由 WiConnect 使用可信网关生成的 attempt/MAC/IP/context 签发网络 Grant，不能信任浏览器自行提交的 MAC/IP。
6. 401 时停止新授权并要求刷新/重新登录，403 scope不足时重新征得授权；网络故障不要当作身份验证成功。可用 `/api/v1/oauth/revoke` 主动撤销 OAuth token。

现有刷新 token 接口继续可用。身份查询不延长 token 或成员期限。若要求联网权限不超过成员资格期限，WiConnect 签发期限应取自身策略与成员资格截止时间的较早值；是否允许断云宽限、退出 Surf 是否立即断网等仍是 WiConnect 的独立策略，不能默认由这个查询接口保证。需要即时撤销已有网络权限时还须接入主动撤销/周期重查。

WiConnect 当前 IdentityProvider 接口依赖账号密码登录语义；本次只完成 Surf 侧 API，未修改其 HTML 登录流程、实现 OAuth callback 或设置生产 OAuth 应用，也未部署。接入时需补 callback 和 OAuth 身份提供者适配，不能直接把本接口当作密码登录接口。

## 错误和查询性能

- 401 invalid_token：token 不存在、过期、被撤销，应用停用或用户 active=false；缺 Bearer 返回401 invalid_request。
- 403 insufficient_scope：缺 openid，或带 group_id 但缺 groups:read，带 WWW-Authenticate 指明范围。
- 400 invalid_request：group_id 非单个合法 ID。
- 复用现有 token_digest 唯一索引与 membership(user_id,group_id) 唯一索引，仅查一个关系；不枚举群组，不依赖 UserInfo 的100条列表上限，不新增迁移。
- 同时让已有 OAuth UserInfo 拒绝 inactive 用户，以免身份端点拒绝后从 UserInfo 绕过该状态检查。

## 验证

集成测试覆盖最小字段、禁止缓存、scope隔离、普通JWT拒绝、过期/撤销、应用/账号停用、三类群组角色、成员过期/停用、群组未审/停用、不泄露他人关系，以及授权码/PKCE换取token、查询身份和撤销后的完整流程。所有验证使用本地测试库，无真实用户凭据或网络授权变更。
