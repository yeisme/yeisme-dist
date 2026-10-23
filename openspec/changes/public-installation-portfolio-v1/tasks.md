## 1. 根级设计与治理

- [x] 1.1 盘点现有公共 dist、Homebrew、Scoop、GoReleaser、Bun bundle 与 GitHub Release 资产状态，并记录核对日期。
- [x] 1.2 冻结产品形态、渠道选择、成熟度状态机、能力账本、项目准入矩阵和 last-known-good 回滚原则。
- [x] 1.3 为 `public-installation-portfolio` 与 `tool-install-distribution` 编写可验证 Requirement/Scenario，并通过 strict OpenSpec validation。

## 2. 第一波 Go 工具 handoff

- [x] 2.1 在 `mcp/gateway/openspec/changes/mcp-gateway-public-install-v1/` 创建 owner change，要求新 tag 发布跨平台 archive/checksum/SBOM、version self-check 和 dist dispatch；验收以正式 Release 资产与 owner evidence 为准。
- [x] 2.2 在 `cli/quaestor/openspec/changes/quaestor-public-install-v1/` 创建 owner change，要求首个正式资产版本、无 Qlib 副作用 smoke、dist handoff 与 README 安装命令；验收以 GitHub Release 和干净环境 smoke 为准。
- [x] 2.3 在 `cli/yeisme-dist/openspec/changes/next-wave-cli-package-channels-v1/` 创建 dist change，仅在 MCP Gateway/Quaestor assets 完整时添加 allowlist、Cask/Scoop/installer 生成与匿名 smoke。

## 3. 复合与 Bun CLI handoff

- [x] 3.2 已取消（2026-09-26）：原执行 owner 子项目已整体退役，实验 Linux x64 bundle 迁移任务不再适用；若未来重新准入执行 owner，需另立新 change 重启该分发计划。
- [x] 3.3 已取消（2026-10-01）：用户批准Radar本地项目整体退役，原Bun standalone/SQLite/schedule发布handoff撤销；未实现或发布，未来重启需另立准入change。 | evidence: 取消/retired，不是实现完成：Radar工作区、gitlink、metadata和profile已通过私有备份20261001T084646Z-a5293e2d退出；未创建发布owner change，不生成或推送发行资产。

## 4. 客户端、服务与 Skills handoff

- [ ] 4.1 在 Workbench 现有 production release change 中记录首个公开交付形态，明确 OCI、本机 bundle、托管 Web 或 desktop app 的 owner、更新和回滚，不复用 CLI Cask 合同。
  - blocked/pending：独立 Workbench 已退役，不重建 production release change 或独立公开客户端。
- [ ] 4.2 当两个以上后台服务准备公开部署时，新建根级 `service-distribution-v1` change，统一 OCI registry、digest/signature、Compose/systemd/Kubernetes、secret injection、backup 与 rollback 门禁。
  - blocked/pending：两个以上后台服务尚未准备公开部署；`service-distribution-v1` 为 future-wave owner surface。
- [ ] 4.3 继续由 `cross-product-agent-skills-distribution-v1` 管理产品 exact-version Skill bundle；产品 README 将 `npx skills add` 写成独立可选步骤，不与二进制安装合并。
  - blocked/pending：依赖 `cross-product-agent-skills-distribution-v1` 2.1 公开 tag 授权后的产品 README 同步；不得与二进制安装合并。

## 5. 文档同步与最终验证

- [ ] 5.1 每个 owner 渠道达到 `verified` 后，先更新产品 README，再更新 `cli/yeisme-dist/README.md` 和根 README 的当前状态；未验证项目只保留源码或 preview 说明。
  - blocked/pending：尚无 owner 渠道达到 `verified`。
- [ ] 5.2 对每个新增渠道保存 owner 与 dist 两层脱敏 evidence，核对 archive digest、版本、自检、安装、升级/回滚、卸载和 fake secret 零命中。
  - blocked/pending：缺新增渠道的 owner/dist 两层脱敏 evidence。
- [ ] 5.3 所有 owner handoff 完成后运行根级 `openspec validate --all --strict`、profile/runtime Skills validation 与 `git diff --check`，再评估本 change 是否可归档。
  - blocked/pending：所有 owner handoff 未完成，不评估归档。
