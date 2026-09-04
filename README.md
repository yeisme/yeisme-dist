# yeisme-dist

Unified **public** binary distribution for Yeisme products. Product source
repositories stay private; their release artifacts are mirrored here
byte-identically so anyone can download and install **without a GitHub
token**.

`catalog.json` is the public index of every mirrored `<product>/vX.Y.Z`
release (latest tag, asset names, counts). The installer reads it first
so it does not have to page through GitHub Releases.

## Products

Numbers below come from `catalog.json` (regenerated on every sync).

<!-- catalog-products:start -->
| Product | Latest | Releases | Upstream repo |
|---|---|---|---|
| eikona | eikona/v0.7.5 | 20 | `yeisme/eikona` |
| pinax | pinax/v0.2.0 | 9 | `yeisme/pinax` |
| auctra | auctra/v0.3.0 | 5 | `yeisme/auctra` |
| scaena | scaena/v0.2.1 | 2 | `yeisme/scaena-agent` |
| gitea-mcp | gitea-mcp/v2.3.3 | 2 | `yeisme/gitea-mcp` |
| sonora | sonora/v0.2.2 | 3 | `yeisme/sonora` |
| anatomia | anatomia/v0.3.0 | 1 | `yeisme/anatomia` |
| mcp-gateway | - | 0 | `yeisme/mcp-gateway` |
| credentialctl | credentialctl/v0.3.0 | 1 | `yeisme/credentialctl` |
<!-- catalog-products:end -->

Releases are tagged `<product>/vX.Y.Z`. More products are appended to
`products.txt` as they ship binary releases (ordo, inferrum, quaestor,
mediahub, aigora, cohors, …).

## Install

### Linux / macOS quick install

```bash
curl -fsSL https://raw.githubusercontent.com/yeisme/yeisme-dist/main/install.sh | bash -s -- credentialctl
credentialctl --version
```

Replace `credentialctl` with any product in the table below. Pin a version or
choose an install directory when needed:

```bash
curl -fsSL https://raw.githubusercontent.com/yeisme/yeisme-dist/main/install.sh | bash -s -- sonora v0.2.2 --to /usr/local/bin
```

The installer picks the archive for your OS/arch, verifies it against the
release's checksum file, and installs to `~/.yeisme/bin`. Add that directory
to `PATH`. List mirrored products without installing:

```bash
curl -fsSL https://raw.githubusercontent.com/yeisme/yeisme-dist/main/install.sh | bash -s -- --list
```

### Homebrew

Generated tap manifests and archives both come from this public repository:

```bash
brew tap yeisme/dist https://github.com/yeisme/yeisme-dist
brew install --cask yeisme/dist/credentialctl
credentialctl --version
```

The same tap installs the other published CLIs:

```bash
brew install --cask yeisme/dist/eikona
brew install --cask yeisme/dist/pinax
brew install --cask yeisme/dist/auctra
brew install --cask yeisme/dist/scaena
brew install --cask yeisme/dist/gitea-mcp
brew install --cask yeisme/dist/sonora
brew install --cask yeisme/dist/anatomia
```

Install the credentialctl Agent Skill when using credential sync:

```bash
npx --yes skills add https://github.com/yeisme/yeisme-agent-my-skills \
  --skill credentialctl-usage --yes
```

Update with:

```bash
brew update
brew upgrade --cask yeisme/dist/credentialctl
```

If an older installation still uses `yeisme/tap/eikona`, migrate it to the
public tap. This keeps `~/.eikona` user configuration intact:

```bash
brew uninstall --cask eikona
brew untap yeisme/tap
brew tap yeisme/dist https://github.com/yeisme/yeisme-dist
brew install --cask yeisme/dist/eikona
```

### Scoop

```powershell
scoop bucket add yeisme-dist https://github.com/yeisme/yeisme-dist
scoop install credentialctl
credentialctl --version
```

Windows archives are also available for:

```powershell
scoop install eikona
scoop install pinax
scoop install auctra
scoop install gitea-mcp
scoop install sonora
```

Scaena and Anatomia do not currently publish Windows ZIP archives, so Scoop
manifests are intentionally not generated for them.

