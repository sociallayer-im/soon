# Surf 图片存储

生产环境使用阿里云 OSS（杭州），公开地址为 https://assets.juluo.xyz/。

必须设置 OBJECT_STORE_PROVIDER=oss，并保留 OSS_ACCESS_KEY_ID、OSS_ACCESS_KEY_SECRET、OSS_ENDPOINT、OSS_REGION、OSS_BUCKET、OSS_PUBLIC_URL。只有 OSS 凭据而没有 provider 开关时，ObjectStore 默认使用 R2。

客户端仍通过 /api/v1/upload/image 上传；服务端完成图片规范化、安全检测，再写入 OSS。旧图片 URL 不迁移，继续引用原地址。

运行变量完整备份保存在本地忽略的 .atlas/oss-before.private.json；新变量文件为 .atlas/oss-runtime.private.json，禁止提交秘密。
