# 联邦演示剧本(FEDERATION DEMO PLAYBOOK)

一步一步地在几个网站之间演示联邦:Sola↔Sola、Sola↔Mastodon、Sola↔Mobilizon,
双向数据流动、互相报名、直到整个 group 的跨实例迁移。每一步都写明**在哪里操作、
做什么、预期看到什么**。除特别标注外,所有幕次都已在下述实验环境实测通过
(实测记录见 `FEDERATION_INTEROP_VERIFICATION.md`)。

写作日期 2026-08-11,代码基线:soon `federation` 分支 `b6d8268`。

---

## 第〇幕:舞台与角色

### 舞台(五个站点,同一台 sg.sola.day,互为独立联邦节点)

| 站点 | 域名 | 软件 | 扮演 |
|---|---|---|---|
| **Sola 实例 A** | 前端 `sola.seven.fan`,API `api.seven.fan` | soon + seastar-app | 主角,AP 身份域是 `sola.seven.fan` |
| **Sola 实例 B** | 前端 `appb.seven.fan`,API/AP `solab.seven.fan` | 同上,独立数据库 | 另一个 Sola 节点(剧本里的 "lunar.day") |
| **Mastodon** | `mas.seven.fan` | Mastodon 4.6.4(AUTHORIZED_FETCH=true) | 微博客世界的观众 |
| **Mobilizon** | `mob.seven.fan` | Mobilizon 5.2.4 | 同类活动平台 |
| **绑定域名** | `hi.seven.fan` | → 实例 A | group 自有域名(第五幕) |

### 角色(现成账号)

| 站点 | 账号 |
|---|---|
| Sola A | 用户 `alice` `bob` `carol`;group `fedlab` `zuconnect` `zuseven`(绑定 hi.seven.fan)`ethchiangmai2025`(从生产复制的 53 个 event) |
| Sola B | 用户 `dana` `interop`;group `nodeb`、`daospace`(第六幕从 A 迁来的) |
| Mastodon | `tester`、`voyagers`(第六幕 sola→mastodon 迁移的落点) |
| Mobilizon | 用户 `joiner`,group `mobgroup` |

### 道具(操作方式速查)

- **从本机 curl**:必须 `curl --noproxy "*"`(本地代理会劫持并返回假 404)。
- **给某个 Sola 用户取 API token**(实验环境直接铸造,免走邮件验证码):
  ```bash
  ssh root@sg.sola.day 'docker exec fedlab-soon bin/rails runner \
    "puts JwtService.encode({user_id: User.find_by!(name: %q{alice}).id})"'
  # 实例 B 用 fedlab-soon-b
  ```
  之后 `curl -H "Authorization: Bearer <token>"`。
- **前端联邦页**:`https://sola.seven.fan/fediverse`(解析远端 handle、关注、
  浏览/报名远端 event 的 UI 入口)。
- **看联邦日志**:`docker logs fedlab-soon -f | grep '\[fed\]'`(方括号里
  direction/type/status 三元组,是每一步的"后台真相")。

---

## 第一幕:身份互认(WebFinger)

> 原理:联邦第一步永远是"你是谁"。`acct:name@domain` 经 WebFinger 解析到
> actor 文档;actor 文档里的公钥/收件箱是后续一切通信的根。

**1.1 从 Mastodon 找到 Sola 的 group**
- 操作:登录 `https://mas.seven.fan`(tester),搜索框输入 `@zuconnect@sola.seven.fan`。
- 预期:出现 group 卡片(Group 类型 actor,头像/简介来自 Sola)。
- 后台:`curl --noproxy "*" "https://sola.seven.fan/.well-known/webfinger?resource=acct:zuconnect@sola.seven.fan"` 返回 actor 链接。

**1.2 从 Sola 找到 Mastodon / Mobilizon 的 actor**
- 操作:`sola.seven.fan/fediverse` 页面,或 API:
  ```bash
  curl --noproxy "*" -X POST https://api.seven.fan/api/v1/federation/resolve \
    -H "Authorization: Bearer $ALICE" -H "Content-Type: application/json" \
    -d '{"handle": "@joiner@mob.seven.fan"}'
  ```
- 预期:返回 `fed_actor`(uri、inbox、类型)。换 `@tester@mas.seven.fan` 同样成立。
- 注意:Mastodon 开着 AUTHORIZED_FETCH,匿名 curl 它的 actor 会 401 ——
  Sola 的抓取是实例签名的,不受影响。这是特性不是故障。

