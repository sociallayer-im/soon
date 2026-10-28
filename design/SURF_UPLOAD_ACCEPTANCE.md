# Surf 活动图片上传排查（2026-10-28）

## 原因

真机请求 POST /api/v1/upload/image 已到达 Rails，返回 502。运行容器 ObjectStore.configured? 为 false：Atlas 环境缺少 AWS_ACCESS_KEY_ID、AWS_SECRET_ACCESS_KEY、AWS_HOST、AWS_BUCKET、S3_URL 五项对象存储配置。

## 修复

- 从本地私有 .env.surf.production 读取上述五项，仅合并到忽略的 .atlas/env.json；保留原有全部 26 项配置。
- 修改前保留私有恢复副本；同步服务器既有私有 app-env.json，权限 0600。
- Atlas variables import 后运行正常 source deployment。注意 redeploy 会保留旧环境快照，不能用于应用刚导入的变量。
- 首次 source build 因服务器缺少 atlas-build-runner:302b0c944dab00a5 而 ALLOCATION_FAILED。按现有 infra/build-runner 源码在服务器补建该镜像后重试；未使用本地 Docker，未新增 Nomad/Traefik 实例。
- 凭证未写入源码、文档或 Git。没有更改真实用户的活动内容。

## 验证

通过公网实际提交带认证的 multipart PNG 上传，随后读取返回的图片 URL 并比较原始字节；不打印认证 token。使用专门的演示账号，不代替用户发布活动。

验收结果：
- Atlas deployment `dep_3d45e1a8-d610-44e5-afb4-a9e635d949d4` successful。
- 当前运行容器 `app-82a9d444-1ab1-5f70-f763-66d5a95dbd4f`。
- ObjectStore 配置完整，数据库仍为 `soon_atlas`。
- 公网 POST 上传返回 200，图片 URL 返回 200 / image/png，下载字节与原图一致；图片域名为 datastore.sola.day。
- 此次为服务端配置修复，无需更新小程序。手机端重新选择图片的用户操作尚未代替执行。
