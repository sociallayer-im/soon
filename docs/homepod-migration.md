# Surf 后端迁移至 HomePod（2026-10-30）

新入口 https://surf-api.sola.day；旧 soon.generic.dev 按用户要求停用。源数据库保留，不删除或覆盖。

## 目标环境

- SSH ubuntu@homepod.sola.day，Atlas https://atlas.sola.day。
- 项目 homepod-surf，实例 si_5e2be168-0c3a-444c-9683-9de2013478ed。
- target tgt_2cc67fa5-9dbf-4414-acf1-f468a7c6f009，共用既有 Nomad/Traefik。
- 共用现有 postgres PG18 容器，新建独立数据库 surf_production，owner 使用现有 sola_soon_db 角色及凭证。没有修改 sola_soon_db 数据库或重启共享容器。
- 保留 Surf 原微信、JWT、Rails、支付、邮件、对象存储凭证；只替换目标数据库连接、API_URL、APP_HOST、OAUTH_ISSUER。
- 原始图片和附件继续使用原对象存储。

## 数据迁移

先保留迁移前 dump，再通过 Atlas suspend 暂停源后端，pg_dump 导出最终一致快照；通过 SSH 传输并以单事务恢复至新空数据库。快照仅在忽略目录 .atlas/homepod/migration 与 HomePod 私有目录 /home/ubuntu/surf-migration-20261030 内保存，不进入 Git。

## 后续部署

atlas.json 是 HomePod 配置，atlas.generic.json 仅保留历史配置，不要对旧环境重新执行 up。根 .atlas/link.json 已切换到 HomePod，旧私有链接保存在 .atlas/generic-preserved。

```sh
ATLAS_SERVER=https://atlas.sola.day \
ATLAS_CONFIG_DIR="$HOME/.config/atlas/homepod" \
/Users/jiang/zurich/atlas/atlas/dist/atlas up --config atlas.json
```

完整变量集合在忽略的 .atlas/env.json；import 会覆盖整集合，仅变量变更时执行。小程序默认 API 已切换，需发布新包，并在微信公众平台添加 https://surf-api.sola.day 为 request 合法域名（及所需上传合法域名）。不临时关闭域名验证。

回退必须先停止新写入再同步数据；不能直接恢复运行旧源数据库，否则会分叉。保留两个数据库与原部署用于排查。

恢复后核对所有 public 表的行数和逐行内容摘要，一致；核心数据为 8 用户、4 节点、11 活动、2 专题、6 专题活动关联、30 报名。目标复用既有工作区构建器，无新增 Nomad/Traefik/BuildKit。

## 完成验收

- Live deployment: dep_6124aca0-0d87-4daf-867d-5b42c1d12391，Atlas image release，https://surf-api.sola.day。
- 镜像：`atlas.sola.day/ws_a8f71a94af044aad916152c9566df042/builds/surf-migrated@sha256:f23b6bdfa2fd0d522cd26e6294b43f9eacfe919ad40ae62b6068a140f147969e`。
- 从 generic.dev 已验收的版本 22 镜像转存，摘要完全一致；应用代码对应 ea947fa，与迁移配置提交的 app/config/Gemfile/Dockerfile 无差异。image release 版本接口 gitCommit 为 null，溯源以该不可变摘要和源部署记录为准。
- 冷构建触及 Runner 原 900 秒上限；重试在替换 Runner 前经 Atlas 正常取消。Atlas 源码 8795e016 移除该限制，HomePod 控制面已固定新 Runner 摘要。当前发布采用镜像复用，不等待再次冷编译。
- HTTPS 普通证书校验通过；/up、/cities、/campaigns、/users/suggestions、/groups/directory、专题活动过滤全部 200；无 js_code 微信登录请求 422，真实微信登录尚需新包验收。
- 容器连接确认 surf_production，8 用户、4 节点、11 活动、2 专题、30 报名。旧地址 /up 返回 404，sola.day 返回 200。
- 对象存储及现有微信、JWT、Rails 等凭证保留。Bun 保持现有方案。