---

## 第二幕:Sola → Mastodon(内容流出微博客世界)

**2.1 Mastodon 用户关注 Sola group**
- 操作:tester 在 1.1 的卡片上点 Follow。
- 预期:立即变为 following(Sola 自动 Accept)。
- 后台日志:`[fed] direction=in type=Follow status=accepted target=zuconnect`。

**2.2 Sola 发布 event,流入 Mastodon 时间线**
- 操作:alice 在 `sola.seven.fan` 的 zuconnect 里创建一个 public event 并发布。
- 预期:数秒内(SweeperJob 每分钟扫一轮)tester 的 Home 时间线出现这条 event
  (Mastodon 把 AP Event 渲染为带标题/时间的贴文)。
- 后台:`[fed] direction=out type=Create ... status=delivered`,
  `fed_deliveries` 表一行 `delivered`。

**2.3 Mastodon 回帖 → 变成 Sola 的 event 评论(反向数据流)**
- 操作:tester 在时间线里对那条 event 回复一句。
- 预期:`sola.seven.fan` 该 event 详情页的评论区出现这条回复,署名远端 actor。
- 原理:inbound `Create(Note)` 的 `inReplyTo` 指向我们的 event → 落库为 Comment
  (`handle_create`,同 Mobilizon 的 comment 机制)。

**2.4 完整性证明随行(FEP-8b32)**
- 每个流出的 event 都带 `proof`(eddsa-jcs-2022)。验证:
  ```bash
  curl --noproxy "*" -H "Accept: application/activity+json" \
    https://sola.seven.fan/events/<id> | python3 -m json.tool | grep -A6 '"proof"'
  ```
- 意义:内容离开本站后仍可自证出处——第三方转发、迁移归档后依然可验
  (第六幕的安全带)。

---

## 第三幕:Sola ↔ Mobilizon(同行之间,互相报名)

**3.1 Sola 关注 Mobilizon 的 group**
```bash
curl --noproxy "*" -X POST https://api.seven.fan/api/v1/federation/follow \
  -H "Authorization: Bearer $ALICE" -H "Content-Type: application/json" \
  -d '{"handle": "@mobgroup@mob.seven.fan"}'
```
- 预期:`state: pending` → 数秒后 Mobilizon 回 Accept → `accepted`
  (查 `GET /federation/following`)。

**3.2 Mobilizon 的 event 镜像进 Sola**
- 操作:joiner 在 `mob.seven.fan` 的 mobgroup 里发布一个 event。
- 预期:`GET https://api.seven.fan/api/v1/federation/events` 出现该 event 镜像;
  前端 `/fediverse` 列表可见。
- 更新/删除同样跟随(inbound Update/Delete;Delete 只有 origin 有权,镜像转
  CANCELLED)。

**3.3 Sola 用户报名 Mobilizon 的 event(跨站报名,方向一)**
```bash
curl --noproxy "*" -X POST \
  https://api.seven.fan/api/v1/federation/events/<fed_event_id>/join \
  -H "Authorization: Bearer $ALICE"
```
- 预期:发出 AP `Join`;Mobilizon 侧该活动出现一名远端参与者;若活动需审批,
  Mobilizon 批准后回 Accept,Sola 侧参与状态变 `attending`。
- 退出:同路径 `DELETE`(发 `Leave`)。

**3.4 远端用户报名 Sola 的 event(方向二)**
- 操作:远端 actor 向我们 inbox 发 `Join`(Mobilizon 界面上对镜像过去的
  Sola event 报名,或用测试脚本direct POST)。
- 预期:Sola event 的参与者列表出现远端参与者(`Participant` 带 `fed_actor_id`);
  审批制 event 走 pending → 主办方在 UI 批准 → 我们回 Accept。
- 注意:Mobilizon 对"陌生实例的 event"的报名入口取决于它是否已镜像到本组时间线;
  演示时先完成 3.2 的反向(mobgroup 关注 Sola group)让 event 流过去。

---

## 第四幕:Sola ↔ Sola(A ↔ B,同软件跨实例)

