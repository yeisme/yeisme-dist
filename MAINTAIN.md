# Maintainer notes

This repository is a **public mirror**, not a product source. Do not check out
private product code here. Do not rebuild binaries.

## Layout

| Path | Role |
| --- | --- |
| `products.txt` | Manifest: `name\|source_repo\|strip_tag_prefix` |
| `catalog.json` | Public index (generated; do not hand-edit) |
| `install.sh` | Anonymous OS/arch installer |
| `Casks/*.rb` | Generated public Homebrew casks; download only from this repository |
| `bucket/*.json` | Generated public Scoop manifests for products with Windows ZIP archives |
| `policy/<product>.json` | Optional verify policy (`yeisme.dist_verify_policy.v1`); products without one keep the legacy mirror path |
| `receipts/<product>/<version>.json` | Immutable distribution receipts (`yeisme.dist_receipt.v1`), append-only |
| `schemas/` | Informative JSON Schemas for external consumers |
| `docs/distribution-contracts.md` | Handoff-hint, verify-policy, receipt and catalog contracts |
| `scripts/sync.sh` | Mirror + repair + catalog/README refresh |
| `scripts/lib/verify.sh` | Upstream fetch-and-verify + receipt library (sourced by `sync.sh`) |
| `scripts/check.sh` | No-credential CI gate |
| `scripts/test-offline.sh` | No-credential offline fixture tests for the verify/receipt path |
| `scripts/test-scaena-packages.sh` | No-credential offline tests for the Scaena three-package channel |
| `scripts/test-scaena-channels-lifecycle.sh` | No-credential offline tests for the Scaena RC temporary channel and manifest rollback drill |
| `scripts/generate-package-manifests.sh` | Generate public Homebrew/Scoop manifests from `catalog.json` |
| `scripts/rc-channel.sh` | Scaena RC temporary Tap/Bucket create/destroy lifecycle (never touches stable surfaces) |
| `scripts/rollback-manifests.sh` | Scaena manifest group rollback: append failure record, demote catalog, regenerate |
| `.github/workflows/sync.yml` | Every 6 hours, manual dispatch, and `repository_dispatch` `product-release` |
| `.github/workflows/ci.yml` | `check.sh` + anonymous `install.sh gitea-mcp` |
| `.github/workflows/scaena-rc-channel.yml` | Manual Scaena RC temporary channel validation (read-only; channel always destroyed) |

## Commands

```bash
scripts/check.sh
scripts/test-offline.sh                   # no credentials, no network
scripts/sync.sh --catalog-only
scripts/generate-package-manifests.sh
scripts/sync.sh --product scaena --dry-run
scripts/sync.sh --product eikona          # needs GH_TOKEN that can read yeisme/eikona
bash install.sh --list
bash install.sh gitea-mcp --to /tmp/yeisme-bin
scripts/generate-package-manifests.sh       # all products use catalog digests; Eikona also checks setup assets
# Scaena RC temporary channel (prerelease smoke evidence; never promotes):
scripts/rc-channel.sh create --tag scaena/v0.4.0-rc.1 --release <upstream-release.json> --root "$RUNNER_TEMP"
scripts/rc-channel.sh destroy --root <channel-root>     # run with if: always()
# Scaena manifest group rollback (drill or real incident):
scripts/rollback-manifests.sh --product scaena --version vX.Y.Z --reason "defect summary" --dry-run
scripts/rollback-manifests.sh --product scaena --version vX.Y.Z --reason "defect summary"
```

GitHub Actions:

```bash
gh workflow run sync.yml --repo yeisme/yeisme-dist -f product=auctra
gh workflow run sync.yml --repo yeisme/yeisme-dist -f catalog_only=true
gh workflow run ci.yml --repo yeisme/yeisme-dist
# Immediate mirror after an upstream GitHub Release (same event product workflows send):
gh api repos/yeisme/yeisme-dist/dispatches --input - <<'EOF'
{"event_type":"product-release","client_payload":{"product":"sonora"}}
EOF
```

## Add a product

1. Upstream ships a non-draft GitHub Release with archives and checksums.
2. Append one line to `products.txt`.
3. Dispatch Sync for that product.
4. Confirm `catalog.json` and the README product table list the new latest tag.
5. Anonymous-install it once: `bash install.sh <name>`.

For every package-manager product, confirm the catalog contains SHA-256 digests
for each selected archive. For Eikona, additionally confirm the release contains all six CLI archives,
`checksums.txt`, `eikona-install-manifest.json`, the version-matched Skills
bundle and metadata, and the version-matched command catalog. The generated
Homebrew caveat, Scoop notes, and Bash installer must all point users to
`eikona setup` before any provider operation.

Products with a working tag→GoReleaser pipeline may be listed before the first
asset exists (`mcp-gateway`): sync skips zero-asset releases. Do not list
products with no publish pipeline (inferrum/aigora tags with 0 assets, ordo
experimental artifact, quaestor/mediahub/cohors).

## Rotate DIST_SYNC_TOKEN

Create a fine-grained PAT: Contents **read** on every private source repo in
`products.txt`, Contents **write** on `yeisme/yeisme-dist`. Then:

```bash
gh secret set DIST_SYNC_TOKEN --repo yeisme/yeisme-dist
gh workflow run sync.yml --repo yeisme/yeisme-dist -f dry_run=true
```

## Do not

- Rebuild from source or retag an existing `<product>/vX.Y.Z` with different bits.
- Commit secrets, tokens, or private source.
- Hand-edit `catalog.json` (run `scripts/sync.sh --catalog-only`).
- Edit, regenerate or rewrite an existing `receipts/<product>/<version>.json`
  (append-only; a changed verification set is a failure record under
  `receipts/<product>/failures/`, never a receipt rewrite).
- Promote a policy product's release to the catalog without a successful
  receipt; keep the last verified entry on stale or mismatched evidence.
- Remove a product from `products.txt` without also deleting its mirrored releases
  if it must leave the public channel.