### Package-manager availability

| Product | Installer | Homebrew | Scoop |
| --- | --- | --- | --- |
| Eikona | Linux/macOS | macOS/Linux | Windows x64/arm64 |
| Pinax | Linux/macOS | macOS/Linux | Windows x64/arm64 |
| Auctra | Linux/macOS | macOS/Linux | Windows x64/arm64 |
| Scaena | Linux x64 | Linux x64 | Not available |
| gitea-mcp | Linux/macOS | macOS/Linux | Windows x64/arm64 |
| Sonora | Linux/macOS | macOS/Linux | Windows x64/arm64 |
| Anatomia | Linux/macOS | macOS/Linux | Not available |
| credentialctl | Linux/macOS | macOS/Linux | Windows x64 |

After installing Eikona, preview and apply its local setup separately:

```bash
eikona setup
eikona setup --yes
```

`eikona setup` uses only the installed binary, local user state, and the public
release matching the running CLI. It does not clone the private product source,
collect credentials, probe a provider, or perform a paid generation.

Persistent local credentials and redacted environment discovery remain explicit:

```bash
eikona auth set openai --protocol openai --api-key-stdin
eikona config env --provider openai --agent
```

## Direct download

```text
https://github.com/yeisme/yeisme-dist/releases/download/<product>/<version>/<asset>
```

e.g. `https://github.com/yeisme/yeisme-dist/releases/download/eikona/v0.6.4/eikona_0.6.4_Linux_x86_64.tar.gz`
(see a release page or `catalog.json` for the full asset list).

## Integrity

- Assets are **byte-identical mirrors** of the upstream release — never
  rebuilt here (sources are private and stay private).
- Every mirrored release keeps its `checksums.txt` and SBOM
  (`.spdx.json` / `.sbom.json`); verify with
  `sha256sum --ignore-missing -c checksums.txt`.
- The sync refuses asset file names matching secret patterns
  (token/secret/credential/pem/key/env/…).
- Incomplete mirrors (asset count ≠ upstream) are deleted and re-copied
  on the next sync.

## Maintenance

- `scripts/sync.sh` mirrors releases listed in `products.txt`; it is
  idempotent (complete `<product>/<version>` tags are skipped) and
  paginates GitHub Releases (no 100-release cap).
- `scripts/sync.sh --catalog-only` regenerates `catalog.json` from the
  current public releases without downloading assets.
- `scripts/check.sh` is the no-credential CI gate (syntax, products.txt,
  catalog schema, Linux archive presence, installer argument checks).
- `.github/workflows/sync.yml` runs every 6 hours, on manual dispatch,
  and on `repository_dispatch` `product-release` from product release
  workflows. Options: single product, release window, dry-run,
  catalog-only. It authenticates with the `DIST_SYNC_TOKEN` secret
  (fine-grained PAT: read contents on the upstream repos, write
  contents on this repo) and commits an updated `catalog.json`.
- `scripts/generate-package-manifests.sh` derives Homebrew Casks and Scoop
  manifests from each latest mirrored release and its GitHub-provided SHA-256
  digests. Eikona additionally requires its six CLI archives, checksums,
  install manifest, version-matched Skills bundle/metadata, and command catalog;
  missing assets, archive digests, or version drift fail closed.
- `.github/workflows/ci.yml` runs `scripts/check.sh` and anonymous
  `install.sh` smokes for `gitea-mcp` and `sonora` on every push/PR.
- To add a product: append `name|yeisme/<repo>|<tag-prefix-to-strip>` to
  `products.txt`, then dispatch a sync.
- To backfill history: dispatch a sync with limit 0, or locally run
  `scripts/sync.sh` (no limit) with a token that can read the upstream
  repos.
- To repair a partial mirror: re-run sync (default); pass `--no-repair`
  only when investigating.

## License

Binaries © Yeisme. Provided as-is for evaluation and internal use; no
license is granted beyond downloading and running them. Sources remain
private.

## CI/CD

- [模块化、分级 CI/CD](docs/delivery/ci-cd.md)：quick、full、integration、release 的触发场景、真实命令和权限边界。
