# Distribution contracts

This document defines the additive, verifiable contracts used when `yeisme-dist`
mirrors a product release whose source repository publishes a
`yeisme.product_release_handoff.v1` correlation record. Anatomia opts in via
`policy/anatomia.json`; credentialctl uses the same verify-before-mutate path
through `policy/credentialctl.json`. Products without a policy file keep the
legacy mirror path unchanged.

Owners: the **producer** (source repo, e.g. Anatomia) owns release evidence and
handoff creation. **`yeisme-dist`** owns the public mirror, catalog, receipts
and their rollback. A handoff or dispatch is never authorization to mutate the
public mirror; it is only a wake-up and correlation hint.

## 1. Wake-up hint semantics

Two paths wake the distributor:

- `repository_dispatch` (`product-release`): the producer's tag workflow may
  send `{product, channel, release_tag, source_revision, handoff_sha256}` in
  `client_payload`. The payload never carries the handoff body or any secret.
  The workflow exports it to `sync.sh` as the `DIST_HINT_JSON` environment
  variable (data only; it is parsed with `jq`, never evaluated as shell).
- Scheduled discovery (every 6 hours): same code path with no hint
  (`handoff = null` in the resulting receipt).

Rules:

- A hint is untrusted correlation data. Every field is compared against
  independently fetched upstream facts. Any mismatch (tag, revision, product)
  fails verification with reason `hint_mismatch`; it can never promote a
  mirror.
- Hint loss is recoverable: scheduled discovery converges to the same receipt
  because idempotency is keyed by verified facts, not by hint presence.
- A hint that names an already-final (immutable, matching) receipt is a no-op.

## 2. Verify policy — `yeisme.dist_verify_policy.v1`

One JSON file per opted-in product at `policy/<product>.json`:

| Field | Meaning |
| --- | --- |
| `schema_version` | `yeisme.dist_verify_policy.v1` |
| `product` / `source_repo` / `channel` | identity the policy applies to |
| `eligible_tag_pattern` | upstream tag must match after `strip_tag_prefix` |
| `exclude_prerelease` | prereleases are never stable-eligible |
| `expected_assets` | exact public archive matrix; `{version}` = upstream version **without** the leading `v` (goreleaser `{{ .Version }}`) |
| `required_assets` | extra non-archive assets that must exist (`checksums.txt`) |
| `allowed_extra_assets` | the only permitted additional assets; `{expected_archive}` stands for each expected archive name (`.spdx.json` SBOMs) |
| `source_revision_required` | the tag must resolve to a commit SHA via the git ref API |
| `checksums` | `checksums.txt` must pass `sha256sum -c` with **no** `--ignore-missing`, covering every expected archive |
| `provenance.sbom_required_per_archive` | each expected archive has a `<archive>.spdx.json` |
| `provenance.attestation` | GitHub artifact attestation is recorded (`record-only`); offline enforcement is a future, separately reviewed policy |
| `handoff.correlation_fields` | hint fields compared against verified facts |

The `anatomia` matrix covers client Darwin/Linux amd64+arm64 and server Linux
amd64+arm64. The `credentialctl` matrix covers Darwin/Linux amd64+arm64 and
Windows amd64. Both mirror their producer GoReleaser configuration. Changing a
matrix requires a producer release-process change first; a stale matrix fails
closed here.

## 3. Distribution receipt — `yeisme.dist_receipt.v1`

Location: `receipts/<product>/<version>.json` (committed to this repository,
addressable via raw.githubusercontent). Informative JSON Schema:
`schemas/dist-receipt-v1.schema.json`. Structure enforced in CI by
`scripts/check.sh`.

A successful receipt binds:

- consumed handoff digest when a hint matched (`handoff.sha256`, else `null`);
- independently verified upstream facts (`upstream_tag`, `upstream_release_ref`,
  `source_revision`, per-asset digests, checksums digest, matrix counts, SBOM
  list);
- exact mirrored asset names and digests (`mirrored_assets`, produced by
  re-hashing the mirrored release after publication);
- `distribution_revision`, `channel`, `status`, `produced_at`;
- `fingerprint_sha256` — see below.

### Fingerprint, immutability, idempotency

`fingerprint_sha256` is the SHA-256 of the `jq -S -c` canonical form of
`{product, channel, upstream_tag, source_revision, upstream_assets,
mirrored_assets, handoff.sha256}`. It is the idempotency key: the same verified
product/channel/tag/asset-digest set always yields the same fingerprint.

- **Append-only.** If `receipts/<product>/<version>.json` already exists:
  - equal fingerprint → the file is left byte-identical untouched
    ("skip immutable"); this is how scheduled discovery converges without
    churn;
  - different fingerprint → the rewrite is refused, the attempt is recorded as
    a failure, and the previously verified receipt stays authoritative.
