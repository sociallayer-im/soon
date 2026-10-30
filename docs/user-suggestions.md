# 发现人物 API

GET `/api/v1/users/suggestions?city=上海&limit=4&page=1`，允许匿名，登录可个性化排除。路由必须放在 `/users/:id` 之前，避免 suggestions 被解释为用户名。

推荐池只包含 active、具有用户名、data.visibility 未设置或为 public 的用户，并且必须在 active 节点下拥有尚未结束的 published normal/open_registration 活动。city 精确匹配活动所属节点 group.city；不是按用户自填城市推断活动城市。无 city 时发现所有城市。暂不推荐仅报名用户、私有活动用户或任意新注册账号，不读取通讯录、手机号或邮箱。

登录时排除当前用户及 active/pending 关注关系目标。按用户 created_at desc、id desc 稳定分页；这是一套可解释的活动发起人发现规则，不是热度评分或随机排序。变更关注后分页可能自然变化。空候选返回 data: []，标准 meta，前端正常展示空状态；网络错误显示重试，不再以 404 回退到 discover。

响应仅包含 id/name/nickname/image_url/bio/city/recommendation_reason，独立蓝图禁止意外继承账号字段。推荐理由为“同城活动发起人”或“公开活动发起人”。参数 limit/page 遵循现有 API 分页限制；city 最长 100 字符。
