## Why

Yeisme 已经为一批 Go CLI 提供匿名安装器、Homebrew 和 Scoop，但其余项目仍混合了“已有可验证 Release”“只有构建管线”“仅有实验产物”“服务或内部库不适用”等状态。若继续按项目逐个补 README，用户会看到不可用命令，维护者也缺少统一的准入、成熟度、owner 和回滚合同。

## What Changes

- 建立覆盖 CLI、本地 MCP、TypeScript/Bun 工具、客户端、后台服务、共享库、数据仓与 Skills 的安装渠道组合，而不是把所有项目都强制塞入 Homebrew/Scoop。
- `yeisme-workbench` 已于 2026-10-10 退役。它不再是 Web + Go service 分发候选，不得恢复 launcher、bundle 或 desktop app。
- 定义从 `source_only` 到 `verified` 的发布成熟度状态机；只有 exact-byte Release、checksum、平台 smoke 和公共镜像均通过后，README 才能展示可复制的匿名安装命令。
- 将 Go 单二进制项目的公共镜像路径统一交给 `yeisme-dist`；TypeScript/Bun CLI 先由自身 owner 选择 package registry 或 standalone bundle；后台服务优先 OCI/Compose/systemd，桌面/浏览器客户端走独立应用分发。
- 将 Skills 安装明确为产品附带 workflow 资产或 `npx skills add` 渠道，不把 Skills 当作二进制包管理器的替代品。

## Capabilities

### New Capabilities

- `public-installation-portfolio`: 跨项目安装渠道准入、成熟度状态、项目矩阵、公共文档展示门禁和 owner handoff 合同。

### Modified Capabilities

- `tool-install-distribution`: 将已有 Go 工具分发标准扩展为多运行时、多产品形态的渠道选择规则，并规定不可用渠道不得出现在复制式安装入口中。

## Impact

- 根级治理：`cli/yeisme-dist/openspec/changes/public-installation-portfolio-v1/` 记录组合设计、能力账本、迁移顺序和验收合同。
- 公共分发 owner：`cli/yeisme-dist` 继续只镜像已发布、可校验的 exact bytes，并在资产就绪后生成 Homebrew/Scoop 清单。
- 现有已验证项目：Eikona、Pinax、Auctra、Scaena、Sonora、Anatomia、credentialctl 与 gitea-mcp 保持当前公共渠道，不发生破坏性迁移。
- 非目标：本 change 不发布 tag、不创建远端 Release、不推送包仓、不部署服务、不把内部 SDK、数据仓或内容仓包装成终端用户 CLI。
