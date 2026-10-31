
## 2026-10-30 帖子与活动关联修复
- 实现 GET/POST events/:event_id/discussion；关联帖子保存 event_id，复用节点分类可见性、发帖权限和限流。
- 同步社区与仅活动内讨论共用 Topic；社区列表过滤未同步内容，禁止非公开活动同步。
- 新增回归覆盖关联发布、列表同步隔离和权限拒绝；讨论、专题测试通过。

## 2026-10-30 所有节点默认开放帖子
- 根据用户要求，现有节点统一启用 discussion_enabled、can_post_topic=everyone（登录用户可发布），新节点数据库默认值同步调整。
- 新节点自动提供公开“日常分享”分类；迁移仅补充缺失公开分类，保留现有私密/归档分类及其权限。
- 保留管理员主动关闭能力；删除空节点清理空分类，有帖子时保留删除保护并正确返回错误。
- 节点、分类权限、帖子关联、Campaign 等 82 项测试、299 个断言通过。
- 前一版关联接口已部署 dep_2a145fd1-379b-4ae3-abb0-64c6754fcfc7，公网关联讨论、分类、专题接口均为 200。
- Atlas 默认开放版本部署成功：dep_a275ad3a-7449-4768-88be-1075c818a66d，源码 f31a4e8。健康检查、city-g 分类、活动讨论接口均返回 200；线上 4/4 节点已开放且具备公开分类，新节点默认值 true/everyone 已核对。

## 2026-10-30 手机号登录线上 404 修复
- 线上 21:08 两次 request_phone_code 返回 404；PHONE_LOGIN_ENABLED=false 且运行容器缺少短信凭证。微信和邮箱同期认证均为 200。
- 私密备份完整 Atlas 变量至 .atlas/backups/before-phone-login-20261030-211015/，从项目既有 .env.surf.production 补回三项阿里云短信配置并开启手机号登录，保留数据库、支付和邮件变量。
- 复用现有镜像部署 dep_44085793-9b3e-4894-b704-071c5f70cb0c 成功；健康检查 200，运行配置 ready；无手机号请求返回 422，接口不再 404。未发送真实测试短信，收码需用户验证。
- 手机登录测试 26 项、136 个断言通过。

## 2026-10-30 邮箱登录后验证手机号
- 邮箱认证成功且账号无手机号时，先引导短信验证，再进入 ID 完善/个人页；已绑定手机号不重复要求。
- 绑定既有手机号账号时，验证 bind_phone 专用验证码，锁定双方账号，迁移数据并返回新 JWT；携带邮箱及兼容登录身份，保留目标已有资料。
- 冲突邮箱/微信/钱包身份与管理员源账号明确拒绝，不覆盖、不丢失资料；事务保证失败回滚。
- 修复登录响应只含 id/email/name 的问题，改为私有 self 资料（含 phone、image_url）；不影响公开资料接口。
- 合并保留活动专题和提现记录。手机号/合并/微信认证共 39 项、187 个断言通过。
- Atlas 部署 dep_f881f1bc-d17b-44f7-ab05-b7b3b8c32f7c 成功，源码 c944ba8；公网健康检查 200、版本一致，手机号开关和短信配置保留。未操作真实用户合并，真实短信与客户端完整流程需新小程序版本验收。

## 2026-10-30 微信首次登录手机号授权
- 新增受登录保护的 auth/wechat_miniprogram_phone，微信专用手机号 code 在服务端兑换；验证返回号码、国家区号和 appid 水印，拒绝客户端自行断言手机号。
- 使用 stable_token、缓存服务端调用凭证；敏感 code 纳入日志过滤，不向客户端返回 access_token 或 AppSecret。
- 有手机号直接跳过；首次无手机号先授权，已有号码通过事务关联账号并刷新 session；支持短信验证替代。
- 服务与认证/绑定测试共 41 项、185 个断言通过，包含授权过期、跨 AppID 和身份来源校验。
- Atlas 部署 dep_561472c8-3b1f-4836-a0d1-45147b7cec30 成功（源码 62e7f61），公网 /up 和版本接口 200。
- 在线预检 stable_token 获取成功，getuserphonenumber 无效 code 返回微信 40029；未读取或保存真实用户手机号，真实授权待新小程序真机验收。

