## Why

Template Registry 的外部 Agent 用户需要无需私有仓 token 的二进制和版本匹配 Skill。

## What Changes

- 登记 template-registry 产品及其私有发行来源。
- 由产品 release-assets CLI 生成明确白名单验证策略。
- 复用现有同步、校验、receipt 和匿名安装流程，不接收私有源代码。

## Capabilities

### New Capabilities
- `template-registry-distribution`: Registry 匿名下载与安装。

### Modified Capabilities

无。

## Impact

仅 products.txt 和 policy、新的自动生成目录/receipt。产品代码仍由私有 Registry 仓维护。
