## ADDED Requirements

### Requirement: 每个项目 SHALL 按产品形态选择安装或部署渠道

根级安装组合 SHALL 为每个面向用户或 operator 的项目记录 `fit`、`split-owner` 或 `reject-now`，并记录唯一首选渠道、当前成熟度、平台范围、owner 与进入下一状态的证据。目录位置、编程语言或存在可执行文件本身 MUST NOT 自动使项目成为 Homebrew 或 Scoop 候选。

#### Scenario: 单二进制 CLI 进入公共分发
- **WHEN** Go 或 standalone CLI 已发布所需平台的不可变 archive、checksum 与 SBOM
- **THEN** 该项目 SHALL 由产品 owner 提供 upstream Release，并由 `yeisme-dist` 镜像 exact bytes
- **AND** Homebrew、Scoop 与匿名 installer SHALL 只在各自平台资产存在时分别准入

#### Scenario: 后台服务不伪装成 CLI 包
- **WHEN** 项目主要交付常驻服务、数据库依赖、租户控制面或公网 API
- **THEN** 首选渠道 SHALL 是 OCI、Compose、systemd、Kubernetes 或 owner 明确的部署合同
- **AND** 通用 Homebrew/Scoop 安装 SHALL 标记为 `reject-now`

### Requirement: 渠道 SHALL 遵循可验证成熟度状态机

每个项目、渠道和平台组合 SHALL 使用 `not_applicable`、`source_only`、`pipeline_ready`、`assets_available`、`mirrored`、`manifest_ready` 或 `verified` 状态。状态推进 MUST 由对应资产与 smoke evidence 支持，不得仅依据 README、tag 名、计划或 CI 文件推断。

#### Scenario: 只有发布管线但没有资产
- **WHEN** 项目已配置 GoReleaser 或 standalone build workflow，但正式 Release 没有所需资产
- **THEN** 渠道最高 SHALL 为 `pipeline_ready`
- **AND** 默认 README 安装区 MUST NOT 展示该渠道的匿名复制命令

#### Scenario: 平台资产缺失
- **WHEN** 已镜像版本缺少 Windows ZIP
- **THEN** Scoop 状态 SHALL 保持 `not_applicable` 或低于 `manifest_ready`
- **AND** manifest 生成 SHALL fail-closed，而不是引用其它平台资产

### Requirement: 公共安装文档 SHALL 与 verified 状态一致

产品 README、根 README 与 dist README 中的默认复制式安装命令 SHALL 只引用 `verified` 渠道。每个稳定安装命令 SHALL 紧随无副作用版本或离线诊断命令；`source_only` 与 `preview` 路径 SHALL 分栏并说明限制。

#### Scenario: 项目尚未公开发布
- **WHEN** 项目处于 `source_only` 或 `pipeline_ready`
- **THEN** README MAY 提供源码构建或明确标注的 preview 命令
- **AND** SHALL 说明缺失的正式 Release、平台或验证门禁
- **AND** MUST NOT 宣称 Homebrew、Scoop 或匿名 installer 已可用

#### Scenario: 渠道完成验证
- **WHEN** 某平台渠道达到 `verified`
- **THEN** owner README SHALL 提供真实仓库、真实 package 名与真实验证命令
- **AND** 根 README SHALL 可将状态更新为“已有公开安装”

### Requirement: yeisme-dist SHALL 只镜像产品 owner 的 exact bytes

`cli/yeisme-dist` SHALL 只处理 allowlist 中已发布的 upstream assets，校验 checksum、资产完整性与版本一致性后再生成 catalog、installer、Homebrew Cask 或 Scoop manifest。dist MUST NOT 从私有源码重建产品，也 MUST NOT 在镜像不完整时推进 latest manifest。

#### Scenario: 镜像资产不完整
- **WHEN** upstream Release 的 archive、checksum、SBOM 或产品必需 metadata 缺失或 digest 不一致
- **THEN** dist SHALL 拒绝发布或更新对应 manifest
- **AND** 上一个 `verified` 版本 SHALL 保持可安装

#### Scenario: 新产品首次接入
- **WHEN** 产品 owner 已发布并验证第一组正式 assets
- **THEN** dist owner SHALL 通过自己的 OpenSpec change 将产品加入 allowlist
- **AND** SHALL 在匿名环境验证下载、安装、版本检查和卸载后才标记为 `verified`

### Requirement: Bun 和 TypeScript CLI SHALL 先拥有 owner 级 release 合同