## 2026-10-30 按用户要求清除指定账号
- 最新指令为清除“我是你”及关联数据，不重新创建。唯一账号核对后，在事务内清除账号、3 场自建活动、3 篇帖子、回复/评论、参与与成员关系、相关票券和活动记录；保留群组本身和其他用户。
- 操作前使用 pg_dump 创建全库私密备份：.atlas/backups/delete-woshini-20261030-214417/surf-production.dump，目录 700、文件 600，未提交 Git。
- 操作后账号不存在，指向该用户的数据库外键引用为 0；4 个群组及另一指定用户保留，相关数量缓存已刷新。未进行支付或退款。


### 2026-10-30 · 统一 Surf 品牌文字

用户可见的 Sola / Social Layer 品牌文字统一为 Surf。保留域名、存储键和组件标识以保持兼容。同步邮件品牌、默认发件人显示名称及邮件主题测试。


### 2026-10-30 · 避免老用户重复授权手机号

微信登录响应增加 is_new_user 标记，仅新账号且手机号为空时进入手机号授权。已有账号无手机号也可正常重新登录。兼容旧后端缺少标记时不强制授权。前端 135 项测试及类型检查、小程序双构建通过；后端微信登录 5 项测试、23 个断言通过。


### 2026-10-30 · 关联活动和账号默认候选列表

关联活动自动加载最近 30 天至未来 30 天的已报名活动，再展示当前城市未来 30 天活动，合并按 ID 去重；输入标题继续搜索。角色账号默认按关注、当前社区成员、近期公开贡献者排列为连续列表，按用户 ID 去重并排除其他已选角色人员。新增认证接口 /users/role_candidates，仅按公开活动、公开帖子创建时间排序，响应不含手机号、邮箱或登录时间。联合主办/讲者直接获得既有协作权限，评委仅展示。前端 140 项测试、类型检查及双构建通过，后端候选接口相关 4 项测试 29 断言通过。后端接口尚需部署。


### 2026-10-30 · 群组创建审核与超级管理员管理中心

新增群组 review_status（pending/approved/rejected）、审核说明、审核时间和审核人字段；迁移保留既有群组 approved 状态。API 创建群组强制 pending + inactive，不接受客户端绕过；仅超级管理员可分页查看申请并批准/拒绝，拒绝必须说明原因，行锁防止并发重复审核。未通过群组不公开、不可发布活动/帖子，创建者可查看状态。个人页超级管理员显示管理中心，支持三种状态列表及批准/拒绝操作。前端类型检查及双构建通过，141 项测试通过；后端 31 项测试、116 断言通过。源码已完成，数据库迁移及接口需随后端部署生效。


### 2026-10-30 · 全流程类推修复与范围调整

修复创建成功返回表单、超时重试重复记录、活动名额/时区回填、分步地点与场地重试、角色列表异步竞态、候选分页和失败提示、全部城市、发布权限筛选、公开搜索范围、拒绝后重新送审及审核留痕。

按用户最新要求：手机号仅前端补充，不设置后端业务门槛，并取消旧的设置 ID 前手机号拦截；活动名额与票种库存独立，不增加合计或联动限制。新增 creation_receipts（幂等事务锁）与 group_review_logs（历史回填）迁移。未推送、未部署、未修改线上数据；前端详细清单见 docs/flow-audit-fixes-2026-10-30.md。

验证：前端 158 项测试、21 项布局检查、1 项模拟接口的 Web 绑定流程通过；类型检查、Web 构建及小程序双构建通过。后端全量 1,358 项、4,882 断言通过，随后新增公共范围相关专项 32 项、157 断言通过；审核历史专项 8 项、56 断言通过。

最终后端完整回归：1,359 项测试、4,884 个断言通过，0 失败、0 错误。两个并发创建请求返回同一群组，验证成功。手机号规则仅前端，票种与活动名额保持独立。


### 2026-10-30 · 帖子编辑删除接口验收

确认既有 PATCH/DELETE /api/v1/topics/:id 支持作者与群组管理者操作。新增关联活动帖子回归：陌生人修改/删除均 403，作者修改保留 event_id，删除后从活动讨论列表消失。帖子相关 30 项测试、139 断言通过；本次后端仅新增测试，无运行时代码变更。


### 2026-10-30 · 主办与嘉宾自动加入个人日程

