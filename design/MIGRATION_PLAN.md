# sails → soon 生产迁移方案

**日期**: 2026-07-30
**状态**: 已完成 — 切换于 2026-07-29 18:39 UTC 完成。

> **本文是执行期间的工作记录**（方案原文 + 逐阶段标注），已完成使命。
> 迁移的结论性记录见 **[MIGRATION_REPORT.md](MIGRATION_REPORT.md)**——
> 那份可独立阅读，含故障根因、教训和可复用的流水线。

## 0. 目标与原则

把 `api.sola.day` 的后端从 sails（Rails 7.2，Fly 时代遗留、现跑在 sg.sola.day）
切换到 soon（Rails 8.1，TSID 主键，GoodJob 进程内异步），数据迁入 PlanetScale
新建的 `sola_soon_db`。原则：

- **sails 及其数据库全程只读、原样保留**，出问题随时把域名切回去（观察期 7 天）。
- **尽可能重用现有 secret**（用户指令）：JWT 密钥、NEXT_TOKEN 必须与 sails 完全一致。
- sg.sola.day 只有 **4GB 内存**，过渡期 sails + soon 并存，资源参数要压着配。
- 数据库 dump 优先在服务端做（网络近、快），但**稳定为主**——所有长任务放
  tmux/nohup，用 `-Fc` 自定义格式。
- API 冻结范围：**event create/update + recurring create/update**（用户确认此范围足够）。
- juluo.xyz 国内站、sola-event-dashboard、sola-cli 后续单独迁移，本次不处理
  （CN 部署继续用 before-migration 的代码，不受影响；dashboard/cli 打到新后端
  会 404，属已知并接受）。

## 1. 现状盘点

| 项 | 值 |
|---|---|
| 服务器 | `root@sg.sola.day`（172.81.108.136，4GB RAM） |
| 构建机 | `ubuntu@wamo.city`（amd64） |
| 部署工具 | ginger **0.7**（Nomad 调度 + **Traefik** 流量路由；Traefik 按容器 label 自动发现，同一 host 规则不能被两个 service 同时声明。0.7 的 nomad job-template 模式本次不需要——生成式 spec 够用） |
| 镜像仓库 | `ghcr.io/sociallayer-im/<service>` |
| DNS | Cloudflare zone `sola.day`（`cf` CLI，DNS-only CNAME → sg.sola.day） |
| sails 生产库 | PlanetScale Postgres（`DATABASE_URL` in `sails/.env.production`） |
| soon 目标库 | PlanetScale 新建 `sola_soon_db`（待创建） |
| 前端分支 | seastar-app / seastar-auth 均在 `soon` 分支（未 push），`main` 为旧版 |

关键差异（决定了迁移不能是简单 dump/restore）：

- sails 整数 PK ↔ soon TSID 字符串 PK；60 张表 ↔ 34 张表；profiles → users
  且做身份合并。唯一通路是 `soon/script/migrate_from_sails.rb`（已在本地全量
  演练过一次，见 `design/migration_report_2026-07-29.md`）。
- ETL 脚本**硬性拒绝远程目标**（检测到 host / DATABASE_URL 即 abort，因为它
  TRUNCATE 目标表）——所以 ETL 只在本地跑，结果再导入 PlanetScale。
- 路由前缀：sails 在根路径（`/event/create`），soon 全部在 `/api/v1/`。

## 2. Secret 对照与重用（用户指令：尽量重用）

sails `.env.production` → soon `.env.production` 映射：

| sails 变量 | soon 变量 | 处理 |
|---|---|---|
| `JWT_SECRET_KEY` | `JWT_SECRET` | **同值复制，必须对齐**（见 §3 token 兼容） |
| `NEXT_TOKEN` | `NEXT_TOKEN` | **同值复制，必须对齐**（seastar-auth trusted_signin / Stripe 回调共用） |
| `SECRET_KEY_BASE` | `SECRET_KEY_BASE` | 同值复制（省得再生成；soon JWT 不回退到它，因为 JWT_SECRET 已显式设置） |
| `RESEND_KEY` | `RESEND_API_KEY` | 同值复制（变量名不同） |
| `CLOUDFLARE_ACCOUNT_ID` | `CLOUDFLARE_ACCOUNT_ID` | 同值复制 |
| `CLOUDFLARE_IMAGE_API_KEY` | `CLOUDFLARE_IMAGES_TOKEN` | 同值复制（变量名不同） |
| `DATABASE_URL` | `DATABASE_URL` | **不同**：指向新建 `sola_soon_db` |
| `AWS_*` / `S3_URL` / `BUCKET_NAME` | — | soon 不用 S3（图片全走 Cloudflare Images），不迁 |
| `SKYLIGHT_AUTHENTICATION` / `ALCHEMY_API_KEY` | — | soon 不用，不迁 |

soon 新增变量（sails 没有）：

| 变量 | 值 |
|---|---|
| `ALLOWED_SIWE_DOMAINS` | `auth.sola.day,auth.juluo.xyz`（默认值即可，可不设） |
| `WEB_URL` | `https://app.sola.day`（默认值即可） |
| `APP_HOST` | `app.sola.day`（默认值即可） |
| `MAIL_FROM` / `MAIL_LOGO_URL` | 沿用现有邮件发件配置 |
| `RAILS_MAX_THREADS` | `3`（见 §5 内存预算） |
| `GOOD_JOB_MAX_THREADS` | `3`（同上；连接池自动 = 3+3+2 = 8） |
| `WEB_CONCURRENCY` | `1`（单 Puma worker，压内存） |
| `STRIPE_*` | 暂缓（支付系统后续整体过一遍时再配，含 TicketItem#timeout TODO） |

