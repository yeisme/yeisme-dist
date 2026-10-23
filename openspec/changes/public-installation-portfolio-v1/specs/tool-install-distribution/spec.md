## MODIFIED Requirements

### Requirement: 工具 SHALL 提供一致的包管理器安装入口

面向最终用户的 Yeisme CLI 和本地 MCP 服务二进制 SHALL 在已验证平台提供一致的公共安装体验。具有 macOS 或 Linux archive 的项目 SHALL 可通过 `yeisme/dist` Homebrew Cask 安装；具有 Windows ZIP 的项目 SHALL 可通过 `yeisme-dist` Scoop bucket 安装。缺少对应平台资产的项目 MUST NOT 生成该渠道 manifest；非 Go 或复合运行时工具 SHALL 在 owning subproject 设计中说明等价安装路线和进入公共 dist 的前置条件。

#### Scenario: Homebrew 安装命令一致
- **WHEN** 用户在 macOS 或 Linux 安装已达到 `verified` 的 Yeisme CLI 工具
- **THEN** 文档 SHALL 提供 `brew tap yeisme/dist https://github.com/yeisme/yeisme-dist` 和 `brew install --cask yeisme/dist/<tool>` 形式的命令
- **AND** 安装后 SHALL 提供 `<tool> --version` 或等价无副作用验证命令

#### Scenario: Scoop 安装命令一致
- **WHEN** 用户在 Windows 安装已发布且具有已验证 Windows ZIP 的 Yeisme CLI 工具
- **THEN** 文档 SHALL 提供 `scoop bucket add yeisme-dist https://github.com/yeisme/yeisme-dist` 和 `scoop install <tool>` 形式的命令
- **AND** 安装后 SHALL 提供 `<tool> --version` 或等价无副作用验证命令

#### Scenario: 对应平台资产缺失
- **WHEN** 产品没有 macOS/Linux archive 或 Windows ZIP
- **THEN** 对应 Homebrew 或 Scoop manifest SHALL 不生成
- **AND** 文档 SHALL 明确显示该渠道不可用，而不是提供预期失败的命令

### Requirement: Go 工具 SHALL 发布可验证的跨平台 release assets

每个进入公共快捷安装标准的 Go 工具 SHALL 通过子项目 OpenSpec change 落地所声明平台的 GitHub Release archive、checksum、SBOM、version self-check 和 post-release smoke。Homebrew、Scoop 与 Linux native package 为按真实平台覆盖选择的渠道，不再要求每个工具同时发布全部包格式。根级 change SHALL 只记录标准和 handoff，不承载子项目实现 closeout。

#### Scenario: Go 工具 release baseline 完整
- **WHEN** 子项目声明某组 OS/arch 已进入快捷安装分发标准
- **THEN** 该子项目 OpenSpec SHALL 覆盖所声明平台的 release archive、checksum、SBOM、binary version 和安装 smoke
- **AND** `yeisme-dist` SHALL 在 exact-byte 镜像完成后才生成适用的 Homebrew/Scoop manifest

#### Scenario: Root change 不追踪子项目实现
- **WHEN** 任一产品开始修改发布配置、资产命名或 installer
- **THEN** 实现任务 SHALL 写入对应子项目 `openspec/changes/<change-id>/tasks.md`
- **AND** 根级 change SHALL 只保留设计、路由、能力账本和验收合同

### Requirement: Linux SHALL 先支持直接包资产再支持仓库安装

Linux native package 为可选的产品级扩展，不是进入公共 dist 的统一前置条件。若项目选择 `.deb`、`.rpm` 或 `.apk`，SHALL 先发布可直接下载和校验的 Release 资产；建设 `apt`、`dnf/yum` 或 `apk` 签名仓库前 SHALL 创建独立基础设施 OpenSpec。

#### Scenario: 项目选择直接 Linux package
- **WHEN** 产品 owner 决定支持 `.deb`、`.rpm` 或 `.apk`
- **THEN** GitHub Release SHALL 包含所选择格式的资产与 checksum
- **AND** 子项目文档 SHALL 提供平台本地命令安装、升级和卸载示例

#### Scenario: 项目不选择 native package
- **WHEN** 产品已通过 archive installer 或 Homebrew 覆盖目标 Linux 用户
- **THEN** 缺少 `.deb`、`.rpm` 或 `.apk` MUST NOT 阻止该渠道达到 `verified`
- **AND** 文档 MUST NOT 宣称未发布的 native package 可用

#### Scenario: 仓库安装延后到独立设计
- **WHEN** Yeisme 准备支持 `apt install <tool>`、`dnf install <tool>` 或 `apk add <tool>`
- **THEN** SHALL 先创建新的根级或基础设施 OpenSpec change
- **AND** 该 change SHALL 覆盖签名 key、索引生成、托管、promotion、回滚和失陷恢复
