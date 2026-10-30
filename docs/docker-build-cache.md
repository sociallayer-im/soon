# 后端 Docker 构建缓存

## 分层

- `base`：Ruby 4.0.5 slim 与运行依赖。APT 的索引和下载包使用共享锁定的 BuildKit cache mount，不进入最终镜像层。
- `javascript-deps`：固定摘要的官方 Bun 1.3.14 镜像，只读取 package.json/bun.lock；下载缓存独立保留。
- `javascript-build`：只读取 JS、样式、视图、helpers 与 bun.config.js。后端 controller/model 修改不重装 JS 依赖，也不重新构建这些资源。
- `gems`：只读取 Gemfile/Gemfile.lock，排除 development 和 test 两组，保留原生扩展编译工具。按 Ruby 完整版本和目标架构隔离安装缓存，锁定共享，避免并发写入；镜像内复制一份完整依赖，不依赖缓存挂载才能启动。
- `build`：应用代码和已构建资源合并，生成 Bootsnap 与 Rails 资源指纹。SKIP_JS_BUILD/SKIP_CSS_BUILD 只在该 RUN 中生效，防止 Rails 再次安装/编译 Bun 资源。
- `runtime`：只复制运行依赖和应用，不包含 Bun、node_modules 或系统编译工具。gems 保持只读，应用目录归 uid/gid 1000 所有。

旧配置 BUNDLE_WITHOUT=development 仍会安装 test 组依赖；现在使用 development:test。未修改 Gemfile.lock 或依赖版本，不删除业务功能。

## 缓存边界

保持同一 workspace/target 的持久 BuildKit daemon/cache；切换构建器或清理缓存后仍需冷构建。Gemfile.lock 改动会重跑 bundle install，但缓存中未变化的已编译 gems 可以复用；不承诺锁文件改变完全免编译。缓存损坏或缺失时，锁文件仍是依赖来源，不允许把缓存当发布产物。

`.dockerignore` 与 `.atlasignore` 都排除私有 .atlas/、数据库迁移快照、环境文件、密钥、旧部署凭证及文档/测试等非运行输入。文档修改不会改变应用 COPY 输入。缓存中不写运行凭证。

## 验证方法

在 HomePod 既有 BuildKit 上执行，不在 Mac 启动 Docker，不使用 QEMU，也不替换线上实例：

1. 构建并导出测试镜像；记录日志。
2. 用同一上下文立即重建，检查依赖步骤 CACHED。
3. 在独立测试上下文中修改 controller 注释，检查 Ruby/Bun 依赖及 JS 资源步骤仍命中缓存。
4. 在独立上下文修改 Gemfile 注释，检查重跑安装时复用已编译 gems。
5. 导入最终运行镜像，禁用网络，检查生产 gems、原生扩展、资源清单、非 root 身份与 Rails eager load。确认无测试依赖、编译器、node_modules、私有状态。

参考：[Docker 缓存优化](https://docs.docker.com/build/cache/optimize/)、[Bun 官方 Docker 指南](https://bun.sh/guides/ecosystem/docker)、[Bundler 配置](https://bundler.io/man/bundle-config.1.html)。

本项目当前没有 Gemfile path/vendor 依赖，所以 gems 阶段只复制两个清单文件；后续加入此类依赖时，需把对应目录显式加入该阶段的 COPY 输入。保留 script/ 内的维护脚本，避免改变现有 Rails runner 运维入口。

## HomePod 缓存容量

验证发现既有 BuildKit 的 4 GiB GC 保留预算会在完整构建后回收 Ruby/Bun 中间层，造成下一次重复安装。已在无进行中构建时，持有 Atlas 构建维护锁，将现有 `atlas-prod-buildkit` 的 `--oci-worker-gc-keepstorage` 调整为 16384。原镜像、缓存卷、CPU/内存、安全选项和 socket 路径不变；旧容器保留为 stopped 状态。该预算只影响磁盘缓存保留，不是新增内存分配，也不替换线上应用。

## 实测（2026-10-30）

同一 HomePod 构建器，包含 Docker 格式镜像导出，不包含服务启动/健康检查：

| 场景 | 耗时 | 依赖情况 |
|---|---:|---|
| 完全相同的输入重建 | 7.45 秒 | Ruby、Bun、JS 资源均 CACHED |
| controller 注释变化 | 163.48 秒 | Ruby、Bun、JS 资源均 CACHED；只重建应用部分 |
| Gemfile 注释变化，依赖解析不变 | 218.04 秒 | 重跑 bundle install，复用已编译 gems；Bun、JS 资源 CACHED |

Gemfile 场景没有出现原生扩展重新安装日志；依赖步骤本身约 36.5 秒，空 gem 缓存首次为 335.6 秒。Gemfile 的注释变化用于安全触发安装层重建，并不等于验证新增版本的编译成本。首次填充与被 GC 回收后的恢复仍有冷构建开销。详情见 docker-build-benchmark.json。

最终运行镜像禁用网络、只读根文件系统、uid 1000 烟测通过：生产依赖检查、Eth 原生签名、Oga XML、Vips 图片、bcrypt、资源清单和 Rails zeitwerk:check。测试依赖、Bun、编译器、node_modules、测试/文档目录及私有标记均不在镜像内，script/ 维护入口保留。

测试镜像 229,593,083 字节，迁移前线上镜像 254,695,758 字节。镜像仅用于验证，没有发布替换线上服务；缓存保留预算调整已经生效。
