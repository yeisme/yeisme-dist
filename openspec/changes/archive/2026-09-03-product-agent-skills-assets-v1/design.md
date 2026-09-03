## Context

Dist 已拥有公共 binary mirror 和 append-only receipts。Skills assets 应沿用同一 asset
copy/digest flow，并保持 product install manifest 是唯一 expected-set 声明。

```mermaid
flowchart LR
  U[Upstream product release] --> M[Read install manifest]
  M --> V[Verify declared Skills assets and checksums]
  V --> C[Copy exact bytes]
  C --> D[Verify mirrored digests]
  D --> R[Append sync receipt]
  R --> P[Promote product release in public catalog]
```

Dist 不展开 tarball、不运行 Skill、不重写 manifest/catalog。对于未支持 Skills 的旧
release，字段缺失视为兼容；一旦 install manifest 声明 Skills asset set，则 incomplete
set 阻断该版本 promotion。

Rollback 保留上一稳定 release 指针和 bytes；已镜像但未 promotion 的失败资产可以
留作 receipt evidence，不覆盖稳定 catalog。