## 3. 前置代码变更（切换前必须完成）

### 3.1 soon：legacy token 兼容（防全员登出）

**已核实的硬伤**：sails token payload 是 `{id: <整数>, address_type, hasura claims}`
（无 exp），soon `authenticate!` 读 `payload["user_id"]`（TSID）。密钥对齐只让
签名验过，用户身份仍解不出来 → 所有已登录用户在切换瞬间被登出。

修复：`Api::BaseController#authenticate!` / `authenticate_optional!` 增加回退——
`payload["user_id"]` 缺失时取 `payload["id"]`，按 `User.find_by(ref_id: id.to_s)`
查（`users.ref_id` 存的正是旧整数 id，有部分索引）。JWT gem 对无 `exp` 的
payload 不做过期校验，旧 token 天然长效，行为与 sails 一致。加测试：伪造一枚
sails 格式 token（同密钥）能通过 soon 认证并解析到正确用户。

### 3.2 sails：API 冻结开关

`EventController` create/update + `RecurringController` create/update 入口检查
`ENV["MIGRATION_FREEZE"]`，为真则返回 503 + 明确报错信息。**用环境变量开关**，
回滚/解冻只改 `.env.production` 重启容器，不用重新构建镜像。默认不设 = 行为
完全不变，可以提前部署好待命。

### 3.3 校验脚本

`soon/script/verify_migration.rb`（rails runner，只读，双库连接）：

- 每表行数对照：source 读数 − 预期 skip/merge 数 = target 行数
  （预期值以 `migration_report_2026-07-29.md` 的口径为准：users −66 合并、
  events −3、venues −22、markers −16、participants −19 去重、event_roles −264）。
- 按 `ref_id` 抽样全字段 diff（每表随机 ≥200 行或全量，取小者），字段映射复用
  ETL 的 transform 定义。
- 悬空 FK 全表扫（必填 FK 必须为 0）。
- 关键不变量：每个 group 的 owner membership 存在；badge→badge_class 计数一致；
  ticket_items 金额汇总一致。
- 输出 PASS/FAIL 摘要，**任何一项 FAIL 不切域名**。

### 3.4 前端分支整理

```bash
# seastar-app / seastar-auth 各自：
git branch before-migration main   # 备份分支（等价于用户要的"main 改名备份"，但不动 GitHub 默认分支）
git checkout main && git merge soon
git push origin main before-migration
```

不直接 rename main 的原因：GitHub 默认分支、`origin/HEAD`、可能残留的 Vercel
webhook 都会被 rename 牵动；备份分支 + 正常合并达到同样效果、零副作用。
CN 站（`ginger.cn.yml`）下次部署前先 checkout `before-migration` 即可不受影响。

## 4. soon 的 ginger 部署配置（新建 `soon/ginger.yml`）

以 `sails/ginger.yml` 为模板，差异点：

```yaml
service: soon
image: ghcr.io/sociallayer-im/soon

runner: nomad
egress: traefik

servers:
  web:
    hosts: [sg.sola.day]
    primary: true

registry:
  server: ghcr.io
  username: jiangplus
  password: GHCR_TOKEN

proxy:
  hosts: [soon-api.sola.day]     # 切换时改为 [api.sola.day, soon-api.sola.day]（见 §7）
  app_port: 8080
  ssl: true                      # Traefik 自动处理 Let's Encrypt
  health_check_path: /up
  # 注：deploy_timeout/drain_timeout 是 kamal-proxy 专属参数，Nomad+Traefik 栈不用；
  # 健康门禁由 ginger 轮询 nomad deployments + ProgressDeadline 完成

resources:                       # Nomad 资源（4GB 服务器上必须显式设，见 §5）
  cpu: 256
  memory: 300                    # 预留压低——Nomad 按预留调度，预留设大了部署直接排不进去
  memory_max: 1024               # 实际可用走 oversubscription 突发上限（over-provision，必设）

ssh:
  user: root
  command_timeout: 600

builder:
  arch: amd64
  remote: ssh://ubuntu@wamo.city

env:
  RAILS_ENV: production
  WEB_CONCURRENCY: "1"
  RAILS_MAX_THREADS: "3"
  GOOD_JOB_MAX_THREADS: "3"
  THRUSTER_HTTP_PORT: "8080"     # soon Dockerfile EXPOSE 80，用 Thruster 环境变量对齐到 8080
  THRUSTER_TARGET_PORT: "3000"

secrets:
  load: [.env.production]
  inject:
    - DATABASE_URL
    - SECRET_KEY_BASE
    - JWT_SECRET
    - NEXT_TOKEN
    - RESEND_API_KEY
    - CLOUDFLARE_ACCOUNT_ID
    - CLOUDFLARE_IMAGES_TOKEN

retain_containers: 5
```

`soon/.env.production`（git-ignored）按 §2 的映射从 `sails/.env.production` 生成。