**4.1 B 的用户关注 A 的 group**
```bash
DANA=$(ssh root@sg.sola.day 'docker exec fedlab-soon-b bin/rails runner \
  "puts JwtService.encode({user_id: User.find_by!(name: %q{dana}).id})"')
curl --noproxy "*" -X POST https://solab.seven.fan/api/v1/federation/follow \
  -H "Authorization: Bearer $DANA" -H "Content-Type: application/json" \
  -d '{"handle": "@zuconnect@sola.seven.fan"}'
```
- 预期:秒级 `accepted`(两边都是 soon,握手全自动)。

**4.2 A 发布 event → B 镜像 → B 用户报名**
- A 侧 alice 发布 public event;
- B 侧 `GET https://solab.seven.fan/api/v1/federation/events` 出现镜像,
  前端 `appb.seven.fan/fediverse` 可见;
- dana 对它 `POST .../join` → A 侧参与者列表 +1(远端参与者,domain 显示
  `solab.seven.fan`)。
- 评论同理:B 侧对镜像 event 的评论以 `Create(Note)` 回流 A。

**4.3 双向对称**
- 把 4.1/4.2 的 A、B 互换再做一遍(bob@A 关注 nodeb@B)。数据流完全对称——
  这就是"Sola 网络"本身:任何人可以自建实例并与 sola.day 平权互联。

---

## 第五幕:group 绑定自己的域名(hi.seven.fan)

> 原理:acct 在自有域名上,actor id 留在托管实例——"签名可携带,身份不漂移"
> (PLAN §9.4)。DNS + Traefik 指向实例即可,无需独立部署。

**5.1 绑定**(域名 DNS 已指向实例;ops 侧直接设置)
```bash
ssh root@sg.sola.day 'docker exec fedlab-soon bin/rails runner \
  "Group.find_by!(name: %q{zuseven}).update!(custom_domain: %q{hi.seven.fan})"'
```

**5.2 验证 WebFinger 闭环(Mastodon 的规范化回环)**
```bash
# 自有域名上的 acct:
curl --noproxy "*" "https://hi.seven.fan/.well-known/webfinger?resource=acct:zuseven@hi.seven.fan"
# 返回的 actor id 仍在 sola.seven.fan;
# 再用 subject 域名反查,必须回到同一个 actor id(闭环)。
```

**5.3 从 Mastodon 搜索 `@zuseven@hi.seven.fan`**
- 预期:Mastodon 把它规范化显示为 `@zuseven@hi.seven.fan`,关注、收内容一切
  如常;actor id 始终是 `https://sola.seven.fan/groups/<id>`。
- 已实测:2026-08-03(INTEROP §11.4,含 DNS 泛解析补测)。

---

## 第六幕:整个 group 的迁移(压轴)

> 原理:AP Move 语义 = 新老身份互相作证。老 actor 宣布 `movedTo`,新 actor 的
> `alsoKnownAs` 必须独立声明老 id——对端在**新鲜抓取**上校验这一对,绝不信
> 活动自己的一面之词。关注者被自动重指;对象 URL 是合同(老 event 链接仍可
> 解析/归档),活动 URL 是收据。

### 6a. Sola → Sola(daospace 从 A 迁到 B,已实测)

1. **在 B 侧建好落点**并声明前身(alsoKnownAs):
   ```bash
   # B 侧(目标 group 的管理员 token):
   curl --noproxy "*" -X POST \
     https://solab.seven.fan/api/v1/federation/groups/<b_group_id>/aliases \
     -H "Authorization: Bearer $DANA" -H "Content-Type: application/json" \
     -d '{"uri": "https://sola.seven.fan/groups/<a_group_id>"}'
   ```
2. **A 侧宣布迁移**:
   ```bash
   curl --noproxy "*" -X POST \
     https://api.seven.fan/api/v1/federation/groups/<a_group_id>/move \
     -H "Authorization: Bearer $ALICE" -H "Content-Type: application/json" \
     -d '{"target": "https://solab.seven.fan/groups/<b_group_id>"}'
   # 若 B 侧没先做第 1 步,这里 422(NotAttested)——互证是硬门槛,先试一次感受它。
   ```
3. **预期**:
   - A 的 actor 文档出现 `movedTo`;
   - 所有关注者(Mastodon 的 tester、B 的 dana、Mobilizon)收到 Move;
     支持 Move 的对端自动改关注新地址(Mastodon 界面上 tester 已在关注
     B 的 daospace);
   - 老 event 链接仍可访问(合同不毁),新内容从 B 发出。

### 6b. Sola → Mastodon(账号迁去微博客世界,已实测)

