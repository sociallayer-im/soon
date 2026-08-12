# 联邦演示剧本(FEDERATION DEMO PLAYBOOK)

一步一步地在几个网站之间演示联邦:Sola↔Sola、Sola↔Mastodon、Sola↔Mobilizon,
双向数据流动、互相报名、直到整个 group 的跨实例迁移。

**本剧本以 UI 操作为主**——每一步都在页面上点得出来。命令行只保留两类:运维动作
(手动触发对账)和排障时的旁证(看日志、验 DNS、读原始 AP 文档)。curl 版接口调用
移到附录 B,作为 UI 出问题时的备用路径。

写作日期 2026-08-11(2026-08-12 改为 UI 版),代码基线:soon `federation` 分支
`b50daa9`,seastar-app `97e889b`。

---

## 第〇幕:舞台与角色

### 舞台(五个站点,同一台 sg.sola.day,互为独立联邦节点)

| 站点 | 前端(操作) | 后端 / AP 身份域 | 软件 |
|---|---|---|---|
| **Sola 实例 A** | `sola.seven.fan` | `api.seven.fan`,身份域 `sola.seven.fan` | soon + seastar-app |
| **Sola 实例 B** | `appb.seven.fan` | `solab.seven.fan`(同时是身份域) | 同上,独立数据库 |
| **Mastodon** | `mas.seven.fan` | 同 | Mastodon 4.6.4(AUTHORIZED_FETCH=on) |
| **Mobilizon** | `mob.seven.fan` | 同 | Mobilizon 5.2.4 |
| **绑定域名** | — | `hi.seven.fan` → A 的 zuseven | 第五幕 |

### 角色与登录

| 站点 | 账号 | 登录方式 |
|---|---|---|
| Sola A | `alice` `bob` `carol` | 邮箱 `alice@sola.seven.fan` + 验证码(见附录 A) |
| Sola B | `dana` `interop` | 邮箱 `dana@solab.seven.fan` + 验证码 |
| Mastodon | `tester` / `voyagers` | `tester@mas.seven.fan` / `voyagers@seven.fan` + 密码(附录 A) |
| Mobilizon | `joiner`(管理员) | `joiner@mob.seven.fan` + 密码(附录 A) |

**内容素材**:A 上有 `zuconnect`、`fedlab`、`zuseven`(绑定 hi.seven.fan)、
`daospace`,以及从生产复制来的 `ethchiangmai2025`(53 个 event,首页可见);
B 上有 `nodeb`、`daospace`。

### UI 入口速查

| 要做的事 | 去哪 |
|---|---|
| 找远端账号 / 关注 / 取关 | `/fediverse` 顶部搜索框 |
| 浏览远端 event、报名/退出 | `/fediverse` 列表 → 详情页 |
| 绑定自有域名 | `/event/<group>/setting` → **自定义域名** |
| 社群迁入 / 迁出 | `/event/<group>/setting` → **迁移社群** |
| 个人账号声明前身 | `/profile/<handle>/edit` → **前身身份** |

### 排障道具

- **看联邦日志**(每步的后台真相):
  `ssh root@sg.sola.day 'docker logs fedlab-soon -f' | grep '\[fed\]'`
  日志是 `direction/type/status` 三元组,B 实例换 `fedlab-soon-b`。
- **从本机 curl 一定要 `--noproxy "*"`**(本地代理会劫持并返回假 404);
  本地 `dig` 被劫持成 198.18.x,验 DNS 要在服务器上 `dig @1.1.1.1`。

---

## 第一幕:身份互认(WebFinger)

> 原理:联邦第一步永远是"你是谁"。`acct:name@domain` 经 WebFinger 解析到
> actor 文档;文档里的公钥和收件箱是后续一切通信的根。

**1.1 从 Mastodon 找到 Sola 的 group**
- 操作:登录 `mas.seven.fan`(tester),搜索 `@zuconnect@sola.seven.fan`。
- 预期:出现 group 卡片(Group 类型 actor,头像/简介来自 Sola)。

**1.2 从 Sola 找到 Mastodon / Mobilizon 的账号**
- 操作:登录 `sola.seven.fan`(alice)→ 打开 `/fediverse` → 顶部搜索框输入
  `@joiner@mob.seven.fan` → 回车。
