#!/usr/bin/env bash
# rollback-manifests.sh — execute or drill a Scaena package-manifest channel
# rollback (scaena-v0-4-package-channels-v1 §6.4).
#
# When the currently promoted Scaena manifests prove defective (public smoke
# failure, user report), this tool restores the previous stable generated
# state:
#   1. append an immutable failure record under
#      receipts/scaena/failures/<version>-manifest-rollback.json (redacted,
#      never rewritten — rewriting it is refused);
#   2. demote catalog latest/verified_latest past the defective version.
#      write_catalog computes the same answer from the failure record, so
#      the next CI sync converges on the rollback instead of re-promoting;
#   3. regenerate every manifest from the demoted catalog; the generator
#      removes the stale three-package group when the eligible latest falls
#      back below v0.4;
#   4. refresh the README product table.
#
# Invariants: existing success receipts are never rewritten (verified by
# digest before/after), mirrored release bytes are never touched (this tool
# performs no network or gh operations), and the upstream tag is never
# reused — the fix ships as the next patch release.
#
# Usage: rollback-manifests.sh --product scaena --version vX.Y.Z
#                               --reason "defect summary" [--root DIR] [--dry-run]
#
# --version names the defective promoted release explicitly, so an accidental
# rerun is an idempotent no-op instead of rolling back the restored latest.
# --root operates on a copy of the tree (drills, tests); default is the repo
# root. DIST_VERIFY_NOW pins the failure record produced_at.
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCT=""
VERSION=""
REASON=""
TARGET_ROOT=""
DRY_RUN=0

usage() {
  sed -n '2,28p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product) PRODUCT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --root) TARGET_ROOT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$PRODUCT" && -n "$VERSION" && -n "$REASON" ]] || usage
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
[[ "$PRODUCT" == "scaena" ]] || {
  echo "manifest group rollback is scaena-only (single multi-package product by design)" >&2
  exit 2
}
TARGET_ROOT="${TARGET_ROOT:-$SCRIPT_ROOT}"
[[ -f "$TARGET_ROOT/catalog.json" ]] || { echo "catalog not found: $TARGET_ROOT/catalog.json" >&2; exit 2; }

# dist_root()/verify.sh and catalog.sh operate on ROOT.
ROOT="$TARGET_ROOT"
export ROOT
source "$SCRIPT_ROOT/scripts/lib/verify.sh"
source "$SCRIPT_ROOT/scripts/lib/catalog.sh"

[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "--version must look like v0.4.0 (the catalog release version)" >&2
  exit 2
}
latest="$(jq -er --arg p scaena '.products[] | select(.name == $p) | .latest | select(type == "string")' \
  "$TARGET_ROOT/catalog.json")"
version="$VERSION"
record="$TARGET_ROOT/receipts/scaena/failures/$version-manifest-rollback.json"
if [[ -f "$record" ]]; then
  echo "skip: scaena/$version already carries a manifest-rollback failure record (immutable evidence; refusing to rewrite)"
  exit 0
fi
if [[ "$latest" != "scaena/$version" ]]; then
  echo "refusing: current latest is $latest, not scaena/$version." >&2
  echo "A version that is no longer promoted needs no channel rollback (its manifests are not live)." >&2
  exit 1
fi

releases="$(jq -ce --arg p scaena '.products[] | select(.name == $p) | .releases' "$TARGET_ROOT/catalog.json")"
# Restore target: newest stable release that is neither the defective version
# nor already rolled back. The extra-exclusion parameter lets us look past
# the defective version before its failure record exists on disk.
restored="$(catalog_pick_latest scaena "$releases" 1 "[\"$version\"]")"
if [[ -z "$restored" ]]; then
  echo "no previous stable $PRODUCT release to restore; refusing." >&2
  echo "A rollback with no prior stable release is a manual CI operation:" >&2
  echo "delete the six generated group files and let the catalog latest go null." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "dry-run rollback plan for $latest:"
  echo "  failure record : receipts/scaena/failures/$version-manifest-rollback.json"
  echo "  catalog latest : $latest -> $restored"
  echo "  manifests      : regenerated from the demoted catalog (stale v0.4 group files removed)"
  echo "  receipts/mirror: untouched (digest-verified after the real run)"
  exit 0
fi

# Snapshot existing success receipts so the drill can prove immutability.
receipt_sig() {
  ( cd "$TARGET_ROOT" \
    && find receipts/scaena -maxdepth 1 -name '*.json' -type f 2>/dev/null | sort \
      | xargs -r sha256sum ) | sha256sum | cut -d' ' -f1
}
receipts_before="$(receipt_sig)"

mkdir -p "$TARGET_ROOT/receipts/scaena/failures"
jq -n --arg cause "$REASON" --arg dist_tag "$latest" --arg restored "$restored" \
      --arg now "${DIST_VERIFY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" '
  {status: "failed", reason: "manifest_rollback",
   detail: {product: "scaena", dist_tag: $dist_tag, restored_latest: $restored,
            cause: $cause,
            remediation: "ship the fix as the next patch release; never reuse the upstream tag or rewrite mirrored bytes"},
   produced_at: $now}
' > "$record"
echo "recorded failure $record"

# Demote the catalog (the on-disk failure record now excludes the version).
new_latest="$(catalog_pick_latest scaena "$releases" 1)"
new_verified="$(catalog_pick_verified_latest scaena "$releases")"
[[ -n "$new_latest" ]] || { echo "internal error: demoted latest is empty" >&2; exit 1; }
catalog_tmp="$(mktemp)"
jq --arg latest "$new_latest" --arg vlatest "$new_verified" '
  (.products[] | select(.name == "scaena")) |=
    (.latest = (if $latest == "" then null else $latest end)
     | .verified_latest = (if $vlatest == "" then null else $vlatest end))
' "$TARGET_ROOT/catalog.json" > "$catalog_tmp"
mv "$catalog_tmp" "$TARGET_ROOT/catalog.json"
echo "demoted catalog latest: $latest -> $new_latest"

# Regenerate every manifest from the demoted catalog (idempotent for the
# other products; removes the stale Scaena three-package group).
"$SCRIPT_ROOT/scripts/generate-package-manifests.sh" \
  --catalog "$TARGET_ROOT/catalog.json" --output-root "$TARGET_ROOT"

write_readme_products

# Immutability proof: success receipts byte-identical, failure record present.
receipts_after="$(receipt_sig)"
if [[ "$receipts_after" != "$receipts_before" ]]; then
  echo "FATAL: success receipts changed during rollback (must stay byte-identical)" >&2
  exit 1
fi
[[ -f "$record" ]] || { echo "FATAL: failure record missing after rollback" >&2; exit 1; }
echo "rollback complete: $latest demoted to $new_latest"
echo "  - failure evidence : $record (append-only)"
echo "  - receipts/mirrors : byte-identical, untouched"
echo "  - fix path         : next patch release (never reuse $latest)"