- **No success without exact mirroring.** A receipt with `status: success`
  exists only after every expected asset was mirrored and the mirrored digests
  were re-verified to equal the verified upstream digests. Partial or failed
  copies are never represented as eligible catalog releases.
- `distribution_revision` is the count of successful receipts for the product
  at first write, and is stable afterwards because receipts are never
  rewritten.

### Failure records

Failed, stale, partial or mismatched attempts are written to
`receipts/<product>/failures/<version>.json` (last-write-wins diagnostic;
never referenced by `catalog.json`). The record is redacted: it contains
statuses and reasons, never tokens, headers or raw provider payloads.

## 4. Catalog additive fields

`catalog.json` keeps `schema_version: 1`; the anonymous installer and the
existing fields are unchanged. During every regeneration (`write_catalog`,
including `--catalog-only`), receipt evidence is joined from the local
`receipts/` directory rather than inferred from GitHub API data. Release asset
digests come from the public dist Release API. The additive fields are:

- per release (optional): `receipt` (path relative to repo root),
  `receipt_sha256` (digest of the receipt file bytes), and a `verification`
  object `{status, channel, upstream_tag, source_revision, handoff_sha256,
  distribution_revision}`;
- per release (optional): `asset_digests`, a mapping from release asset name to
  the GitHub release API's `sha256:<hex>` digest. The package-manifest generator
  uses this field to emit checksum-pinned Homebrew casks. A missing or malformed
  digest makes that product ineligible for generated package metadata; it does
  not weaken checksum verification or change `latest`;
- per product (optional): `verified_latest` — newest non-prerelease tag with a
  successful receipt, or `null`.

`latest` semantics are unchanged: a newer mirror without a successful receipt
does not advance `verified_latest`, and a failed verification of a newer
release retains the last verified entry.

## 5. Trust metadata (future, owner-gated)

Signed update metadata (threshold signatures, expiry, rollback counters, root
rotation) is designed in the producer repositories
(`docs/contracts/distribution-trust-metadata-v1.md` in Anatomia). No client
`apply` surface exists until that evidence is accepted by the security/release
owner; until then clients may at most run no-write `check` projections.

## 6. Migration and compatibility

- Products without a `policy/<name>.json` keep the legacy mirror path
  untouched.
- Existing mirrors of opted-in products made before this contract converge
  lazily: the next discovery that finds a complete mirror without a receipt
  verifies the upstream evidence and writes the receipt without re-mirroring.
- The existing manual `install.sh` stays supported. If an update path ever
  replaces it, it remains supported for at least two minor releases, tracked
  in a separate change.

## 7. Planned Scaena v0.4 multi-package projection

Scaena remains one catalog product and one canonical `scaena/vX.Y.Z` release history. The planned v0.4 projection adds three bounded aliases without changing catalog schema 1:

| Requested package | Catalog product | Archive prefix | Installed binary |
| --- | --- | --- | --- |
| `scaena` | `scaena` | `scaena_` | `scaena` |
| `scaena-api` | `scaena` | `scaena-api_` | `scaena-api` |
| `scaena-production-worker` | `scaena` | `scaena-production-worker_` | `scaena-production-worker` |

Stable package manifests are eligible only after exact-byte mirror, immutable success receipt, complete `asset_digests`, three roles × six platform/architecture archives, checksums, per-archive SBOMs, command catalog, handoff metadata and the approved binary distribution notice. Missing evidence for one role blocks all three package aliases at that version.

The generator owns three Homebrew Casks and three Scoop manifests as one atomic output group. RC manifests exist only in a temporary Tap/Bucket. Packages install only their matching binary and never register or start services. Until public fetch/install/version/help/uninstall smoke succeeds, documentation must keep Scaena Homebrew/Scoop marked planned.

Implementation and evidence are tracked in `openspec/changes/scaena-v0-4-package-channels-v1/`; the cross-repository acceptance contract remains in the parent workspace root OpenSpec.

## 8. Product Agent Skills asset declaration

An upstream release may include `<product>-install-manifest.json`. Releases
without one keep the historical mirror contract. Once present, the manifest's
Skills bundle, bundle metadata, catalog, and install manifest form an atomic
declared set: every name must be path-safe, every file must exist, every file
must be covered by the release checksum file, and all declared SHA-256 values
must match the downloaded bytes.

The shared `yeisme.product_install_manifest.v1` contract declares the three
Skills assets directly. The Eikona `eikona.install_manifest.v1` compatibility
reader keeps the declared bundle and includes version-matched metadata/catalog
when that release carries them. Dist copies the files byte-for-byte and never
opens the tarball. After publishing, it downloads the public files and verifies
the same digests. Failure removes the unverified mirror and leaves the previous
stable catalog target unchanged.