- 预期:解析出对方账号卡片(名称、简介、头像、所在实例),旁边是「关注」按钮。
  换 `@tester@mas.seven.fan` 同样成立。
- 旁证:`[fed]` 日志出现一次出站抓取;Mastodon 开着 AUTHORIZED_FETCH,匿名
  curl 它的 actor 会 401,而我们的抓取是实例签名的——**这是特性不是故障**。

---

## 第二幕:Sola → Mastodon(内容流出到微博客世界)

**2.1 Mastodon 用户关注 Sola group**
- 操作:tester 在 1.1 的卡片上点 Follow。
- 预期:立即变 following(Sola 自动回 Accept)。
- 日志:`direction=in type=Follow status=accepted target=zuconnect`。

**2.2 Sola 发布 event,流入 Mastodon 时间线**
- 操作:alice 在 `sola.seven.fan` 的 zuconnect 里创建一个 public event 并发布。
- 预期:数秒内(投递 Sweeper 每分钟扫一轮)tester 的 Home 出现这条 event,
  Mastodon 把 AP Event 渲染成带标题/时间的贴文。
- 日志:`direction=out type=Create ... status=delivered`。

**2.3 Mastodon 回帖 → 变成 Sola 的 event 评论(反向数据流)**
- 操作:tester 在时间线里对那条 event 回复一句。
- 预期:回到 `sola.seven.fan` 该 event 详情页,评论区出现这条回复,署名远端账号,
  **HTML 正常渲染**(提及是可点链接,不是源码)。
- 原理:入站 `Create(Note)` 的 `inReplyTo` 指向我们的 event → 落库为评论。

**2.4 完整性证明随行(FEP-8b32)**
- 每条流出的 event 都带 `proof`(eddsa-jcs-2022)。看一眼:
  ```bash
  curl -s --noproxy "*" -H "Accept: application/activity+json" \
    https://sola.seven.fan/events/<id> | python3 -m json.tool | grep -A6 '"proof"'
  ```
- 意义:内容离开本站后仍可自证出处——第三方转发、迁移归档后依然可验(第六幕的安全带)。

---

## 第三幕:Sola ↔ Mobilizon(同行之间,互相报名)

**3.1 Sola 关注 Mobilizon 的 group**
- 操作:alice 在 `/fediverse` 搜索 `@mobgroup@mob.seven.fan` → 点「关注」。
- 预期:按钮先变「待确认(pending)」,数秒后 Mobilizon 回 Accept → 变「已关注」。
  刷新页面状态保持。

**3.2 Mobilizon 的 event 镜像进 Sola**
- 操作:joiner 在 `mob.seven.fan` 的 mobgroup 里发布一个 event。
- 预期:`sola.seven.fan/fediverse` 列表出现该 event(标题、时间、来源实例);
  点进详情页可看到正文与原文链接。
- 更新/删除同样跟随(Delete 只有 origin 有权,镜像转 CANCELLED)。

**3.3 Sola 用户报名 Mobilizon 的 event(跨站报名,方向一)**
- 操作:在 3.2 的 event 详情页点「报名」。
- 预期:Mobilizon 侧该活动出现一名远端参与者;需审批的活动在 Mobilizon 批准后,
  Sola 侧状态变为「已参加」。再点一次即退出(发 `Leave`)。

**3.4 远端用户报名 Sola 的 event(方向二)**
- 前置:先让 mobgroup 关注 A 的 group(在 Mobilizon 上搜 `@zuconnect@sola.seven.fan`
  并关注),这样 A 发布的 event 才会出现在对方时间线里。
- 操作:joiner 在 Mobilizon 上对镜像过去的 Sola event 报名。
- 预期:Sola 的 event 参与者列表出现远端参与者(带来源域名);审批制 event 会先是
  pending,主办方在 UI 批准后我们回 Accept。

---

## 第四幕:Sola ↔ Sola(A ↔ B,同软件跨实例)

> 提示:A 和 B 的登录 cookie 现在按主机隔离,**两个会话可以在同一浏览器并存**,
> 来回切换不会互相顶掉。

**4.1 B 的用户关注 A 的 group**
- 操作:登录 `appb.seven.fan`(dana)→ `/fediverse` → 搜索
  `@zuconnect@sola.seven.fan` → 关注。
