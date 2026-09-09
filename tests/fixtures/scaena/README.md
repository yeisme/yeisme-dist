# Scaena v0.4 frozen handoff fixtures

`scaena-dist-handoff_0.4.0-contract.json` freezes the Scaena owner's v0.4
release contract for this repository (change
`scaena-v0-4-package-channels-v1` task 1.1). It mirrors the owner schema
`yeisme.scaena.dist-handoff.v1` byte-for-byte in shape.

Provenance (owner truth, pinned at the archive of
`agent/scaena/openspec/changes/scaena-v0-4-multiplatform-distribution-v1`,
2026-09-03):

- 18 fixed archive names `<package>_<goos>_<goarch>.tar.gz|.zip`:
  `agent/scaena/.goreleaser.yaml` (`name_template`) and
  `agent/scaena/scripts/scaena-release-verify.sh`.
- Top-level assets `checksums.txt` (37 entries: 18 archives + 18 per-archive
  SBOMs + command catalog) and `scaena-command-catalog_<version>.json`:
  `.goreleaser.yaml` checksum/release sections.
- Per-archive SBOM asset naming `<archive>.sbom.json` and the product-level
  `scaena.spdx.json` envelope: `agent/scaena/scripts/scaena-product-sbom.sh`.
- Handoff JSON shape and stable/prerelease semantics:
  `agent/scaena/scripts/scaena-dist-handoff.sh` and
  `agent/scaena/docs/delivery/public-binary-distribution.md`.

Digests in this fixture are deterministic contract digests
(`sha256("contract-fixture:<asset-name>")`), clearly synthetic: they can never
match real release bytes and exist only so offline tests have a stable
corpus. The real handoff asset `scaena-dist-handoff_<version>.json` ships with
each Scaena release; when it arrives, sync mirrors its bytes and this frozen
contract stays as the regression baseline for names and semantics.

The owner contract carries no top-level notice digest: the
`BINARY-DISTRIBUTION-NOTICE.txt` ships identical bytes inside every archive
(owner-verified per release by `scaena-release-verify.sh`), and on this side
it is covered transitively by the mirrored archives' checksums. If the owner
later adds an explicit notice digest field to the handoff schema, extend the
policy correlation fields and this fixture in the same change.
