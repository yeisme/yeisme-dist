## Why

Scaena 与 Eikona product releases 需要公开匿名下载 exact-version Skills assets，但
`yeisme-dist` 不能成为 bundle builder、Skill marketplace 或产品策略 owner。

## What Changes

- Dist sync 识别产品声明的 Skills tarball、bundle manifest、install manifest 与 catalog。
- 所有资产 exact-byte mirror，并与 upstream/install manifest/checksums 交叉校验。
- 缺失、digest mismatch 或未声明资产 fail closed，保留上一稳定镜像。
- Catalog schema 与产品 identity 不变；不解析或重建 Skill 内容。

## Capabilities

### New Capabilities

- `product-agent-skills-assets`: 产品 Skills release assets 的透明镜像与完整性验证。

## Impact

- `scripts/sync.sh`、fixture/check scripts、MAINTAIN.md 与 receipt evidence。
- 不修改产品 bundle、用户 registry 或 runtime 目录。

