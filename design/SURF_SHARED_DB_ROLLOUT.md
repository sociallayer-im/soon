# Surf 与主站合库的发布顺序

1. 备份主站库并恢复到隔离库核验。保留现网两侧各自的 issuer、WEB_URL 和 RSA 私钥，核对各自 JWKS 与迁移前一致。主站设置 OAUTH_PROVIDER=main，Surf 设置 OAUTH_PROVIDER=surf、DISCUSSION_ENABLED=true 和群组白名单。
2. 先单独执行主站兼容分支 integration/main-oauth-rollback（79e326a）的数据库迁移，并用该版本替换所有旧主站实例。记录实际镜像摘要，验证主站客户端可用。待旧实例退出流量后再导入 WiConnect。候选实例设置 DEPLOYMENT_WARMUP=true，数据库迁移显式执行。
3. 运行合并分支的增量迁移与 706 导入，复跑导入，对照两边授权入口和 userinfo 的本端成功、跨端拒绝结果。Surf 新申请群组经审核并加入白名单后，可使用默认公共版块。
4. 主站应用回退到第 2 步记录的兼容镜像，保留已升级的数据库结构。Surf 继续使用自己的 issuer 配置。主站更早的镜像不支持 OAuth 应用隔离，不能用于合库后的回退。
