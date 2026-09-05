## Context

Registry 发行六个 OS/arch 压缩包、每包 SPDX SBOM、checksums 及版本匹配 Skill 四项资产。

## Goals / Non-Goals

匿名下载、完整性校验和既有安装器兼容；不构建产品，不公开私有源码。

## Decisions

使用现有 yeisme.dist_verify_policy.v1。必需平台包为 Linux/macOS/Windows 的 amd64/arm64；额外资产仅允许每包 SPDX。install manifest 的 Skill digest 与公开 URL 必须验证。

## Risks / Trade-offs

真实平台运行证据以产品兼容矩阵为准。失败镜像不得替换既有成功版本；首次没有可用版本时明确不可安装。
