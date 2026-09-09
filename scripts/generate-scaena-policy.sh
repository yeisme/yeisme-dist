#!/usr/bin/env bash
# Generate policy/scaena.json from the frozen Scaena v0.4 handoff contract
# fixture (change scaena-v0-4-package-channels-v1 task 1.2). The fixture is
# the asset-name truth (see tests/fixtures/scaena/README.md); the policy file
# itself is a generated artifact — never hand-edit it.
#
# Usage: scripts/generate-scaena-policy.sh [--output FILE]
#   --output  write to FILE instead of policy/scaena.json
#
# Deterministic: same fixture + products.txt always produce identical bytes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/scaena/scaena-dist-handoff_0.4.0-contract.json"
OUTPUT="$ROOT/policy/scaena.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    --fixture) FIXTURE="$2"; shift 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
[[ -f "$FIXTURE" ]] || { echo "fixture not found: $FIXTURE" >&2; exit 2; }

# Catalog identity comes from products.txt, the same row sync.sh consumes;
# the generator refuses to run if that row drifts away from the fixture.
source_repo="$(awk -F'|' '$1 == "scaena" {print $2; exit}' "$ROOT/products.txt")"
tag_prefix="$(awk -F'|' '$1 == "scaena" {print $3; exit}' "$ROOT/products.txt")"
[[ -n "$source_repo" ]] || { echo 'products.txt missing scaena row' >&2; exit 2; }
[[ "$tag_prefix" == "scaena/" || -z "$tag_prefix" ]] || {
  echo "unexpected scaena tag prefix '$tag_prefix' in products.txt" >&2; exit 2; }
fixture_product="$(jq -er '.product' "$FIXTURE")"
[[ "$fixture_product" == "scaena" ]] || {
  echo "fixture product '$fixture_product' is not scaena" >&2; exit 2; }

fixture_version="$(jq -er '.version' "$FIXTURE")"
fixture_channel="$(jq -er '.channel' "$FIXTURE")"
[[ "$fixture_channel" == "stable" ]] || {
  echo "policy freezes the stable contract; fixture channel is '$fixture_channel'" >&2; exit 2; }

archive_count="$(jq -r '.archives | length' "$FIXTURE")"
[[ "$archive_count" -eq 18 ]] || {
  echo "fixture has $archive_count archives, want 18" >&2; exit 2; }

# Scaena opts into the verify policy from v0.4.0; older tags stay on the
# receipt-only mirror path (boundary mirrors credentialctl's v0.3 rule).
minor_boundary="$(cut -d. -f2 <<<"$fixture_version")"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

jq -n \
  --slurpfile fixture "$FIXTURE" \
  --arg source_repo "$source_repo" \
  --arg boundary "$minor_boundary" \
  --arg tag_prefix "$tag_prefix" '
  ($fixture[0]) as $f |
  {
    schema_version: "yeisme.dist_verify_policy.v1",
    product: $f.product,
    source_repo: $source_repo,
    channel: "stable",
    # policy_check_eligibility matches the raw upstream tag, which for scaena
    # carries the "scaena/" release-tag prefix (products.txt column 3).
    eligible_tag_pattern: ("^" + $tag_prefix + "v(0\\.([" + $boundary + "-9]|[1-9][0-9]+)\\.[0-9]+|[1-9][0-9]*\\.[0-9]+\\.[0-9]+)$"),
    exclude_prerelease: true,
    expected_assets: [$f.archives[].name],
    required_assets: [
      "checksums.txt",
      "scaena-command-catalog_{version}.json",
      "scaena-dist-handoff_{version}.json"
    ],
    allowed_extra_assets: [
      "{expected_archive}.sbom.json",
      "scaena.spdx.json"
    ],
    source_revision_required: true,
    checksums: {
      required: true,
      algorithm: "sha256",
      must_cover: "expected_assets"
    },
    provenance: {
      sbom_required_per_archive: true,
      sbom_asset_suffix: ".sbom.json",
      attestation: {
        expected: "github-attestation",
        enforcement: "record-only"
      }
    },
    handoff: {
      expected_schema_version: "yeisme.scaena.dist-handoff.v1",
      correlation_fields: ["channel", "release_tag", "source_revision", "handoff_sha256"]
    }
  }
' > "$tmp"

mkdir -p "$(dirname "$OUTPUT")"
mv "$tmp" "$OUTPUT"
trap - EXIT
echo "generated $OUTPUT"
