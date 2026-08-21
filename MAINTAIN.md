# Maintainer notes

This repository is a **public mirror**, not a product source. Do not check out
private product code here. Do not rebuild binaries.

## Layout

| Path | Role |
| --- | --- |
| `products.txt` | Manifest: `name\|source_repo\|strip_tag_prefix` |
| `catalog.json` | Public index (generated; do not hand-edit) |
| `install.sh` | Anonymous OS/arch installer |
| `scripts/sync.sh` | Mirror + repair + catalog/README refresh |
| `scripts/check.sh` | No-credential CI gate |
| `.github/workflows/sync.yml` | Every 6 hours + manual dispatch |
| `.github/workflows/ci.yml` | `check.sh` + anonymous `install.sh gitea-mcp` |

## Commands

```bash
scripts/check.sh
scripts/sync.sh --catalog-only
scripts/sync.sh --product scaena --dry-run
scripts/sync.sh --product eikona          # needs GH_TOKEN that can read yeisme/eikona
bash install.sh --list
bash install.sh gitea-mcp --to /tmp/yeisme-bin
```

GitHub Actions:

```bash
gh workflow run sync.yml --repo yeisme/yeisme-dist -f product=auctra
gh workflow run sync.yml --repo yeisme/yeisme-dist -f catalog_only=true
gh workflow run ci.yml --repo yeisme/yeisme-dist
```

## Add a product

1. Upstream ships a non-draft GitHub Release with archives and checksums.
2. Append one line to `products.txt`.
3. Dispatch Sync for that product.
4. Confirm `catalog.json` and the README product table list the new latest tag.
5. Anonymous-install it once: `bash install.sh <name>`.

Do not add a product whose latest release has zero assets (inferrum `v1.0.0`,
mcp-gateway `v0.1.0`, aigora `v0.0.0-alpha` as of 2026-08-21).

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
- Remove a product from `products.txt` without also deleting its mirrored releases
  if it must leave the public channel.