attendee_id 查询包含活动 owner 和通过 User 账号或现有邮箱关联的角色，返回 is_event_team，并将这类活动标记为 is_attending。不会创建额外 Participant、支付订单或占用票库存；群组成员及仅展示名称不自动报名。关联嘉宾可以读取自己的非公开已发布活动及报名后说明，取消活动仍排除，评委不因此取得编辑权限。角色移除后隐式报名自然失效，实际报名保留。

新增4项回归覆盖主办、关联嘉宾、各角色、无账号名称、角色移除、非公开可见性及取消排除。全量1364项测试、4920断言通过，0失败、0错误。未推送、未部署。


### 2026-10-30 · 站内通知业务闭环

Activity增加nullable notification_key和(receiver_id,notification_key)部分唯一索引，兼容旧Activity。SiteNotifiable在业务保存事务中写站内消息；请求局部NotificationContext隔离发起人并保证异常后重置。覆盖报名审核、节点审核、活动发布通过/重要安排变更/取消、角色关联前后差异、成员角色变化、邀请/加入申请处理结果、帖子回复、真实支付确认、每笔退款结果及退款失败。按接收人去重，跳过自己触发的普通操作；旧直接成员角色变更Activity不重复生成。活动未读变更5分钟内合并，已读后的新变化创建新消息。

GET /activities/tasks按现有政策投影当前待处理事项：超级管理员审核节点，节点管理员审核活动/加入申请，活动owner和有编辑权的角色审核报名；评委不因此取得审核权。支持分页，已读不会完成任务，处理或权限移除后刷新即消失。邀请接受/拒绝、报名审核、发布批准使用行锁保护状态，旧请求不能覆盖已处理结果。GET /activities/summary仅返回本人未读/待办数；mark_read all:true仅修改本人记录。ActivityBlueprint新增中文标题/正文和按当前权限解析的详情跳转，删除目标没有跳转链接。

SiteNotificationReminderJob注册GoodJob每5分钟执行，查询未来2小时已发布活动，向有效已确认报名者、owner和关联嘉宾生成站内提醒；报名待审核、欠款、取消/拒绝报名不提醒，角色与报名重叠只生成一次。使用活动开始时间参与幂等键，改期后可再次提醒；重要变更或取消清理旧的未读开始提醒。仅使用站内消息，无微信授权/推送，无短信。活动发布审核沿用现有批准操作，本次不新增活动驳回状态。

部署需要执行新增迁移20261030235000（沿用Atlas入口db:prepare）；现有待办即查即得，不批量回填历史通知。验证：全量1378项测试、5015断言通过；最终专项109项、385断言通过。前端173项和27项布局检查、类型检查及双小程序构建通过。未推送、未部署。


### 2026-10-30 · 聚合推荐接口与查询索引

新增 GET /discovery/home（首页：推荐活动、个人赴约、节点、专题、城市选项）、GET /discovery/community（帖子、人物、节点、城市选项）、GET /discovery/feed（events/topics/groups/people的后续推荐页）。首页和社区各一个HTTP首屏请求，旧/discover及单资源接口保留兼容Web。规则为同城公开内容、关注/加入关系优先、时间排序；发现首屏给其他节点/作者留出位置，所有候选保留可翻页，关注动态严格按发布时间。用户来源从近期公开活动/帖子的作者中选取，优先共同节点，排除自己、已关注、隐藏和停用账号，不查询他人私密报名或登录时间。专题按同城即将发生的公开活动排序，不再由专题创建时间决定。

公共同城候选ID缓存60秒，race_condition_ttl为5秒；每次读取重新检查当前公开、审核、归档等条件，不缓存任何人的关系或个人日程。活动/帖子推荐窗口各最多120项、节点40项，人物最多120人；这是有边界的推荐窗口，不替代全量城市日历或搜索。游标为绑定身份、城市、类型与范围的15分钟签名快照，分页按候选ID批量取数，无数据库深OFFSET、无跨请求内存快照依赖。被隐藏/删除内容在游标页同样重新过滤。响应使用private,no-store，避免个人数据被共享HTTP缓存。

活动卡片不加载完整Markdown/报名后说明，帖子首屏正文最多1200字符，关联活动和节点名称批量嵌入，避免逐项请求。个人赴约通过owner、嘉宾、有效已付款/免费报名三个有索引的有界查询取得，再合并排序；不使用全事件历史上的大OR。关系只按用户批量读，公共卡片的成员数/活动数沿用已有标量计数，不逐项COUNT。