DNS：`cf dns records create ... '{"type":"CNAME","name":"soon-api","content":"sg.sola.day","proxied":false}'`。

seastar-app / seastar-auth 的 `ginger.yml` 不变（`NEXT_PUBLIC_API_URL` 保持
`https://api.sola.day`，前端镜像一次构建到底；切换只动 proxy 的 host 归属）。

## 5. 内存预算（4GB 硬约束）

**2026-07-30 实测（此前的估算是错的——这台机器上不止 3 个服务）：**

```
free -m:   total 3915   used 2785   available 1130   swap used 1000/2047
vmstat:    si/so 稳定为 0 —— 那 1GB swap 是冷页，不是在颠簸
nomad:     12 个 running allocation，已分配 3.8GiB / 8.0GiB
           （节点被有意配置成 8GiB，物理只有 3.9GB，即 over-provision）
```

同机运行的 12 个服务：`sails-web`、`seastar-app-web`、`seastar-auth-web`、
`loop-app-web`、`loop-backend-web`、`semi-app-web`、`semi-backend-web`、
`wave-web`、`flow-circle-web`、`hometown-web`、`xray`、`yatch-mirror`，
外加 `ginger-traefik`。容器实测 RSS 合计约 1.65GB，最大的单个是 352MB。

| 项 | 实测 / 预算 |
|---|---|
| 当前已用（12 服务 + 系统） | 2785 MB |
| 当前可用 | 1130 MB |
| **soon 预留（Nomad 调度依据）** | 300 MB |
| **soon 上限 `memory_max`** | 640 MB（约为 sails 实测 ~350MB 的 2 倍） |
| 加入 soon 后预计可用 | ~750 MB |

**为什么 `memory_max` 从 1024 收到 640**：可用内存只有 ~1.1GB 且被 12 个服务
共享，1GB 的上限意味着单个泄漏就能把整机拖进 swap。640 给了 soon 约 2 倍于
同类工作负载（sails）的余量，同时保住其余服务。

- **Nomad 按 `resources.memory` 预留调度，4GB 机器必须走内存 over-provision**：
  预留（memory）压低到 ~300MB 保证排得进去，实际用量靠 `memory_max` 突发上限
  兜住（需 Nomad 开启 memory oversubscription：server 配置
  `memory_oversubscription_enabled = true`——部署 soon 前先在服务器上确认，
  未开则 `memory_max` 被忽略、突发直接按预留 OOM）。
- **滚动部署瞬间新旧 alloc 并存**，预留×2 计入调度——这也是预留必须压低的原因；
  所有服务的预留总和 + 一份最大服务的预留 必须 < Nomad allocatable memory。
- 构建全部在 wamo.city 远程构建机，**服务器上不发生 docker build**。
- 数据导入 PlanetScale 从本地发起（§6），不占服务器内存；服务端只跑
  `pg_dump`（流式，内存占用可忽略）。
- 部署时 nomad 短暂新旧容器并存，峰值 +450 MB，仍有余量。
- 观察期结束下线 sails 容器后回收 ~500 MB。

## 6. 数据迁移路径（五步，先演练后正式）

ETL 不能直连远程（脚本硬性拒绝 + TRUNCATE 危险），实际链路：

```
[1] 服务端 pg_dump（PlanetScale sola_sails_db → sg.sola.day 上的 .dump 文件）
      tmux 内: pg_dump "$SAILS_DATABASE_URL" -Fc -Z 6 -f /root/sails_prod_$(date +%Y%m%d).dump
      （服务器网络离库近，快且稳；-Fc 支持并行 restore 与断点重试）
[2] scp 到本地 → pg_restore 到本地 Postgres 新库 sails_prod_mirror
[3] 本地跑 ETL：
      bin/rails db:schema:load（本地全新 soon_prod_stage 库）
      SOURCE_DB=sails_prod_mirror DRY_RUN=1 bin/rails runner script/migrate_from_sails.rb   # 先干跑
      SOURCE_DB=sails_prod_mirror bin/rails runner script/migrate_from_sails.rb             # 真跑
[4] 本地跑校验脚本（§3.3），必须全 PASS
[5] 导入 PlanetScale：
      pg_dump soon_prod_stage -Fc | pg_restore -d "$SOLA_SOON_DB_URL" --no-owner --no-acl -j 4
      （排除 good_job* 数据，只建空表；若本地上行带宽成为瓶颈，把 stage dump
       scp 回服务器、从服务端 restore——两条路径演练时各测一次取快且稳者）
```

### 演练结果（2026-07-30，全链路真实生产数据，已完成）

| 步骤 | 耗时 | 备注 |
|---|---:|---|
| [1] 生产 `pg_dump` → 本地 | **2:00** | 67MB（`-Fc -Z 6`），零报错 |
| [2] `pg_restore` → 本地 `sails_prod_mirror` | **0:04** | 仅 2 个 `hypopg` 报错，PlanetScale 的索引顾问扩展，与应用数据无关 |
| [3] ETL（`DRY_RUN` 0:08 + 实跑 0:34） | **0:34** | |
| [4] 本地校验 | **0:02** | 38 PASS / 0 FAIL |
| [5a] `pg_dump` stage（排除 `auth_codes`/`good_job*` 数据） | **0:04** | 64MB |
| [5b] `pg_restore` → PlanetScale `sola_soon_db` | **0:39** | 零报错 |
| [6] 对生产库跑校验 | **0:36** | 38 PASS / 0 FAIL |
| **合计** | **≈ 4 分钟** | |

