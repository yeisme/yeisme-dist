# yeisme-dist

Unified **public** binary distribution for Yeisme products. Product source
repositories stay private; their release artifacts are mirrored here
byte-identically so anyone can download and install **without a GitHub
token**.

## Products

| Product | Latest | Upstream repo | Notes |
|---|---|---|---|
| eikona | v0.6.4 | `yeisme/eikona` (private) | visual asset CLI/TUI; ships installer manifest + SBOM |
| pinax | v0.2.0 | `yeisme/pinax` | notes CLI |
| auctra | v0.2.0 | `yeisme/auctra` (private) | short-drama production CLI/TUI |
| scaena | v0.1.2 | `yeisme/scaena-agent` (private) | agent control plane |
| gitea-mcp | v2.3.3 | `yeisme/gitea-mcp` (private) | Gitea MCP server |

Releases are tagged `<product>/vX.Y.Z`. More products are appended to
`products.txt` as they ship binary releases (sonora, anatomia, ordo,
inferrum, …).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/yeisme/yeisme-dist/main/install.sh | bash -s eikona
# or a pinned version / custom destination:
curl -fsSL https://raw.githubusercontent.com/yeisme/yeisme-dist/main/install.sh | bash -s auctra v0.2.0 --to /usr/local/bin
```

The installer picks the archive for your OS/arch, verifies it against the
release's checksum file, and installs to `~/.yeisme/bin`.

## Direct download

```text
https://github.com/yeisme/yeisme-dist/releases/download/<product>/<version>/<asset>
```

e.g. `https://github.com/yeisme/yeisme-dist/releases/download/eikona/v0.6.4/eikona_0.6.4_Linux_x86_64.tar.gz`
(see a release page for its full asset list).

## Integrity

- Assets are **byte-identical mirrors** of the upstream release — never
  rebuilt here (sources are private and stay private).
- Every mirrored release keeps its `checksums.txt` and SBOM
  (`.spdx.json` / `.sbom.json`); verify with
  `sha256sum --ignore-missing -c checksums.txt`.
- The sync refuses asset file names matching secret patterns
  (token/secret/credential/pem/key/env/…).

## Maintenance

- `scripts/sync.sh` mirrors releases listed in `products.txt`; it is
  idempotent (existing `<product>/<version>` tags are skipped).
- `.github/workflows/sync.yml` runs it every 6 hours and on manual
  dispatch (`Actions → Sync → Run workflow`, options: single product,
  release window, dry-run). It authenticates with the `DIST_SYNC_TOKEN`
  secret (fine-grained PAT: read contents on the upstream repos, write
  contents on this repo).
- To add a product: append `name|yeisme/<repo>|<tag-prefix-to-strip>` to
  `products.txt`, then dispatch a sync.
- To backfill history: dispatch a sync with limit 0, or locally run
  `scripts/sync.sh` (no limit) with a token that can read the upstream
  repos.

## License

Binaries © Yeisme. Provided as-is for evaluation and internal use; no
license is granted beyond downloading and running them. Sources remain
private.
