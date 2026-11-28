# 用户和节点关注

`GET /api/v1/follows?user_id=...&include=profiles` 返回指定用户的关注；`direction=followers&target_id=...&target_type=User|Group` 返回关注者。省略 user_id 或使用 me 时要求登录，其他公开个人页面列表允许匿名读取。

`POST /api/v1/follows {target_type,target_id}` 要求登录，仅创建当前用户的关系。重复关注复用关系；禁止自关注。`DELETE /api/v1/follows/:id` 仅允许关系创建者取消。嵌入用户使用公开资料蓝图，不暴露邮箱、手机和微信身份。

迁移 20261029020000 创建 follows 表，数据库约束保证关系唯一、合法目标类型/状态及禁止自关注。UserMerger 迁移入站/出站关系，去重并剔除合并产生的自关注；用户或节点删除清理对应关系。

2026-10-30 提交与部署前验证：Follow 模型、控制器、UserSuggestions 与 UserMergerTeam 共 18 项测试、87 个断言通过，zeitwerk:check 通过。前端类型检查、小程序 dist/dist-preview 构建通过。本次只部署后端，不发布 Web。