1. Mastodon 侧(voyagers)在 **Settings → Account → Moving from a different
   account** 填老 id `https://sola.seven.fan/groups/<id>`(即 alsoKnownAs)。
2. Sola 侧 `POST /federation/groups/<id>/move`,target 用 **Mastodon 的规范
   id**:`https://mas.seven.fan/ap/users/<数字id>`。
   - ⚠️ 用 `/users/voyagers` 这种 handle URL 会被拒(`id != fetched uri`)——
     Mastodon 4.6 的规范 actor id 是 `/ap/users/<numeric>`,先抓一次 actor
     文档拿到真 id。这是实测踩过的坑。
3. 预期:关注者被重指到 voyagers@mas.seven.fan;Sola 老地址挂 `movedTo`。

### 6c. 反方向(Mastodon/其他实例 → Sola)

- 对方在其平台发起 Move,target 指向 Sola 的 group;Sola 侧 group 需事先把
  对方老 id 加进 `alsoKnownAs`(同 6a 第 1 步的 aliases 接口)。
- inbound Move 处理:校验 object==验证过的发送者、fresh fetch 校验互证,
  然后本地关注边自动重指(`handle_move` / `handle_move_to_local`)。

### 迁移后的兜底(哪怕当时不在线)

- 对账循环重抓 actor 时发现 `movedTo`,走与 inbound Move 相同的互证重指——
  **错过 Move 广播也不会永久漂移**(第七幕)。
- Mobilizon 不处理 Move(实测确认):它的关注边靠上一条兜底,或由用户手动重关。

---

## 第七幕:对账与自愈(让联邦"静默失败"无处藏身)

> 失败类别:本地说 accepted、对端已把边丢了,每一层都报成功、内容静默不出现。
> 机制:超过 7 天无确认的出站关注,按**原活动 id** 重发 Follow;对端幂等地再
> Accept——这个 Accept 既是"边还活着"的证明,也顺手把丢失的边修了回来。
> 3 次无回应 → `lapsed`(退出投递受众、可重关,绝不静默保留)。

**7.1 手动触发一轮**(正常由每日 cron 03:41 跑)
```bash
ssh root@sg.sola.day 'docker exec fedlab-soon bin/rails runner \
  "Federation::FollowReconciliationService.run"'
# 观察 [fed] type=Reconcile status=probed/lapsed/actor_gone_purged/repointed_moved
```

**7.2 实测过的自愈剧目**
- Mobilizon 对探测回 Accept → `last_confirmed_at` 盖戳(闭环);
- 对端 actor 404/410 → 双向清边;
- 对端换了规范 URL 形式 → 同主机 id 重定向 + actor 行原地重挂
  (`actor_rekeyed`),探测继续;
- 我们自己收到重复 Follow → 豁免防重放去重、重跑再 Accept(应答方义务)。

---

## 附录:实测踩坑速查

| 坑 | 症状 | 解法 |
|---|---|---|
| 本地代理劫持 | curl 假 404 / dig 返回 198.18.x | `curl --noproxy "*"`;DNS 到服务器上验证 |
| Mastodon AUTHORIZED_FETCH | 匿名抓 actor 401 | 正常;用实例签名抓取 |
| Mastodon 规范 id | Move target 用 handle URL 被拒 | 用 `/ap/users/<数字id>` |
| Mobilizon 不发/不收 Move | 迁移后它的边不动 | 对账循环兜底重指 |
| NEXT_PUBLIC 构建期烘焙 | 改运行时 env 无效 | 重新 build(B 前端在本机 build 后 rsync `.next`) |
| 前端子域名白名单 | 新 app host 首页 404 | `SOLA_APP_SUBDOMAINS` 加一条 |
| 远端关注 pending | Mastodon 显示未关注 | 异步 Accept,等 ~10s 再看 |
| 服务器内存 3.9GB | 远端 next build 打挂主机 | 本机构建,rsync 产物 |

## 与设计文档的对应

- URL 分层与固定链接:PLAN §9.1;Instance 概念:§9.2;域名绑定:§9.4;
- 迁移语义与归档:§9.5–9.6;FEP-8b32:§9.7;
- 实测记录:`FEDERATION_INTEROP_VERIFICATION.md` §11(迁移)、§10.3 附记(对账);
- 尚未上台的戏:第三方转发的 LD 签名验证、迁移后老身份的发布冻结、
  User 级 alias/move API(见 DEVLOG §12 known-not-done)。