**冻结窗口按 15 分钟准备**（4 分钟流水线 + 切域名 + 冒烟 + 缓冲）。

生产数据规模：34291 profiles / 18184 events / 55443 participants / 31303 domains，
库 167MB。全部行数差为 0，身份合并 66 人（0 人不可达），必填外键 0 悬空，
6 张表 × 1800 行字段级 diff 全等。`sails_sails_db` 全程只读，演练后大小和行数不变。

**修正原计划的两点**：

1. **dump 在本地做，不在服务端。** 服务器上没装 `pg_dump`，而且 ETL 必须在本地跑，
   所以服务端 dump 反而多一跳（Sydney→新加坡→本地）。本地直连 2 分钟就够，
   不必为此在生产机上装 postgresql-client。
2. **导出 stage 时必须排除 `auth_codes` 和 `good_job*` 的数据**——本地 dev 库里
   有 3 条登录验证码和 2 条 GoodJob 执行记录，不能带进生产。已在命令里加
   `--exclude-table-data`，并验证生产库这两张表为空。

## 7. 执行顺序

### 阶段 A：准备（不碰线上行为，可随时做）

1. soon legacy-token 兼容 + 测试（§3.1）
2. sails `MIGRATION_FREEZE` 开关（§3.2），部署 sails（开关不设，行为不变）
3. 校验脚本（§3.3）
4. 前端分支合并 + `before-migration` 备份分支（§3.4）
5. `soon/ginger.yml` + `.env.production`（§2/§4）；PlanetScale 创建 `sola_soon_db`
6. Cloudflare 加 `soon-api` CNAME
7. 服务器上确认 Nomad 已开启 memory oversubscription
   （`nomad operator scheduler get-config`；未开则先
   `nomad operator scheduler set-config -memory-oversubscription=true`，
   否则 §4 的 `memory_max` 不生效，soon 会按 300MB 预留被 OOM）
8. **演练**：§6 全链路计时 + 校验全 PASS

### 阶段 B：soon 预上线（线上仍由 sails 服务，无风险）

9. `cd soon && GHCR_TOKEN=... ginger deploy` → `soon-api.sola.day`，接演练数据
10. 冒烟：`/up`；**拿一枚真实 sails 生产 token 调 soon 认证接口**（验证 §3.1）；
    邮箱验证码登录；建 event / RSVP（演练库随便写）；邮件实际送达（GoodJob 进程内执行）
11. 本地起 seastar-app/seastar-auth 指向 `soon-api.sola.day` 完整过主流程
    （登录、建活动、报名、群组管理、徽章、售票）——把前端集成从代码审查变成实测

### 阶段 C：正式窗口（低峰时段，提前公告）

12. **开冻结**：sails `.env.production` 设 `MIGRATION_FREEZE=1`，重启 sails 容器
13. 跑 §6 [1]–[5]（正式数据、目标 `sola_soon_db`；先 `TRUNCATE`/重建掉演练数据）
14. 校验脚本全 PASS（任何 FAIL → 中止，解冻结，择日重来——此时线上零损伤）
15. soon 指到正式库（`.env.production` 确认 `DATABASE_URL`），重启，soon-api 冒烟
16. **域名交接**（Traefik 按容器 label 路由：同一 Host 规则若被两个 service
    同时声明，路由行为不确定——必须先摘后挂，顺序不能反）：
    a. `sails/ginger.yml` proxy.hosts 去掉 `api.sola.day`（留占位
       `sails-old.sola.day`）→ `ginger deploy --skip-push`（Nomad 重提交 job、
       换 label，Traefik 秒级感知）
    b. `soon/ginger.yml` proxy.hosts 改为 `[api.sola.day, soon-api.sola.day]`
       → `ginger deploy --skip-push`
    c. 两步之间 api.sola.day 有数秒 404 窗口，属预期（冻结窗口内）
17. 部署 seastar-app / seastar-auth（main 分支镜像，`NEXT_PUBLIC_API_URL` 仍是
    `https://api.sola.day`，无需改动——如 B 阶段镜像已构建可直接复用；两个服务
    可用 group deploy 一条命令走：`ginger deploy -c seastar-app/ginger.yml -c seastar-auth/ginger.yml`）
18. 生产冒烟：老 cookie 直接访问（legacy token 生效）、新登录、建 event、RSVP、
    邮件、图片上传、日历订阅
19. 冒烟通过 → sails 保持 `MIGRATION_FREEZE=1` 不解除（它已不接流量，冻结留作
    防御：万一有旧客户端直连容器）

### 阶段 D：观察期（7 天）

20. sails 容器与 PlanetScale 旧库**原样保留、不动**
21. 每日看 soon 日志 + GoodJob dashboard（失败任务）+ 内存水位（`free -m`）
22. 7 天无恙 → 下线 sails 容器（镜像和库仍保留），出迁移收尾报告

## 8. 回滚

