# 城市与系列活动（2026-10-29）

参考 `/Users/jiang/zurich/706mini/706mini/miniprogram/lib/forms.js`、`preview-records.js` 和 `docs/data-integration/design-schema.md` 的 campaign 字段。706mini 的专题汇集已有活动，并非 recurring 的重复排期；Surf 原有 recurring / track 保持各自用途。

## 数据结构

- `groups.city`：可空、最长 100 字符、去首尾空白，空字符串存 NULL，有索引。与自由文本详细地址 `location` 独立，不从旧地址自动推断城市，也不新增城市主数据表。
- `campaigns`：TSID 主键，group_id、owner_id、title、kicker、introduction（Markdown 文本）、cover_url、media（最多 12 张 HTTP(S) 图片）、resource_links（最多 50 个 HTTP(S) 链接）、status、时间戳。
- `campaign_events`：campaign_id、event_id、position，组合唯一索引与数据库外键。支持一个活动属于多个系列、跨节点和跨城市收录、用户指定顺序。
- 删除系列保留活动；删除活动清理关联；删除所属节点或创建者清理系列。

## 接口

统一前缀 `/api/v1`。

| 接口 | 用途 |
| --- | --- |
| GET /cities | 活跃节点的非空城市去重列表，返回 `{data: ["北京", "杭州"]}` |
| POST /groups、PATCH /groups/:id | group.city 保存，沿用节点创建/管理权限 |
| GET /groups?city=杭州 | 当前用户加入的指定城市节点 |
| GET /groups/directory?city=杭州 | 公开城市节点列表 |
| GET /events?city=杭州 | 按活动所属节点的城市筛选 |
| GET /campaigns | 分页系列列表，支持 group_id、city |
| GET /campaigns/:id | 系列详情、可见活动 event_ids、派生 cities、can_edit |
| POST /campaigns | 创建（campaign 参数对象） |
| PATCH /campaigns/:id | 更新元数据和关联活动 |
| DELETE /campaigns/:id | 删除系列 |
| GET /events?campaign_id=:id | 读取系列内可见活动的完整卡片，沿用活动列表分页和时间排序 |

带 city 或 campaign_id 的活动查询是发现查询，不再额外限定“我加入的节点”；仍沿用 Event.visible_to。系列详情 event_ids 按收录顺序返回；需要相同顺序时客户端按这些 id 排列卡片。城市筛选按系列内当前可见活动的节点城市匹配，不仅按系列所属节点。

请求示例：

```json
{
  "campaign": {
    "group_id": "节点ID",
    "title": "城市共读系列",
    "kicker": "每周相聚",
    "introduction": "## 关于系列\n跨城市的阅读活动。",
    "status": "published",
    "media": [{"type": "image", "url": "https://example.com/cover.jpg"}],
    "event_ids": ["活动ID1", "活动ID2"],
    "resource_links": ["https://example.com/reading"]
  }
}
```

## 权限、状态与边界

- 创建需要所属节点管理权限（含平台管理员）；编辑/删除允许创建者或节点管理者。group_id、owner_id 创建后不能通过更新转移。
- 状态采用 Surf 的小写 `draft / published / archived`。未迁移 706mini 的多方审核、审核轮次及发起人确认流程；当前不存在相关审批模型，不伪造审批已通过。
- 公开列表仅展示 published；创建者、节点管理者可看到自己的 draft/archived；平台管理员可查看全部。匿名访问未发布详情返回 403。
- 发布必须有介绍和至少一个活动；关联活动最多 200 个、去重，发布时全部必须为公开 published 活动。草稿可关联本人可编辑的非公开活动。收录公开活动不授予编辑活动的权限。
- 保存元数据和替换活动在同一事务中，失败全部回滚。省略 event_ids 保持原关联，传 [] 清空（已发布系列不能清空）。
- 已收录活动后续变为草稿/取消/隐藏时，响应动态使用 Event.visible_to 筛选，不泄漏活动 ID 或城市。系列不会自动下架，可能暂时显示为空。
- cover_url 未设置时派生自 media 第一张图片；使用现有上传接口取得图片 URL。
- 本轮仅实现后端：没有小程序城市选择器、专题编辑/详情页面，也未部署线上数据库迁移。

## 验证

本地执行 db:migrate；集成测试覆盖城市写入、标准化和筛选，跨城系列创建/顺序/去重，草稿权限、匿名写入、非法关联和 URL 拒绝、事务回滚、省略/清空语义、不可转移所属节点、隐藏活动动态过滤、删除级联及活动保留。