Bun/TypeScript CLI SHALL 由 owning subproject 决定 standalone bundle 或 public package registry 路线。若已有 standalone binary/installer 合同，SHALL 优先把该合同推进为稳定多平台 Release；package 仍为 private、fixture-only 或 local-demo 时 MUST NOT 发布稳定包管理器入口。

#### Scenario: 实验性 Linux bundle
- **WHEN** 某 Bun/TypeScript CLI 只有 Actions artifact 且 release status 为 experimental
- **THEN** 稳定渠道 SHALL 保持低于 `assets_available`
- **AND** Homebrew/Scoop SHALL 等待正式 GitHub Release 与对应平台 smoke

#### Scenario: Public package registry 作为新增渠道
- **WHEN** Bun CLI owner 决定发布 npm/Bun package
- **THEN** owner spec SHALL 定义 package visibility、runtime version、lockfile/reproducibility、bin entry、upgrade、uninstall 与 smoke
- **AND** 该渠道 SHALL 独立于 standalone bundle 记录成熟度

### Requirement: 复合运行时产品 SHALL 验证默认可用体验

依赖 sidecar、worker、runtime、浏览器或其它可执行组件的产品 MUST 在公开安装前定义默认组件安装、版本绑定、诊断、升级和回滚合同。只安装主 CLI 但无法完成 README 默认 quickstart 的产物 MUST NOT 标记为 `verified`。

#### Scenario: 复合运行时产品申请 verified 渠道
- **WHEN** 依赖外部可执行组件的产品准备进入匿名安装和包管理器渠道
- **THEN** owner SHALL 提供自包含 pinned 组件资产或 digest-pinned 显式 setup 合同
- **AND** 组件缺失时 CLI SHALL 诚实返回 `unavailable` 或等价状态
- **AND** 用户 MUST NOT 需要源码 checkout 才能完成默认本地验证

### Requirement: 安装与部署 SHALL 保持凭据和业务状态分离

installer、Cask、Scoop manifest、standalone bundle 和 service package SHALL 只安装程序及静态 metadata。它们 MUST NOT 创建 provider credential、业务 workspace、数据库内容、运行证据、远程资源或开放公网 listener。

#### Scenario: 安装后需要初始化
- **WHEN** 产品需要 auth、quickstart、workspace init、serve 或 provider 配置
- **THEN** 安装完成后 SHALL 由用户显式执行产品命令
- **AND** 安装 smoke SHALL 只运行 version、help、offline doctor 或等价无副作用检查

### Requirement: Skills SHALL 使用独立的版本化安装渠道

Agent Skills SHALL 通过 `npx skills add`、产品 exact-version bundle 或共享 Skills registry 安装。Homebrew/Scoop 只负责产品二进制，MUST NOT 被描述为已经安装对应 workflow Skills。

#### Scenario: 二进制需要可选 Skill
- **WHEN** 产品提供可选 Agent 使用 Skill
- **THEN** README SHALL 将二进制安装与 Skill 安装写成两个显式步骤
- **AND** Skill 命令 SHALL 引用公共 source、明确 skill id，并保持不接收真实 secret

### Requirement: 发布验证 SHALL 产生脱敏 owner evidence

产品 owner 与 dist owner SHALL 分别保存 release 和安装验证证据。integration、component、system 或 e2e 入口 SHALL 写入 owning subproject 的 `temp/integration-test-runs/<run-id>/`，至少包含 `summary.json`、`command.txt`、`stdout.log`、`stderr.log`、`env.json` 与 `artifacts/`，并对 secret、token、Authorization、provider payload、私有路径与完整模型推理脱敏。

#### Scenario: 干净环境安装 smoke
- **WHEN** 渠道准备从 `manifest_ready` 晋级 `verified`
- **THEN** 测试 SHALL 在对应平台从公共入口安装 exact version
- **AND** SHALL 验证版本、digest、无副作用启动和卸载或回滚
- **AND** stdout、stderr、events、logs 与 evidence 中的 fake secret 扫描 SHALL 零命中

### Requirement: 失败发布 SHALL 保留 last-known-good

公开 tag 和 assets SHALL 保持不可变。新版本镜像、manifest 或安装 smoke 失败时，渠道 SHALL 保留上一 `verified` 版本，不得用覆盖旧 tag 或删除用户状态来修复。

#### Scenario: 新版本安装失败
- **WHEN** 新版本在任一目标渠道 smoke 失败
- **THEN** latest manifest SHALL 继续指向上一 `verified` 版本
- **AND** 修复 SHALL 使用新版本重新发布
- **AND** uninstall/rollback MUST NOT 默认删除用户配置、workspace、数据库或 credential