| 时点 | 动作 | 数据损失 |
|---|---|---|
| 阶段 C 步骤 14 前（校验失败等） | 解冻结即可，什么都没发生 | 无 |
| 域名已切、**尚无实质写入 soon** | 步骤 16 反向执行（sails 收回 api.sola.day host → 解冻结）；前端无需动 | 无 |
| **已有写入 soon** | 原则上不回退（无反向 ETL：TSID→整数、身份合并均不可逆）。极端情况下回切 = 放弃切换后产生的数据 | 切换后新增数据 |

一分钟回滚命令（预演过再进窗口）：

```bash
cd soon  && ginger deploy --skip-push   # proxy.hosts 已改回 [soon-api.sola.day]（先摘）
cd sails && ginger deploy --skip-push   # proxy.hosts 已改回 [api.sola.day]（后挂）
# sails .env.production 去掉 MIGRATION_FREEZE，重启
```

（把两份 ginger.yml 的"回滚版"提前写好放在分支/stash 里，窗口内不现场手改。）

镜像层面回滚另有 `ginger rollback <version>`（切回旧容器）+ `ginger history`
（查版本号），适用于"soon 新镜像有 bug"而非"整体切回 sails"的场景，两者不要混。

## 9. 已知并接受的破坏（用户确认）

- **juluo.xyz 国内站**：继续跑 sails + before-migration 前端，后续单独迁移。
- **sola-event-dashboard / sola-cli**：打 `api.sola.day` 根路径老路由会 404
  （soon 全在 `/api/v1/`），后续迁移时一并升级。
- 未迁移的 sails 表（votes、points、orders、estores、map_checkins 等 26 张）
  数据留在旧库，soon 无对应功能。

## 10. 进度

### 已完成（本地，未触碰线上）

- [x] **§3.1 soon legacy-token 兼容** — `app/controllers/api/base_controller.rb`
      新增 `user_from_payload`，`payload["user_id"]`（soon）优先，回退
      `payload["id"]` → `User.find_by(ref_id:)`（sails）。
      `test/controllers/api/legacy_token_test.rb` 10 例覆盖：跨格式认证、
      无 `exp` 不被拒、错密钥拒绝、`ref_id` 为空的新用户不可被旧 token 命中、
      `user_id` 优先于 `id`、可选认证降级为匿名。soon 全量 625 runs / 0 failures。
- [x] **§3.2 sails 冻结开关** — `ApiController#block_during_migration!`
      （`MIGRATION_FREEZE`，未设或 `0/false/no` 即关闭），挂在
      `EventController` / `RecurringController` 的 `create`/`update` 上，
      返回 503 + `Retry-After: 600`。`test/controllers/api/migration_freeze_test.rb` 4 例。
      基线对比确认零回归：改动前后同为 5 failures + 4 errors，均为既有问题
      （`popup_cities`/`PopupCity` 模型缺失、`custom_form_id` schema 漂移、
      payment-methods 校验、fixture 数据）。
- [x] **§3.3 校验脚本** — `script/verify_migration.rb`，只读，双库对照。
      四段：行数对照 / 身份合并可达性 / 去重后精确计数 / 外键+字段 diff+业务不变量。
      本地对 07-29 的迁移结果实跑通过：34 PASS，身份合并 0 人不可达，必填外键 0 悬空，
      6 张表 × 1800 行字段级 diff 全等。
- [x] **§4 `soon/ginger.yml`**（Nomad+Traefik、`memory:300`/`memory_max:1024`、
      Thruster 8080）与 **`soon/.env.production`**（已 gitignore）。
      secret 已从 `sails/.env.production` 重用并逐项校验一致：
      `JWT_SECRET_KEY→JWT_SECRET`、`NEXT_TOKEN`、`SECRET_KEY_BASE`、
      `RESEND_KEY→RESEND_API_KEY`、`CLOUDFLARE_IMAGE_API_KEY→CLOUDFLARE_IMAGES_TOKEN`。
      `DATABASE_URL` **故意留占位符**，待 `sola_soon_db` 建好后填入——绝不可指向 sails 生产库。

### 校验脚本的一个关键发现

ETL 的 `req:` 检查作用于**映射后**的值，所以源库中「非 NULL 但指向已不存在的父行」
的外键，和 NULL 一样会导致整行被跳过。本地数据里这样的行有：
`badge_classes` 1（悬空 `creator_id`）、`ticket_items` 3（悬空 `ticket_id`）、
`comments` 2（悬空 `profile_id`）、`form_submissions` 1（悬空 `user_id`）。
校验脚本的预期损失规则据此改成检查**可解析性**而非是否为 NULL——生产数据的数字
会不同，必须在演练时重新导出，不能沿用这里的值。

### 阶段 A 已全部完成（2026-07-30）

- [x] **§3.4 前端分支** — seastar-app / seastar-auth 各自建 `before-migration`
      备份分支（指向合并前的 main），soon 快进合并进 main，两者均已 push。
      推送前确认过：三个生产域名都 CNAME 到 sg.sola.day，不走 Vercel，
      所以即使仓库还挂着 Vercel 集成也影响不到线上流量。
- [x] **PlanetScale `sola_soon_db`** — 在 sails 所在实例上
      `CREATE DATABASE`（该角色 `rolcreatedb = t`）。`soon/.env.production`
      的 `DATABASE_URL` 已回填，凭据与 sails 相同、仅库名不同，
      并断言了字符串里不再含 `sola_sails_db`。
