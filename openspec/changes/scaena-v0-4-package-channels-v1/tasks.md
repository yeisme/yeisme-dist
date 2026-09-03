## 1. Scaena handoff 与 verify policy

- [ ] 1.1 接收 Scaena owner 的 v0.4 release fixture，固定单一 product/tag、三个 package descriptor、18 archive names、required metadata、notice digest 与 prerelease 语义。
- [ ] 1.2 增加脚本命令从冻结 fixture 生成 `policy/scaena.json`，禁止手写 policy，并加入 deterministic regeneration check。
- [ ] 1.3 扩展 offline verify fixtures，覆盖完整成功、缺失 worker ARM、错误 checksum/SBOM、notice/handoff 缺失、prerelease 和 mirror digest mismatch。

## 2. 静态 package alias 与匿名 installer

- [ ] 2.1 在 installer/generator 共享合同中增加 `scaena`、`scaena-api`、`scaena-production-worker` 静态 descriptor，同时保持 catalog schema 1 和单一 `scaena` product。
- [ ] 2.2 扩展 `install.sh`，让三个 requested package 从同一 catalog release 选择各自 archive prefix 和 binary；保持 `install.sh scaena` 兼容。
- [ ] 2.3 添加 prefix collision、OS/arch、Unix tar.gz、Windows zip、checksum、custom install root 与不安装 service/config 辅助文件的测试。

## 3. 六份 package manifests 原子生成

- [ ] 3.1 扩展 manifest generator，在 successful receipt 与完整 `asset_digests` 后生成三个 Homebrew Casks 和三个 Scoop manifests。
- [ ] 3.2 Homebrew 覆盖 macOS/Linux amd64/arm64，Scoop 覆盖 Windows amd64/arm64；每个 package 只安装对应 binary，不声明依赖或 service stanza。
- [ ] 3.3 先在临时目录生成和验证六份 manifests，再原子替换 generated files；任一 hash/asset 缺失时保留上一稳定全组。
- [ ] 3.4 增加 generated-file drift check，阻断手写 `catalog.json`、receipts、Scaena policy、Casks 或 Scoop manifests。

## 4. RC、CI 与公共 smoke

- [ ] 4.1 增加 RC temporary Tap/Bucket 路径；prerelease 不推进 stable catalog、success receipt 或公共 manifests，job 结束后销毁临时渠道。
- [ ] 4.2 PR/offline CI 使用 synthetic assets 覆盖三个 package 的 fetch/install/version/help/uninstall 与 negative promotion cases，不需要 credential。
- [ ] 4.3 stable sync 后在 macOS/Linux amd64/arm64 验证三个 Casks，在 Windows amd64/arm64 验证三个 Scoop manifests；缺少 runner 或失败时不 promotion。
- [ ] 4.4 验证 public URL、asset SHA-256、installed binary 和卸载结果，并输出脱敏 handoff evidence 给根级 change。

## 5. 文档与运营边界

- [x] 5.1 更新 README、MAINTAIN、distribution contracts 与 CI/CD 文档，区分当前 Scaena Linux/amd64 direct install 和 v0.4 planned 三包渠道。
- [x] 5.2 文档化单一 catalog product、静态 aliases、mirror-before-manifest、RC isolation、无 service side effect 和官方渠道再分发边界。
- [ ] 5.3 仅在远端六份 manifests 与公共 smoke 通过后，把 Scaena Homebrew/Scoop 从 planned 改为 active 并发布真实安装命令。

## 6. 验证、handoff 与 rollback

- [ ] 6.1 运行 `openspec validate scaena-v0-4-package-channels-v1 --strict --no-interactive`、`scripts/check.sh`、`scripts/test-offline.sh` 和 generated manifest checks。
- [ ] 6.2 用 Scaena RC exact assets 完成临时渠道验收；确认 stable generated files byte-identical 未变。
- [ ] 6.3 stable `scaena/v0.4.0` 后验证 immutable receipt、catalog asset digests、六份 manifests 和 public smoke，再向根级 handoff 提交证据索引。
- [ ] 6.4 演练 manifest rollback：恢复上一 stable，保留 failure evidence，不改写 receipt/mirrored bytes，不复用上游 tag。
