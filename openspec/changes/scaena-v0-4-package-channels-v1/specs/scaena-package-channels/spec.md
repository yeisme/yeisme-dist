## ADDED Requirements

### Requirement: Dist SHALL 保持单一 Scaena catalog product 和三个静态 package alias

Catalog SHALL 继续只保存一个 `name=scaena` product 和一条 canonical release history。Installer 与 manifest generator SHALL additive 支持 `scaena`、`scaena-api`、`scaena-production-worker` 三个 requested package，并把它们映射到同一 Release 的对应 archive prefix。Catalog schema SHALL 保持 1。

#### Scenario: 默认 Scaena 安装保持兼容

- **WHEN** 用户运行 `install.sh scaena v0.4.0`
- **THEN** installer SHALL 从 `scaena` catalog product 选择 `scaena_<os>_<arch>` archive
- **AND** SHALL 安装 `scaena`，不选择 API 或 worker binary

#### Scenario: API alias 使用同一 release

- **WHEN** 用户运行 `install.sh scaena-api v0.4.0`
- **THEN** installer SHALL 查询 canonical `scaena/v0.4.0` Release
- **AND** SHALL 选择 `scaena-api_<os>_<arch>` archive 并安装 `scaena-api`

### Requirement: Scaena stable eligibility SHALL 要求完整的三角色资产证据

Scaena verify policy SHALL 要求三个角色的 Linux、darwin、Windows amd64/arm64 共 18 个 archives、checksums、per-archive SPDX SBOM、command catalog、二进制分发声明和 handoff metadata。所有 mirrored digests SHALL 与 independently verified upstream bytes 一致；任一 required asset 缺失或不匹配 SHALL fail closed。

#### Scenario: Worker ARM archive 缺失

- **WHEN** upstream 或 mirror 缺少一个 `scaena-production-worker_*_arm64` archive
- **THEN** sync SHALL NOT 写成功 receipt 或推进 verified stable eligibility
- **AND** generator SHALL 保留三个 package 的上一稳定 manifests

#### Scenario: Mirror digest 不匹配

- **WHEN** mirrored archive digest 与已验证 upstream digest 不同
- **THEN** sync SHALL 记录脱敏 failure evidence
- **AND** SHALL NOT 把该 Release 写成 package-manager eligible

### Requirement: Scaena package manifests SHALL 在 mirror 后原子生成

Generator SHALL 只从成功 receipt、catalog `asset_digests` 和静态 package descriptor 生成 `Casks/scaena.rb`、`Casks/scaena-api.rb`、`Casks/scaena-production-worker.rb` 以及对应三个 Scoop JSON manifests。六份输出 SHALL 先在临时目录完整生成并验证，再作为一组替换；不得手写 generated manifests。

#### Scenario: 六份 stable manifests 生成成功

- **WHEN** stable `scaena/v0.4.0` 已 exact-byte mirror 且 required digests 完整
- **THEN** generator SHALL 为三个 package 生成 Homebrew 与 Scoop manifests
- **AND** 每个 manifest SHALL 只引用 public `yeisme-dist` URL 和匹配该资产的 SHA-256

#### Scenario: 一个 Scoop hash 缺失

- **WHEN** 任一 Windows archive 没有有效 `asset_digests` entry
- **THEN** generator SHALL 失败且不替换任何 Scaena Cask/Scoop manifest
- **AND** 上一稳定六份 manifests SHALL 保持不变

### Requirement: Homebrew 与 Scoop package SHALL 独立且无 service side effect

三个 Homebrew Cask SHALL 支持 macOS/Linux amd64/arm64，三个 Scoop manifest SHALL 支持 Windows amd64/arm64。每个 package SHALL 只安装对应 binary，不声明对另两个 package 的依赖，不注册、启用或启动 systemd、launchd、Windows Service 或 `brew services`。

#### Scenario: 安装默认 Homebrew package

- **WHEN** 用户安装 `yeisme/dist/scaena`
- **THEN** Cask SHALL 只安装 `scaena` binary
- **AND** SHALL NOT 安装或启动 API/worker

#### Scenario: 安装 Windows worker package

- **WHEN** 用户通过 Scoop 安装 `scaena-production-worker`
- **THEN** manifest SHALL 安装 worker binary 并支持 `--version`/`--help`
- **AND** SHALL NOT 创建或启动 Windows Service

### Requirement: RC SHALL 与 stable public manifests 隔离

Scaena prerelease SHALL NOT 推进 catalog stable `latest`、成功 stable receipt 或公共 Cask/Scoop manifests。RC manifests MAY 仅在临时 Tap/Bucket 或 temporary directory 中生成和验证，并 SHALL 在验证结束后销毁。

#### Scenario: RC 完整通过 package smoke

- **WHEN** `scaena/v0.4.0-rc.1` 的 18 archives 与临时 package smoke 全部通过
- **THEN** CI MAY 保存脱敏 RC evidence
- **AND** public stable manifests SHALL 继续指向上一稳定版本

### Requirement: Public promotion SHALL 以真实安装 smoke 为门

Stable Scaena manifests SHALL 在公共 URL 上完成 fetch、hash、install、`--version`、`--help` 和 uninstall smoke 后才可被文档标记 active。Homebrew SHALL 覆盖 macOS/Linux 的已声明 architecture；Scoop SHALL 覆盖 Windows 的已声明 architecture。缺少 runner 或 smoke 失败 SHALL 保留 planned/prepared 状态。

#### Scenario: Cask 已生成但远端未发布

- **WHEN** 三个 Cask 只存在于本地工作树或 workflow artifact
- **THEN** README 与 root channel matrix SHALL NOT 报告 Scaena Homebrew active
- **AND** 当前用户安装文档 SHALL 继续给出已验证的 direct installer

#### Scenario: 一个平台 smoke 失败

- **WHEN** 任一 Scaena package 在声明的平台/architecture 上安装或版本验证失败
- **THEN** 同版本三个 package SHALL NOT 完成 stable channel promotion
- **AND** 上一稳定 manifests SHALL 保持可安装

### Requirement: Scaena generated state SHALL 只能由仓库脚本或 CI 写入

`catalog.json`、`receipts/scaena/**`、`policy/scaena.json`、Scaena Casks 与 Scoop manifests SHALL 通过仓库脚本或 CI 从冻结合同和验证事实生成。Agents 与维护者 SHALL NOT 手写这些 schema/state/audit/generated assets。

#### Scenario: 维护者需要更新 Scaena expected assets

- **WHEN** 上游 asset contract 发生已批准的 additive 变化
- **THEN** 维护者 SHALL 运行仓库提供的 policy/manifest generation command
- **AND** CI SHALL 验证生成结果、fixture 与上游 handoff 一致

### Requirement: Scaena channel rollback SHALL 保留不可变证据和上一稳定版本

Dist SHALL NOT 改写既有成功 receipt、重建 upstream bytes 或复用已发布 tag。缺陷 manifest SHALL 回退到上一稳定版本；新资产修复 SHALL 使用下一 patch tag。

#### Scenario: 已发布 manifest 指向有缺陷资产

- **WHEN** public smoke 或用户报告证明当前 Scaena manifest 有缺陷
- **THEN** 维护者 SHALL 回退或撤下该 manifest 并保留 failure evidence
- **AND** fixed assets SHALL 通过新的 Scaena patch Release 重新进入完整验证状态机