- [x] **Cloudflare `soon-api` CNAME** → sg.sola.day，已生效。
      注意 zone 里有 `*.sola.day → cname.vercel-dns.com` 通配符，
      所以显式记录是必需的，否则会落到 Vercel。
- [x] **Nomad memory oversubscription** — 已开启（`= true`），`memory_max` 会生效。
      同时发现这台机器实际跑着 12 个服务而非 3 个，据此重写了 §5 并把
      `memory_max` 从 1024 收紧到 640。
- [x] **§6 演练** — 全链路真实生产数据跑通，38 PASS / 0 FAIL，合计约 4 分钟。

### 阶段 B 进行中（2026-07-30）

- [x] **sails 部署**（`d71c53e`）——带冻结开关但开关关闭。线上验证：
      `POST /event/create` 返回 403 鉴权错误而非 503，行为与部署前一致。
      ginger 的 `secrets.inject` 是精确名单且会校验非空，所以用 glob
      `"MIGRATION_*"` 而非直接写 `MIGRATION_FREEZE`，否则冻结未启用时每次
      部署都会失败。启用时改 `.env.production` + `ginger deploy --skip-push`。
- [x] **GitHub `sociallayer-im/soon`** 已创建（**私有**——`design/` 下有服务器
      IP、PlanetScale 主机名等基础设施细节；sails 仓库是公开的，如需对齐可改）
      并推送。
- [x] **soon 部署到 soon-api.sola.day**，接生产数据副本。
- [x] **legacy-token 端到端验证通过**：用生产 `JWT_SECRET_KEY` 铸造 sails 格式
      token（profile id=1），soon 正确解析为迁移后的用户（TSID、钱包地址、
      nickname、权限全部吻合）。`/users/me`、`/group_invites/pending`、
      `/activities` 均 200，无 token 时 401。**这是整个迁移风险最高的一项。**

#### 部署过程中发现并修复的三个问题

1. **构建失败**：`rbsecp256k1`（siwe-rb → eth）用 autotools 编译 vendored
   libsecp256k1，Dockerfile 缺 `autoconf/automake/libtool/libgmp-dev`。

2. **`WEB_CONCURRENCY=1` 导致所有 DB 请求永久挂起**（最隐蔽的一个）。
   Puma 把任何值——包括 `"1"`——都当作要求 **cluster 模式**；`config/puma.rb`
   里没有 `workers` 指令，不设这个变量才是 single 模式。而 GoodJob 是
   `execution_mode :async` 进程内运行，cluster 模式下它的调度器和 LISTEN 连接
   在 fork **之前**的 master 进程里启动，fork 出的 worker 随后在第一个碰数据库的
   请求上永久卡死——**不发 SQL、不报错、不超时**。
   `/up` 不碰数据库所以一直返回 200，**Nomad 健康检查全程是绿的**。
   教训：健康检查必须至少碰一次数据库，否则这类故障对编排系统不可见。

3. **首页 726KB / 9-10 秒**（对比 sails 同一页面 16KB / 0.73 秒）。两层原因：
   - `GroupBlueprint` 的 `:detail` 视图走 5 个关联，而 `discover` 的查询没有
     `includes` → 每条记录 N+1，跨网络就是上百次往返。
   - 更根本的是 `:detail` 把每个 popup city 的**完整成员名单**塞进了首页：
     21 个 group 共 2407 条 membership（单组最多 712），而前端的
     `toPopupCity` 只读 10 个标量字段，一条都没用。

   拆成 `:card`（标量）+ `:detail`（`include_view :card` + 关联），
   discover 用 `:card`，`groups#show` 保留 `:detail` 但走
   `Group.with_detail_associations`。结果 **726KB → 62KB，9-10s → 0.92s**。

#### 当前线上实测

| 端点 | 状态 | 耗时 | 大小 |
|---|---|---:|---:|
| `/up` | 200 | 0.67s | 73B |
| `/api/v1/discover` | 200 | 0.87s | 62KB |
| `/api/v1/events?limit=20` | 200 | 0.90s | 30KB |
| `/api/v1/groups/edgeesmeralda`（712 成员） | 200 | 1.15s | 167KB |
| `/api/v1/search?keyword=edge` | 200 | 0.98s | 41KB |
| `/api/v1/groups/edgeesmeralda/calendar.ics` | 200 | 0.73s | 1.9KB |

soon 容器内存 **268MB / 640MB 上限**，机器可用内存 ~1GB，Puma 已是 single mode。

### 阶段 C 第一次尝试：已中止并回滚（2026-07-29 18:02–18:07 UTC）

冻结窗口 **4 分 45 秒**（凌晨低谷），已完全解冻，生产恢复正常。

流水线本身全部成功，问题出在基础设施容量：

| 步骤 | 结果 |
|---|---|
| 12 开冻结 | ✅ 写接口 503，读接口 200 |
| 13 [1] 生产 dump | ✅ 18 秒 / 67MB |
| 13 [2] restore 本地镜像 | ✅ 4 秒 |
| 13 [3] ETL | ✅ 32 秒 |
| 14 本地校验 | ✅ 38 PASS / 0 FAIL |
| 13 [5] 导入 PlanetScale | ❌ **连接槽耗尽** |