迁移20261031001000添加groups.browse_city（从city派生规范化，支持上海市/Shanghai等）与discovery_active_at并回填；20261031002000并发添加11个组合/部分索引，覆盖城市节点排序、公开活动开始/结束时间、个人活动、帖子创建时间、有效报名、个人/邮箱角色和共同节点成员；20261031003000补充公开活动贡献时间索引，总计12个新索引。索引DDL使用CONCURRENTLY；需要现有Atlas入口db:prepare部署执行，本次只迁移本地测试库。公开活动/帖子的可见性变化、软删除、恢复、标记/取消标记会维护活跃信号，按创建时间索引取最新一项，避免每次写入聚合扫描整个节点历史。

验证：后端全量1392项测试/5071断言通过，包含权限、跨城市、签名游标、共享缓存隔离、活跃信号、专题排序、多样性和查询预算。24张卡片数据下实际SELECT数量：首页17、社区19（包含认证与冷候选查询），低于35预算；无逐卡查询。EXPLAIN ANALYZE BUFFERS在分别6000条活动/帖子的本地事务样本上确认idx_events_discovery_end和idx_topics_discovery_created，执行约0.1–0.2ms（仅本地候选SQL样本，非线上端到端承诺）。前端175项测试、类型检查、Web构建、小程序dist/dist-preview双构建及27项布局检查通过。未推送、未部署、未发布小程序。


### 2026-10-30 · 创建群组时指定管理员

POST /groups接受可选顶层manager_ids。去重并排除创建者，最多10个；所有账号必须存在且active。与群组、创建者owner成员在同一事务中创建manager成员，向额外管理员写入站内任命消息；任何失败整笔回滚。创建者不被降级，群组仍pending/inactive等待平台审核，manager不取得超级管理员身份。沿用CreationReceipt幂等事务，重试不会重复群组/成员/通知。原有不传manager_ids的客户端行为不变。无需数据库迁移。

管理员账号输入复用/users/role_candidates的公开昵称/ID搜索；将keyword分支提前，搜索时不再先扫描全部活动/帖子聚合活跃度。空查询的既有角色候选行为不变；新群组表单在输入搜索词后才请求，限制20项候选。Markdown继续使用既有bio/content/about/notes字符串字段，无新增格式字段或权限。

验证：新增创建管理员专项3项/20断言，覆盖保留owner、重复ID/自己、审核状态、无效/停用账号回滚、幂等重试不重复通知；全量1395项/5091断言通过。搜索提前优化后的最终用户/管理员专项34项/93断言通过。前端180项、36项布局检查及小程序双构建通过。未推送、未部署、未发布。


### 2026-10-31 · 报名审核、先审后付与站内审核工作台

按确认方案将填表与审核解耦：活动require_approval默认关闭，保存/挂接报名表不再自动打开审核；兼容既有ticket.need_approval。免费直报立即确认，免费审核通过后确认，付费直报先待支付，付费审核先pending再awaiting_payment，权威支付确认后才attending。无效/未付款报名不进入赴约、公开参与者或有效票券/签到；主办/已关联嘉宾的隐式日历关系保持原规则。阻止直接participants创建绕过选票、价格/库存/审核，以及PATCH直接把待审核/待支付状态改成attending。

RegistrationReview在event→participant→ticket锁下检查活动与所选票种各自限制，不互相改写总名额/票量；待审核票券不扣库存、不生成支付期限，也不授予免费群组票权益。批准时才预留票量；付费批准保留24小时，最晚为活动结束或票种end_time（当前模型没有独立活动报名截止字段）。待支付预留单独计入容量检查，但participant_count仅统计确认报名。超时由现有5分钟sweeper向支付渠道查询并关闭后释放，渠道不可达/正在支付时保持预留，不在结果不确定时复用名额。保留35分钟普通直付订单期限。微信/Stripe创建支付会话沿用已有期限，重复预支付不会延长审核资格。

