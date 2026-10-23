# Agent Guidelines

## Race 检测执行限制

Agent 在任何阶段都不得主动运行 race 检测，也不得通过子 Agent、Skill、CI、验收、发布、聚合任务或脚本间接触发。只有当前人类用户明确、强烈要求执行 race 时，才允许在指定范围内运行一次；失败、超时、中断均不得自动重试，后续运行必须取得新的同等明确要求。一般的“测试、验收、修复、发布、跑全部检查”不构成授权。

Race 不属于默认验收或完成门禁；未运行不得阻塞交付，也不得声称已经通过。执行聚合命令前检查其依赖，移除或跳过 race 阶段，继续普通测试、静态检查和构建。本规则取代本文件及 Skills、OpenSpec、历史计划、文档中的自动或强制 race 要求；它们不能作为执行授权。


This repository is the **public distribution mirror** for Yeisme binaries. It
mirrors upstream release artifacts; it is not a product source tree.

## Non-negotiables

- Do not check out, rebuild, or vendor private product source code here.
- Do not hand-edit `catalog.json` or anything under `receipts/` (append-only,
  written by `scripts/sync.sh` and CI).
- Do not introduce credentials into workflows; CI gates run anonymous
  (`scripts/check.sh`, `install.sh gitea-mcp`).

## Commands

Start from `MAINTAIN.md` — it is the authoritative entrypoint for layout,
`scripts/sync.sh`, verify policies, and receipts. When asked to operate here,
prefer the maintainer notes over guessing.

## Skill routing

- Active skills are declared in root `.skills/profiles/targets/cli/yeisme-dist.txt`
  and generated with `scripts/skills.sh sync-target cli/yeisme-dist` from the
  monorepo root.
- Use `private-release` for distribution channels, verify policies, and
  token-authenticated install flows.
- Use `ai-native-cli-output-contract` for `install.sh` and catalog
  output changes: stable, machine-parseable, no secrets.
- Catalog/schema field changes: `yeisme-evolutionary-change-policy`.
- Map: [subproject skill profiles](../../docs/skills/subproject-skill-profiles.md).