**根因：实例 `max_connections = 25`，其中 3 个保留给 superuser，可用 22。**
当时分布：`loop_prod` **10（全部 idle）**、后台 9、`sola_sails_db` 5、
`postgres` 2、`sola_soon_db` 2、`pscale_exporter` 1。`pg_restore -j 4` 再要
4 个直接打爆。

这是选择"在 sails 现有实例上 `CREATE DATABASE`"而非独立托管库所带来的代价——
连接预算是**整个实例共享的**，包括正在服务线上流量的 sails 库。

`-j 1` 单连接重试成功（49 秒）。schema 对象数与本地 stage 完全一致
（36 表 / 152 索引 / 279 约束），对生产库跑校验 38 PASS / 0 FAIL，
soon-api 已恢复服务。**所以数据导入不是真正的阻塞点。**

**真正的阻塞点是切换后的稳态容量**：soon 承接全量流量需要约 6 个连接
（`RAILS_MAX_THREADS 3` + `GOOD_JOB_MAX_THREADS 3` + 2），加上 sails 的 5、
`loop_prod` 的 10、系统的 3，合计约 24 > 可用的 22。切过去会在生产上
撞到 "remaining connection slots" 错误。

### 待决策：连接容量（阻塞阶段 C）

| 方案 | 效果 | 代价 |
|---|---|---|
| A. 降低 `loop_prod` 连接池 | 释放最多 10 个槽，是最大单一消费者且**全部 idle** | 那是另一个应用，需要评估其真实需求 |
| B. soon 迁到独立 PlanetScale 库 | 独立连接预算，彻底隔离；本来就是最初的推荐方案 | 需要 `pscale auth login`（交互式），新凭据 |
| C. 提升实例规格 / `max_connections` | 直接解决 | PlanetScale 控制台操作，可能涉及费用 |
| D. 走 6432 连接池端点 | 已验证可连 | **GoodJob 依赖 LISTEN 和 session 级 advisory lock，transaction 池化模式下会坏**；只让 Web 走池、GoodJob 走直连是可行的，但迁移前引入这种复杂度风险高 |

无论选哪个，都应顺带把 `GOOD_JOB_MAX_THREADS` 降到 1 —— soon 的异步任务
目前只有事务性邮件，3 个线程是浪费，降到 1 可省 2 个连接。

### 容量问题的解决（方案 A）

`loop_prod` 是 **Elixir/Phoenix** 应用（`sola-loop/loop-backend`），Ecto 的
`pool_size` 默认就是 10，在启动时一次性建满并靠定时保活维持。采样确认：
10 个连接完全同步地每 2 秒变一次状态，其中 9 个的 `query` 始终为空——
从未跑过应用查询。`config/runtime.exs:47` 已经是 `System.get_env("POOL_SIZE")`
驱动，所以只需加环境变量，无需改代码。设 `POOL_SIZE=3` 后释放 7 个槽，
loop-api 与 loop.sola.day 均保持 200。

同时把 soon 的 `GOOD_JOB_MAX_THREADS` 从 3 降到 1（连接池 8 → 6）。

非后台连接从 20 降到 13–15，可用 22。

## 11. 切换完成（2026-07-29 18:18–18:39 UTC）

| 步骤 | 时刻 UTC | 结果 |
|---|---|---|
| 开冻结 | 18:18 | 写 503 / 读 200 |
| 生产 dump | 18:19 | 19 秒 |
| 本地 restore + ETL | 18:19–18:20 | 35 秒 |
| 本地校验 | 18:20 | 38 PASS / 0 FAIL |
| 重建并导入 `sola_soon_db` | 18:20–18:21 | 44 秒（`-j 1` 单连接） |
| 对生产库校验 | 18:21 | 38 PASS / 0 FAIL，schema 对象 36/152/279 全等 |
| sails 释放 api.sola.day | 18:22 | 转到 sails-old.sola.day |
| soon 接管 api.sola.day | 18:23 | 旧路由 404、`/api/v1/` 200 |
| 前端部署 | 18:24–18:38 | 两个 Next.js 镜像构建 |
| 生产冒烟 | 18:39 | 全绿 |

**终态**：`api.sola.day` → soon；`app.sola.day` / `auth.sola.day` → 新前端；
sails 仍在运行且保持冻结，经 `sails-old.sola.day` 可直达（回滚通路）。
首页 161KB 渲染出真实数据，登录端点（`auth/nonce` / `request_code` /
`verify_code`）行为正确，legacy sails token 认证通过。
连接占用 13 / 22。

### 这次窗口暴露的流程缺陷

**前端镜像应当在窗口开始之前就构建好。** 18:24–18:38 这 14 分钟里，
`api.sola.day` 已经是 soon，而 `app.sola.day` 上跑的还是对着 sails API 写的
旧前端——这段时间前端是坏的。写接口从 18:23 起就可用了，真正的用户可见
中断是这 14 分钟的前后端不匹配，而不是 5 分钟的写冻结。

下次（或国内站迁移时）：**先 `ginger deploy` 构建并推送前端镜像到 registry，
窗口内只做 `--skip-push` 的滚动**，可把这段压到 1 分钟以内。

### 切换后：loop 已停机

按运维决定，`loop-app-web` 与 `loop-backend-web` 两个 job 已 `ginger remove`
下线（`loop.sola.day` / `loop-api.sola.day` 现返回 404）。这让先前的
`POOL_SIZE=3` 调整变成历史记录——loop 重新上线时那个设置仍然有效且仍然正确。

