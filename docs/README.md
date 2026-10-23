# yeisme-dist 文档

本仓是 Yeisme 二进制的公开镜像，不是产品源码树。维护入口是上级 `MAINTAIN.md`。

- 分发合同：`distribution-contracts.md`
- 交付记录：`delivery/`
- 不要手改 `catalog.json` 或 `receipts/`。

## Agent Skills

Active skills 由仓库根 `.skills/profiles/targets/cli/yeisme-dist.txt` 分配：`private-release`、输出合同与演进策略。对照见 [子项目 Skill Profile](../../../docs/skills/subproject-skill-profiles.md)。

- [持续集成与交付](delivery/ci-cd.md)：按改动选择检查，区分本地、远端与发布证据。