新增reviewed_by/reviewed_at/review_reason/payment_due_at/cancellation_reason，复用Activity保存申请、审核结果及超时站内消息，任务仍是实时权限投影；申请记录最新决定，重申更新表单并清空上一轮审核状态。拒绝必须1–500字，取消待审核订单不返还从未扣过的库存；免费票批准后才结算/授予权益。支付确认/取消按event→order锁串行执行，重复确认不重复占位。已开启的微信/Stripe支付单取消前先查询并关闭，渠道异常、已支付/正在支付则拒绝释放。微信预支付发起记录在网络调用前写入，以便响应丢失时仍进行权威查询。审核通过的付费邮件明确待支付且不附日历入场邀请，免费/已支付才附邀请。

新增认证GET /api/v1/registrations：只读自己的报名，按报名时间/id稳定分页；补齐此前只有预览实现的接口。参与者列表默认待审核优先，支持status分页筛选。管理者可读当前页的报名答案和所选票种，批量加载，不按人数逐项查表；其他用户只读已确认公开参与者，不暴露申请答案/审核原因。拒绝结果与支付超时个人可在活动详情/我的报名查看。

迁移20261031004000添加审核字段、reviewed_by的ON DELETE SET NULL外键、库存是否实际预留标记及待支付容量查询部分索引；20261031005000回填旧的“attending但未支付”为awaiting_payment、重算相关活动确认人数，并归还旧待审核未付订单的库存/清除错误倒计时。数据迁移不发送通知、不触碰已付订单，为不可逆数据修复；只迁移本地测试数据库，生产须随部署db:prepare执行。

验证：后端全量1409项/5211断言通过（新增14项完整报名审核集成测试）；最终报名管理序列化增补后57项/256断言通过。覆盖先审后付、免费票、审拒重申、名额与票量各自约束、必填/管理字段保护、公共隐私、接口隔离、过期资格、远程取消失败不释放、支付确认幂等及站内任务结果。前端186项、类型检查、39项320/375/430px布局检查及dist/dist-preview双构建通过；Web仅兼容构建，未发布。未推送、未部署后端、未发布小程序；真实微信扣款仍需新版后端部署后真机验收。

补充边界：同一用户/活动只有一份报名审核，待审核时不能换一个无需审核票种绕过原申请；已确认/已审核通过的活动关系不重复审核。兼容既有同活动不同票种订单，复用同一份预留与最早支付期限，不重复计入活动人数；未实际预留库存的订单，即使报名状态异常也不能发起支付或确认付款。

## 2026-10-31 — Registration entry-point audit hardening

- Closed self-service PATCH promotions to attending from declined, cancelled, maybe, pending and awaiting_payment. Reapplications use the full join/checkout flow; maybe registrations can reapply through those flows too.
- Unified DELETE and legacy PATCH cancellation (and confirmed-to-maybe exits) behind event/participant locks and order teardown. Remotely attempted payments must be safely closed before releasing inventory. Form status follows withdrawal. Repeat cancellation repairs remaining orders without double release.
- Added one Event registration lifecycle gate: published and not ended, for direct join, ticket RSVP and organizer approval. Join/checkout recheck after acquiring the event lock. Removed the pre-review venue-capacity rejection; approval/direct confirmation still independently enforce event/venue capacity and ticket inventory.
- Reusing registrations clears checked_in_at/cancelled_at as well as review/payment audit fields; old participant QR credentials remain bound to the previous registered_at.
- Added separate event_team_check_ins (unique event/user; cascading foreign keys). Hosts and linked role holders obtain a short-lived team pass without buying tickets, creating a Participant or consuming inventory/seats. Every team scan checks current role and event availability; repeat scans retain the first timestamp. Ordinary paid attendee eligibility remains unchanged.
- Added ticket_items.group_owner_notified_at. Owner notification is persisted under the payment-confirmation order lock; repeated callbacks do not repeat group purchase mail, including free tickets. Existing succeeded group purchases are marked in the migration because they already ran the previous notifier.
- Test fixtures now default to published events for signup flows; draft visibility tests explicitly create a draft. Updated legacy English error assertions to the unified errors.
- Verification: full backend suite 1,418 tests / 5,285 assertions, zero failures/errors. Added 8 entry-point regression tests plus repeated purchase notification coverage. No actual payment or production email/SMS was triggered by tests.
- New migrations: 20261031006000 (team check-ins), 20261031007000 (owner notification marker). No backend phone constraint; ticket quantities remain independent of event capacity.

### Deployment verification — registration audit fixes