腾出的资源：非后台连接 **10 / 22**，服务器可用内存 1136MB。

### 观察期（7 天）

- sails 容器与 `sola_sails_db` **原样保留、不动**，冻结开关保持开启。
  经 `sails-old.sola.day` 可直达，是回滚通路。
- 每日检查 soon 日志、GoodJob 失败任务、内存水位（`free -m`）、
  连接数（应稳定在 ~10/22）。
- 7 天无恙后再下线 sails 容器（镜像与数据库仍保留）。

**回滚边界提醒**：切换后已有用户写入 soon，反向 ETL 不存在
（TSID 转不回整数、合并掉的 66 个身份拆不开），所以整体回切 sails
等于放弃切换后产生的全部数据。镜像层面的回滚（`ginger rollback`）
仍然可用，那解决的是"soon 新镜像有 bug"，不是"切回 sails"。

## 12. 切换后修复：legacy 整数 ID 链接

切换后 15 分钟内的生产日志显示，81 个非健康检查请求里有 24 个 404，其中
**9 个是不同的整数 ID 活动查询**（`/api/v1/events/11399` 等）。这些是真实用户
在点切换前生成的链接——书签、分享出去的消息、搜索引擎结果、日历订阅。
整数永远不可能匹配 TSID 主键，所以全部 404。

`ApplicationRecord.find_by_id_or_legacy!` 先按 TSID 查，失败后在标识符
**全为数字**时回退到 `ref_id`（迁移时保留的旧整数）。全数字的标识符本身
不可能是 TSID，所以回退无歧义；额外那次查询走的是 `ref_id` 的部分索引，
且只在 legacy 路径上发生。迁移后新建的记录 `ref_id` 为 NULL，不会被数字命中。

已接入 events / badges / badge_classes / vouchers 以及单活动日历订阅。
groups 用 slug 寻址，slug 跨迁移不变，无需处理。

验证：用户报的 `https://app.sola.day/event/detail/11399` 恢复 200
（"cybernetic economy for the AI Age"），日志里其余 7 个整数 ID 全部恢复 200，
TSID 照常工作，不存在的 ID 仍正确 404。

### 旧路由 404 的处理

同一批日志里还有几个 sails 时代的路径被请求：`/comment/list`（4 次）、
`/api/event/list`（2 次）、`/group/icalendar`（1 次）、`/event/discover`（1 次）。

**`/group/icalendar` 已修复**（`Api::V1::CalendarsController#legacy_group`）。
它和其他旧路由性质不同：订阅 URL 存在用户的 Apple Calendar / Google /
Outlook 里，发出去就再也改不了，所以这条路径要**长期保留**而不只是过渡；
而且它是静默失败的——订阅者只会看到日历悄悄不再更新，永远不会收到报错，
也就不会有人来报。日志里那个 404 是唯一的发现途径。

路由挂在 `/api/v1` 命名空间之外（因为订阅 URL 就长在那个位置），接受 sails
的 `group_name`（slug）和 `group_id`（整数）两种参数，输出与
`/api/v1/groups/:id/calendar.ics` **逐字节相同**。同时 `Group.resolve!` 也加了
数字标识符回退到 `ref_id`，顺带让 `/api/v1/groups/<旧整数id>` 可用。

UID 仍用 soon 的 `event-<tsid>@host` 而非 sails 的 `sola-<整数>`：订阅日历是
整份 feed 同步的，换 UID 只会让客户端替换一次条目，这比为同一批活动维持
两套 UID 方案要好。

生产验证：`?group_name=edgeesmeralda`、`?group_id=3409`、
`/api/v1/groups/3409/calendar.ics`、`/api/v1/groups/edgeesmeralda/calendar.ics`
四种寻址全部 200，未知 group 正确 404。

其余三个（`/comment/list`、`/api/event/list`、`/event/discover`）仍属 §9
已知并接受的破坏——它们来自 sola-cli / dashboard 这类会报错、有人看得见的
调用方，后续随那些项目一起迁移。

### 已知且不修：一个 group 的 handle 在迁移中变了

sails 的公开 URL 按 `handle` 解析，但 ETL 把 soon 的 `name` 定义成
`username || handle`。全库只有一个 group 两者不同：handle `edgepatagonia`
vs username `edgpatagonia`（少一个 e，疑似当年的笔误），于是它在 soon 里
叫 `edgpatagonia`，所有旧链接（含日历订阅）404。该 group 有 1007 个活动。

profiles 侧为 0 例，groups 侧也没有"有 handle 但 username 为空"的情况，
所以影响面就是这一个。

修法是一条 `UPDATE groups SET name='edgepatagonia' WHERE ref_id='3635'`
（该 name 在 soon 中空闲、格式合法）。**经运维判断影响不大，决定不修。**

### `/comment/list` 的 404：不补

来源查明是切换前打开、尚未刷新的浏览器标签页——旧前端 bundle 调
`/comment/list`，新前端调 `/comments`（生产日志中 `/api/v1/comments` 正常 200）。
页面本身是切换前服务端渲染的所以显示正常，只有评论面板在轮询，用户刷新即自愈。
经运维判断不补兼容路由。
