# Surf 演示数据

2026-10-28 写入 https://soon.generic.dev 使用的独立 `soon_atlas` 测试数据库。

## 数据清单

- `surf-demo-city` / `3mywxw3jmbgrr`：Surf 城市漫游（演示），上海。
- `surf-demo-makers` / `3mywxw4anwkrr`：Surf 灵感共创（演示），杭州。
- 6 位虚拟用户：`surf-demo-{lin,summer,chen,momo,iris,river}`，邮箱使用保留的 `.invalid` 域名，不绑定微信或真实手机，不授予平台管理权限。
- 每个社区 6 位成员、1 个公开讨论板、3 篇帖子、3 场已发布免费活动。
- 合计 12 条回复、24 条报名记录。活动每场分别有 3、4、5 位参与者。
- 社区、帖子、活动和用户都有图片，引用 Surf 已部署的 `/assets/*.png` 素材。
- 活动、地点、帖子、用户明确标记为演示，非真实线下招募。

## 执行

脚本：`script/seed_surf_demo.rb`。不会由 `db:seed` 自动执行；只允许目标数据库名为 `soon_atlas`。

在正确运行容器中通过 Rails runner 执行（容器名称随部署变化）：

```sh
ssh ubuntu@generic.dev 'docker exec -i <current-soon-container> bin/rails runner -' < script/seed_surf_demo.rb
```

脚本使用稳定 handle、slug 和自然键，事务内写入；重复执行更新同一批演示数据。已过期活动会重新安排到执行日后 1–3 天，仍有效活动保持原日期。对已占用但没有演示标记的用户/社区 handle 拒绝覆盖。不修改真实账号、凭证、支付或邮件配置，不调用发送通知的控制器/任务。正常模型验证及计数回调仍执行。

## 验证结果

- Ruby 语法检查通过。
- 在运行容器执行成功，再执行一次，用户/社区 ID 和帖子/活动数量一致。
- 公网 `/api/v1/discover` 返回两个演示社区、6 场演示活动。
- `/api/v1/topics?group_id=...` 每个社区返回 3 篇帖子。
- 7 个引用的图片 URL 均为 HTTP 200 / image/png。

未修改后端服务源码或运行配置，无需重新部署。小程序图片能否显示仍取决于微信后台的 downloadFile 合法域名配置，应包含素材域名 `https://surf.generic.dev`。