- 预期:秒级变「已关注」(两边都是 soon,握手全自动)。

**4.2 A 发布 event → B 镜像 → B 用户报名**
- alice 在 A 的 zuconnect 发布一个 public event;
- dana 在 `appb.seven.fan/fediverse` 看到镜像,点进去「报名」;
- 回到 A 的 event 页,参与者列表 +1,来源显示 `solab.seven.fan`。
- 评论同理:B 侧评论以 `Create(Note)` 回流 A。

**4.3 双向对称**
- 把 A、B 互换再做一遍(bob@A 关注 `@nodeb@solab.seven.fan`)。数据流完全对称——
  这就是"Sola 网络"本身:任何人可以自建实例,与 sola.day 平权互联。

---

## 第五幕:group 绑定自己的域名

> 原理:acct 落在自有域名上,actor id 留在托管实例——"签名可携带,身份不漂移"
> (PLAN §9.4)。所以绑定和解绑对关注者都是无损的。

全程在 **`/event/<group>/setting` → 自定义域名** 页面完成,三步:

**5.1 认领域名**
- 输入域名(例:`demo.seven.fan`)→ 点「获取 DNS 记录」。
- 预期:页面出现两条记录,各带复制按钮。**此刻什么都还没绑定**——未验证的认领
  绝不会影响 WebFinger(否则"认领"本身就是漏洞)。

**5.2 添加 DNS 记录**(两条记录作用不同,页面上分别标注)
- `TXT  _sola-challenge.<域名>` = 挑战串 → **证明域名归你**;
- `CNAME/A  <域名>` → 实例主机 → **让域名真正能访问**(这一条需要实例运维在
  Traefik 上加路由并签证书)。
- 只加 TXT 的话验证会成功,但域名打不开——页面文案已点破这一点。
- 本实验环境用 cf CLI 加记录:
  ```bash
  cf dns records create b90051aac681f9bd715ec7f6ede3d5b3 --body \
    '{"type":"TXT","name":"_sola-challenge.demo.seven.fan","content":"sola-domain-verification=<挑战串>","ttl":300}'
  ssh root@sg.sola.day 'dig +short TXT _sola-challenge.demo.seven.fan @1.1.1.1'  # 确认已生效
  ```

**5.3 验证并绑定**
- 点「验证并绑定」。DNS 未生效时会返回可读的 422 提示(告诉你查了哪条记录),
  等几分钟重试即可。
- 成功后页面显示「已绑定」,并同时列出**新旧两个 handle**——旧的
  `name@<实例域名>` 继续有效。

**5.4 验证效果**
- WebFinger 闭环:
  ```bash
  curl -s --noproxy "*" "https://api.seven.fan/.well-known/webfinger?resource=acct:zuconnect@demo.seven.fan"
  ```
  返回的 actor id **仍在 `sola.seven.fan`** —— 这正是"身份不漂移"。
- 从 Mastodon 搜 `@zuseven@hi.seven.fan`(已配好路由的那个):Mastodon 会把它
  规范化显示为自有域名的 handle,关注、收内容一切如常。
- 解绑:同页「解除绑定」,关注者与已有链接不受影响。

---

## 第六幕:整个 group 的迁移(压轴)

> 原理:AP Move = 新老身份**互相作证**。老 actor 宣布 `movedTo`,新 actor 的
> `alsoKnownAs` 必须独立声明老 id——对端在**新鲜抓取**上校验这一对,绝不信活动
> 自己的一面之词。对象 URL 是合同(老 event 链接仍可解析),活动 URL 是收据。

页面 **`/event/<group>/setting` → 迁移社群**,按方向分成两半,顺序不能颠倒。
入口只对该 group 的 manager/owner 显示。

### 演示前必读:目标 group 要先手动建好

**迁移不会在新服务器上凭空生出一个 group**,得先用常规入口把它建出来,再打开
它自己的迁移页。迁入分支第一步就是把目标 id 解析成本站的一个 actor
(`inbox_service.rb` `handle_move_to_local`),解析不到直接按
`local_attestation_missing` 忽略——没有 group 就没有地方存「我曾是谁」这句声明,
也就没有那一页可打开。新 handle 不必和老的一致。

