# Surf 原生微信登录验收记录

日期：2026-10-28（Asia/Shanghai）。

## 结果

真实微信登录已在微信开发者工具中通过：小程序使用新的 `wx.login` 临时代码调用 Soon，取得并保存 Soon 会话；随后携带该会话调用 `GET /api/v1/users/me` 成功。

本轮阻塞登录的根因在客户端：开发者工具启用合法域名校验，`https://soon.generic.dev` 不在当前小程序的域名列表中，`wx.request` 在发往服务端前返回 `request:fail url not in domain list`。用户授权后临时关闭开发者工具校验，真实登录和鉴权请求均成功。该豁免仅用于本次验收，不能替代微信管理后台的正式合法域名配置；恢复校验由客户端调试步骤负责。

没有发现需要修改 Soon 登录源码或再次通过 Atlas 发布的后端故障；未为重复验收重新部署、替换数据库或修改运行密钥。

## 后端与部署核对

- API：`https://soon.generic.dev`，前端：`https://surf.generic.dev`，维持前后端分域。
- 健康路径为 `/up`。API 服务的根路径 `/` 返回 404 不属于故障。
- 公网 `/.well-known/atlas/version` 确认 version `8`，部署 `dep_30ec5d94-3c63-4918-bec3-2bef6cfb0fe6`，源码提交 `1a7dececa8906f0db67a2d8f116814f5ed0fa42d`。
- 当时运行容器为 `app-4c08e366-d4dd-1c20-d9d9-146c19ad8693`。容器名随发布变化，后续核查应重新读取 Atlas 状态。
- 当前 `atlas.json` 使用原始 `Dockerfile`、上下文 `.`、端口 8080、健康检查 `/up`；本轮未使用历史文档中的合并镜像流程。
- 运行 AppID 为 `wxa0fde9108d775630`；运行 AppSecret 存在，且与权威私有文件 `/Users/jiang/zurich/surf/.env` 的 `WECHAT_MINI_SECRET`、本地 `.atlas/env.json` 的 `WECHAT_MINIPROGRAM_APP_SECRET` 匹配。仅比较值或摘要是否相等，未打印秘密、code 或 token。
- 权威字段映射：`WECHAT_MINI_APPID` → `WECHAT_MINIPROGRAM_APP_ID`，`WECHAT_MINI_SECRET` → `WECHAT_MINIPROGRAM_APP_SECRET`。

## 真实请求的服务端证据

由当前运行容器的结构化 HTTP 日志核对，日志时间为 UTC：

| UTC 时间 | 上海时间 | 请求 | 状态 | 耗时 |
| --- | --- | --- | --- | --- |
| 2026-10-28 14:16:54 | 2026-10-28 22:16:54 | `POST /api/v1/auth/wechat_miniprogram` | 200 | 1128 ms |
| 2026-10-28 14:16:58 | 2026-10-28 22:16:58 | `POST /api/v1/auth/wechat_miniprogram` | 200 | 935 ms |
| 2026-10-28 14:16:59 | 2026-10-28 22:16:59 | `GET /api/v1/users/me` | 200 | 22 ms |

客户端同时确认：`preview=false`，API 为线上 Soon，实际 AppID 与服务端一致；登录后 `tokenStored=true`、用户存在、登录页进入资料注册步骤；随后 `api.user()` 返回有 ID 的用户。未使用 mock、预览用户、伪造 token 或无效 code 代替真实登录验收。

服务端之后还记录了 `PATCH /api/v1/users/me` 先返回 422，再于 14:17:08 UTC 返回 200。该记录与资料注册操作分开看待，不把后续资料校验错误解释为微信身份交换失败；本记录不保存用户资料正文。

## 验收边界与上线前操作

- 已完成：开发者工具中真实微信 code → Soon session → 已鉴权用户信息请求。
- 尚需正式配置：在该 AppID 的微信管理后台添加 `https://soon.generic.dev` 为 request 合法域名；上传与下载资源按实际使用配置相应合法域名。
- 尚未验收：恢复域名校验后的再次登录、真机登录、手机号短信绑定、支付等独立流程。本记录不会用无效 code 被拒绝、接口存在或临时关闭校验的成功结果替代这些验收。
- 本轮没有在本地启动 Docker/QEMU，没有新增 Nomad/Traefik，没有打印或提交凭据，没有修改当前容器文件代替源码发布。
