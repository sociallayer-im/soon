# 活动入场凭证与签到

GET `/api/v1/events/:event_id/participants/ticket_pass` 需要本人登录及该活动报名，返回 participant、tickets（订单明细）、token、expires_in。只有 attending 且无订单或至少一笔有效已支付订单的报名产生二维码。待审核、待支付、取消、全额退款不产生凭证。

客户端将 `surf-ticket:` + token 在本地绘制为二维码。token 通过 Rails message_verifier 的 event-ticket verifier 签名，purpose 为 check_in，绑定活动 ID、报名 ID、报名时间；15 分钟过期，不应写入日志或第三方二维码服务。重新报名后旧凭证不再匹配。

POST `/api/v1/events/:event_id/participants/check_in` 接受 token（扫码）或 user_id（管理员名单手动签到），仍由 EventPolicy update? 授权。签到事务内锁定报名并刷新支付汇总，验证 attending 与有效支付；重复请求保留首次 checked_in_at，不修改 registered_at。

Seastar 仅在二维码中携带 profile_id；Surf 使用签名活动凭证，同时保留授权管理员手动签到。二维码是可转发的短期凭证，工作人员仍应核对名单姓名；没有引入支付或自助签到绕过。

验收：参与者凭证 → 管理员扫该活动的二维码 → 名单已签到；重复扫描时间不变；其他活动、伪造、过期、取消、未审核、未支付及退款凭证被拒绝。代码测试不替代真机相机与真实支付验收。