**Move 迁移的是身份和关注关系,不是数据。** 远端关注者被重指到新 id、老 event
链接继续可解析;但老 group 的成员名单、events、评论**不会**跟过来,新 group
就是个空壳。目前没有任何导出/导入通道来搬这部分——演示时要主动说明,否则观众
会默认"整个社群搬家了"。

### 6a. Sola → Sola(daospace 从 A 迁到 B)

0. **在 B 上先建好目标 group**(dana 登录 `appb.seven.fan`,常规建群入口),
   它是下面每一步的操作场所。
1. **目的地先声明前身**:进这个新 group 的
   迁移页 → **「把社群迁移到这里」** → 粘贴 A 侧 group 的 ActivityPub id →
   「添加前身身份」。
   - A 侧 id 在 A 的迁移页顶部直接可复制。
2. **来源宣告迁移**:回到 `sola.seven.fan`(alice)→ 同一页面的
   **「把社群迁出」** → 填目标 id → 「宣告迁移」→ **二次确认**。
   - 想先感受硬门槛:跳过第 1 步直接宣告,会收到 422「目标未声明前身」——
     互证不成立就是不放行。
3. **预期**:
   - A 的迁移页顶部出现「本社群已宣告迁移」横幅;
   - 所有关注者(Mastodon 的 tester、B 的 dana)收到 Move,支持 Move 的对端
     自动改关注新地址;
   - 老 event 链接仍可访问(合同不毁),新内容从 B 发出。

### 6b. Sola → Mastodon(迁到微博客账号)

1. Mastodon 侧(voyagers)在 **设置 → 账户 → 从其他账号迁移过来** 填 Sola 老 id。
2. Sola 侧迁移页填 Mastodon 的**规范 id**:`https://mas.seven.fan/ap/users/<数字id>`。
   - ⚠️ 填 `/users/voyagers` 这种 handle URL 会被拒(`id != fetched uri`)——
     Mastodon 4.6 的规范 actor id 是 `/ap/users/<数字>`。数字 id 可在对方
     actor 文档里看到。这是实测踩过的坑。
3. 预期:关注者被重指到 `voyagers@mas.seven.fan`。

### 6c. 反方向(其他实例 → Sola)

- 先在本站建好承接的 group(同上,不会自动生成),再在它的迁移页
  「把社群迁移到这里」声明对方老 id,对方随后在其平台发起 Move。
- 个人账号同理:`/profile/<handle>/edit` → **前身身份** → 添加远端老 id。

### 迁移后的兜底

- 对账循环重抓 actor 时若发现 `movedTo`,会走与入站 Move 相同的互证重指——
  **错过 Move 广播也不会永久漂移**(第七幕)。
- Mobilizon 不处理 Move(实测确认):它的关注边靠上面这条兜底,或用户手动重关。

---

## 第七幕:对账与自愈(让静默失败无处藏身)

> 失败类别:本地说 accepted、对端已把边丢了,每一层都报成功、内容静默不出现。
> 机制:超过 7 天无确认的出站关注,按**原活动 id** 重发 Follow;对端幂等地再
> Accept——这个 Accept 既是"边还活着"的证明,也顺手把丢失的边修了回来。
> 3 次无回应 → `lapsed`(退出投递受众、可重关,绝不静默保留)。

这是运维动作,没有 UI。手动触发一轮(正常由每日 cron 03:41 执行):

```bash
ssh root@sg.sola.day 'docker exec fedlab-soon bin/rails runner \
  "Federation::FollowReconciliationService.run"'
# 观察 [fed] type=Reconcile status=probed / lapsed / actor_gone_purged / repointed_moved
```

实测过的自愈剧目:Mobilizon 对探测回 Accept(闭环)、对端 404/410 双向清边、
对端换了规范 URL 形式后原地重挂 actor 行、我们自己收到重复 Follow 时豁免防重放
去重并重新 Accept(应答方义务)。

---

## 附录 A:登录凭据速查

**Sola(邮箱验证码,实验环境无邮件服务,验证码从库里取)**
先在页面点「发送验证码」,再执行(A 实例):