- Frontend main pushed at 4847e8f; backend surf implementation pushed/deployed at 01bb505. No Web release was performed.
- Atlas deployment dep_f55bcae2-f060-460f-a367-181115a95d35 / operation op_24992be7-8de9-4da9-b627-8d0ecfb07617 succeeded. Public version reports clean source 01bb505e4463286f7ce3bf24314b5de104904f92; /up returns 200 and unauthenticated /api/v1/registrations returns 401.
- Production schema_migrations verified through 20261031007000, including all prior discovery/review migrations; team check-in table and owner-notification/inventory columns exist.
- Private pre-migration pg_dump archives were created and pg_restore --list verified on HomePod (0600, under /home/ubuntu/atlas-production/private-backups/surf). No secrets or database contents were copied into Git.
- Initial build dep_47fc064d-894a-42ac-b237-81f446a9e9dd was cancelled: Nomad could not place its 512MB runner due to physical memory reservations, despite the authorized 3072MB Atlas target budget.
- Reused the user's existing Surf-only downtime authorization. Atlas suspend rejects subsequent source up with SERVICE_STATE_CONFLICT, so restored the retained version using Atlas resume, submitted a new source deployment, then scaled only the current old Surf job atlas-7ad55ba3-18cc-4a9d-ba37-dd12d072a745 group app to zero through Nomad. This freed actual scheduler capacity while preserving Atlas admission checks, state and rollback history. Atlas completed the new build, migrations, health gate and route cutover; unrelated services were preserved.
- Real device payment, reviewer UX and QR scan acceptance remain user-side checks; automated regression tests did not charge or send production messages.

### 2026-10-31 · Mini Program review contracts and pagination fixes (R01–R17)

- Event detail exposes can_edit/can_manage_participants/can_check_in derived from EventPolicy, including group managers and email-linked editors; judges retain no edit power. can_register and its unavailable reason reflect lifecycle and group join policy. Summary responses use the same authorization but omit full content/participants.
- Added the user_id event agenda filter to union owned/attended/team events before pagination, preserving visibility. Node event ordering optionally places upcoming events before history. No client-side merge of two truncated first pages is required.
- registrations?team=true offers a separate paginated host/guest admission source for published/closed events without creating Participant records or consuming stock. The ordinary registrations contract remains unchanged.
- Added GET users/:id/topics with category/topic/group visibility and synchronization gates. User memberships opt into pagination only when page/limit is provided, preserving legacy array responses. Topic lists include a bounded 600-character excerpt, avoiding per-card body requests.
- Role candidates rank followed users, permitted community members, and publicly contributing users through SQL relations and stable pagination, rather than Ruby arrays containing the entire contributor directory. Community roster access uses GroupPolicy#members?, profiles remain publicly_discoverable, and activity uses DiscoverySignals.public_topics/Event.publicly_discoverable. Existing follow/group-user/contribution indexes remain applicable; no new migration is needed.
- Venue availability replacement runs under a venue row lock and transaction, so an invalid later interval cannot erase existing availability. Frontend retains the saved venue ID and reports partial save status if the third API call fails; unchanged addresses reuse the existing Place.
- Verification: full backend 1,428 tests / 5,332 assertions, zero failures/errors. Added 10 contract tests covering capabilities, email editor/judge separation, lifecycle, unified agenda, team admission, ranked/authorized candidates, profile post visibility, membership compatibility, summary authorization, and availability rollback. Frontend 202 tests, typecheck, and 39 browser-based WXSS layout tests passed. No production payments/messages were sent, and this revision has not been deployed.
- Preserved product decisions: no backend mandatory phone constraint and no coupling ticket quantities to event capacity. Deploy these backend contracts before publishing the updated Mini Program; no Web publication is included.

### 2026-10-31 · Handle-independent current-user order lookup

Added tickets/list?mine=true so authenticated WeChat accounts without public names can resume pending orders. The query always scopes to current_user and event_id, even if a conflicting profile_handle is supplied; old explicit-handle and organizer-list behavior is unchanged. Anonymous callers remain unauthorized. Frontend now uses mine=true only when the public handle is absent, skips fresh application-form requests for restored orders, and guards delayed save/payment/pass responses against session changes.

Verification: full backend 1,429 tests / 5,337 assertions passed, including a nameless buyer, conflicting other-user handle, and anonymous request. Frontend 217 tests and build checks passed. No migration, production payment, SMS/mail, push or deployment in this follow-up.
