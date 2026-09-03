## Why

Scaena `v0.4.0` 将从单一 Linux CLI archive 扩展为同版本的三个角色包和六平台资产。`yeisme-dist` 必须在不重建私有源码、不升级 catalog schema、不中断现有 `scaena` installer 的前提下，原样镜像这些资产并在 digest 完整后生成可验证的 Homebrew/Scoop 渠道。

## What Changes

- 为 Scaena 增加 verify policy：要求三个角色的 18 archives、checksums、per-archive SBOM、command catalog 和二进制分发声明完整，缺一项即 fail closed。
- catalog 继续只有一个 `scaena` product 且保持 schema 1；增加静态 package alias，将 `scaena-api` 与 `scaena-production-worker` 解析到同一 Release 的对应 archive prefix。
- 匿名 installer additive 支持三个 package 名；默认 `scaena` 行为和既有 direct install 保持兼容。
- package manifest generator 在 exact-byte mirror 与 `asset_digests` 完成后生成三个 Homebrew Casks 和三个 Scoop manifests，不手写 generated files。
- RC 只在临时 Tap/Bucket 生成和验证 manifests，不推进 stable public channels。
- 公共 CI 增加三个 package 的 fixture 与远端 smoke 合同；任一角色或平台不完整时，三个 manifests 都保留上一稳定版本。

## Capabilities

### New Capabilities

- `scaena-package-channels`：Scaena 三包 exact-byte mirror、schema 1 静态 alias、Cask/Scoop 生成、匿名安装与 fail-closed promotion。

### Modified Capabilities

无。本仓此前没有 OpenSpec stable specs；既有 installer、catalog 与 receipt 行为作为兼容基线写入新 capability。

## Impact

- 实现 owner：`policy/scaena.json`、`scripts/sync.sh`、`scripts/generate-package-manifests.sh`、`install.sh`、`scripts/check.sh`、offline fixtures、CI 与维护文档。
- Generated assets：`catalog.json`、`receipts/scaena/**`、`Casks/scaena*.rb`、`bucket/scaena*.json` 只能由仓库脚本/CI 生成，禁止手写。
- Upstream dependency：消费 `agent/scaena/openspec/changes/scaena-v0-4-multiplatform-distribution-v1/` 冻结的 asset contract；不读取或构建 Scaena 私有源码。
- 兼容：catalog schema 1、product/tag、现有 `install.sh scaena` 和已有 stable manifests 不发生 breaking change。