```bash
ssh root@sg.sola.day 'docker exec fedlab-soon bin/rails runner \
  "c = AuthCode.active.order(:created_at).last; puts c ? %Q{#{c.recipient} -> #{c.code}} : :none"'
```
B 实例把 `fedlab-soon` 换成 `fedlab-soon-b`。

**Mastodon**(`mas.seven.fan`):`tester@mas.seven.fan` / `voyagers@seven.fan`,
密码重置:
```bash
ssh root@sg.sola.day 'docker exec fedlab-mastodon-web tootctl accounts modify tester --reset-password'
```

**Mobilizon**(`mob.seven.fan`):`joiner@mob.seven.fan`,密码重置:
```bash
ssh root@sg.sola.day 'docker exec fedlab-mobilizon bin/mobilizon_ctl users.modify joiner@mob.seven.fan --password <新密码>'
```

## 附录 B:API 备用路径(UI 出问题时)

取 token:
```bash
ssh root@sg.sola.day 'docker exec fedlab-soon bin/rails runner \
  "puts JwtService.encode({user_id: User.find_by!(name: %q{alice}).id})"'
```

| 动作 | 请求 |
|---|---|
| 解析远端账号 | `POST /api/v1/federation/resolve {handle}` |
| 关注 / 取关 | `POST` / `DELETE /api/v1/federation/follow {uri}` |
| 远端 event 列表 | `GET /api/v1/federation/events` |
| 报名 / 退出 | `POST` / `DELETE /api/v1/federation/events/:id/join` |
| 域名状态 | `GET /api/v1/federation/groups/:id/domain` |
| 认领域名 | `POST /api/v1/federation/groups/:id/domain {domain}` |
| 验证并绑定 | `POST /api/v1/federation/groups/:id/domain/verify` |
| 解绑 | `DELETE /api/v1/federation/groups/:id/domain` |
| group 前身身份 | `GET`/`POST`/`DELETE /api/v1/federation/groups/:id/aliases {uri}` |
| 宣告迁移 | `POST /api/v1/federation/groups/:id/move {target}` |
| 个人前身身份 | `GET`/`POST`/`DELETE /api/v1/federation/profile/aliases {uri}` |

全部需要 `Authorization: Bearer <token>`;group 相关接口要求该 group 的管理权限。

## 附录 C:实测踩坑速查

| 坑 | 症状 | 解法 |
|---|---|---|
| 本地代理劫持 | curl 假 404 / dig 返回 198.18.x | `curl --noproxy "*"`;DNS 到服务器上验 |
| Mastodon AUTHORIZED_FETCH | 匿名抓 actor 401 | 正常;我们用实例签名抓取 |
| Mastodon 规范 id | Move target 用 handle URL 被拒 | 用 `/ap/users/<数字id>` |
| Mobilizon 不发/不收 Move | 迁移后它的边不动 | 靠对账循环兜底 |
| 目标 group 不存在 | 迁移页找不到/Move 被静默忽略 | 先在新服务器手动建好 group |
| 只加了 TXT 没加 CNAME | 验证通过但域名打不开 | TXT 证所有权,CNAME 才通流量 |
| NEXT_PUBLIC 构建期烘焙 | 改运行时 env 无效 | 重新 build(前端在 wamo.city 构建后传产物) |
| 前端子域名白名单 | 新 app host 首页 404 | `SOLA_APP_SUBDOMAINS` 加一条 |
| cookie 作用域 | 两实例互相顶掉登录态 | `NEXT_PUBLIC_AUTH_COOKIE_DOMAIN=host` |
| 远端关注 pending | Mastodon 显示未关注 | 异步 Accept,等 ~10s 再看 |
| sg 内存 3.9GB | 远端 next build 打挂主机 | 在 wamo.city 构建 |

## 与设计文档的对应

- URL 分层与固定链接:PLAN §9.1;Instance 概念:§9.2;域名绑定:§9.4;
- 迁移语义与归档:§9.5–9.6;FEP-8b32:§9.7;
- 实测记录:`FEDERATION_INTEROP_VERIFICATION.md` §11(迁移)、§10.3 附记(对账);
- 尚未上台的戏:第三方转发的 LD 签名验证、迁移后老身份的发布冻结
  (见 DEVLOG §12 known-not-done)。
