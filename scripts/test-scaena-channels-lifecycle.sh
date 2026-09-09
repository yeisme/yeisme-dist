#!/usr/bin/env bash
# test-scaena-channels-lifecycle.sh — offline tests for the Scaena RC
# temporary Tap/Bucket channel and the manifest rollback drill
# (change scaena-v0-4-package-channels-v1, tasks 4.1 and 6.4).
#
# Covers, without credentials and without network:
#   - rc-channel.sh create/destroy lifecycle: six RC manifests rendered into
#     a throwaway Tap/Bucket, stable generated surface proven byte-identical,
#     channel destroyed;
#   - fail-closed RC guards: stable/draft releases refused, incomplete
#     18-archive matrix refused, temporary channel cleaned on failure;
#   - the RC generator mode never writes the stable output root;
#   - --rc-url-base redirects manifest download URLs;
#   - the stable generator refuses a prerelease latest for policy products;
#   - catalog_pick_latest/catalog_pick_verified_latest: policy products never
#     fall back to a prerelease, manifest-rollback failure records demote a
#     version on every regeneration, extra exclusions compose;
#   - the rollback drill: failure record appended (never rewritten), catalog
#     demoted to the previous stable, stale group files removed by
#     regeneration, success receipts byte-identical, README table consistent,
#     rerun idempotent, and the next patch release re-promotes.
set -euo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
command -v sha256sum >/dev/null || { echo 'sha256sum required' >&2; exit 2; }
command -v ruby >/dev/null || { echo 'ruby required' >&2; exit 2; }

# Transitional guard: skip cleanly on trees without the §4.1/§6.4 files.
if [[ ! -x "$REAL_ROOT/scripts/rc-channel.sh" ]] \
   || [[ ! -x "$REAL_ROOT/scripts/rollback-manifests.sh" ]] \
   || ! grep -q 'scaena_render_matrix' "$REAL_ROOT/scripts/generate-package-manifests.sh" \
   || ! grep -q 'rolled_back_versions' "$REAL_ROOT/scripts/lib/verify.sh"; then
  echo "skip: scaena-v0-4-package-channels-v1 §4.1/§6.4 implementation files not present"
  exit 0
fi

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

fail=0
ok()  { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

ROOT="$SBX/picker-root"
export ROOT
source "$REAL_ROOT/scripts/lib/verify.sh"

SCAENA_PKGS=(scaena scaena-api scaena-production-worker)

# ---------------------------------------------------------------- helpers ---

asset_digest() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

scaena_asset_names() { # [drop <asset>]
  local drop="${1:-}" pkg os arch ext name
  for pkg in "${SCAENA_PKGS[@]}"; do
    for pair in "linux amd64" "linux arm64" "darwin amd64" "darwin arm64" "windows amd64" "windows arm64"; do
      read -r os arch _u <<<"$pair"
      ext="tar.gz"; [[ "$os" == "windows" ]] && ext="zip"
      name="${pkg}_${os}_${arch}.${ext}"
      [[ "$name" == "$drop" ]] && continue
      printf '%s\n' "$name"
    done
  done
}

# build_rc_release <out-file> <mode: rc|stable|draft|incomplete>
build_rc_release() {
  local out="$1" mode="$2"
  local drop="" prerelease=true draft=false
  case "$mode" in
    rc)         prerelease=true;  draft=false ;;
    stable)     prerelease=false; draft=false ;;
    draft)      prerelease=true;  draft=true ;;
    incomplete) prerelease=true;  draft=false; drop="scaena-production-worker_windows_arm64.zip" ;;
  esac
  local names names_json digests_json
  names_json="$( (scaena_asset_names "$drop"; echo checksums.txt) | jq -Rsc 'split("\n") | map(select(length > 0))')"
  digests_json="$( { scaena_asset_names "$drop" | while IFS= read -r n; do
      printf '%s\tsha256:%s\n' "$n" "$(asset_digest "$n")"
    done; } | jq -Rr 'split("\t") | {(.[0]): .[1]}' | jq -sc 'add // {}')"
  jq -n --argjson names "$names_json" --argjson digests "$digests_json" \
        --argjson pre "$prerelease" --argjson draft "$draft" '
    {tag_name: "scaena/v0.4.0-rc.1", draft: $draft, prerelease: $pre,
     assets: ($names | map({name: ., digest: ($digests[.] // "")}))}
  ' > "$out"
}

# v0.4-shaped catalog release entry (fake-but-valid digests).
scaena_v04_entry_json() { # <version> [drop asset]
  local version="$1" drop="${2:-}"
  local names_json digests_json
  names_json="$( (scaena_asset_names "$drop"; echo checksums.txt) | jq -Rsc 'split("\n") | map(select(length > 0))')"
  digests_json="$( { scaena_asset_names "$drop" | while IFS= read -r n; do
      printf '%s\tsha256:%s\n' "$n" "$(asset_digest "$n")"
    done; } | jq -Rr 'split("\t") | {(.[0]): .[1]}' | jq -sc 'add // {}')"
  jq -cn --arg tag "scaena/v$version" --arg version "v$version" \
        --argjson assets "$names_json" --argjson digests "$digests_json" '
    {tag: $tag, version: $version, published_at: "2026-09-09T00:00:00Z",
     prerelease: false, asset_count: ($assets | length), assets: $assets,
     asset_digests: $digests}'
}

# promote_catalog <in> <out> <version> [prerelease]
# New releases are prepended: catalog releases are newest-first (GitHub API
# order), and the latest pickers select the first eligible entry.
promote_catalog() {
  local in="$1" out="$2" version="$3" pre="${4:-false}" tmp
  # Write through a temp file so in == out (in-place promotion) cannot
  # truncate the input before jq reads it.
  tmp="$(mktemp)"
  jq --arg version "$version" --argjson entry "$(scaena_v04_entry_json "$version")" \
     --argjson pre "$pre" '
    (.products[] | select(.name == "scaena")) |=
      (.latest = "scaena/v" + $version
       | .releases = ([($entry | .prerelease = $pre)]
                      + [.releases[] | select(.tag != ("scaena/v" + $version))])
       | .release_count = (.releases | length))
  ' "$in" > "$tmp" && mv "$tmp" "$out"
}

tree_sig() { ( cd "$1" && find . -type f | sort | xargs -r sha256sum ) | sha256sum | cut -d' ' -f1; }

# ------------------------------------------------------------------ tests ---

# 1. RC channel create/destroy lifecycle.
t_rc_channel_lifecycle() {
  local chroot="$SBX/ch" root
  mkdir -p "$chroot"
  build_rc_release "$SBX/rc-release.json" rc
  root="$("$REAL_ROOT/scripts/rc-channel.sh" create \
            --tag scaena/v0.4.0-rc.1 --release "$SBX/rc-release.json" --root "$chroot")" \
    || return 1
  [[ -d "$root" && -f "$root/.stable-state.sig" ]] || return 1
  local pkg cask scoop d
  for pkg in "${SCAENA_PKGS[@]}"; do
    cask="$root/Tap/Casks/$pkg.rb"; scoop="$root/Bucket/bucket/$pkg.json"
    [[ -s "$cask" && -s "$scoop" ]] || return 1
    ruby -c "$cask" >/dev/null 2>&1 || return 1
    grep -qF 'version "0.4.0-rc.1"' "$cask" || return 1
    grep -qF "binary \"$pkg\"" "$cask" || return 1
    grep -qF "url \"https://github.com/yeisme/yeisme-dist/releases/download/scaena/v#{version}/${pkg}_" "$cask" || return 1
    [[ "$(grep -cF 'sha256 "' "$cask")" -eq 4 ]] || return 1
    d="$(asset_digest "${pkg}_darwin_amd64.tar.gz")"
    grep -qF "sha256 \"$d\"" "$cask" || return 1
    jq -e --arg v "0.4.0-rc.1" --arg bin "${pkg}.exe" '
      .version == $v and .bin == $bin
      and (.architecture["64bit"].url
           == "https://github.com/yeisme/yeisme-dist/releases/download/scaena/v0.4.0-rc.1/" + $bin[:-4] + "_windows_amd64.zip")
      and (.architecture | has("64bit") and has("arm64"))
    ' "$scoop" >/dev/null || return 1
  done
  # destroy proves the stable surface stayed byte-identical and removes the channel
  "$REAL_ROOT/scripts/rc-channel.sh" destroy --root "$root" >/dev/null || return 1
  [[ ! -e "$root" ]] || return 1
  return 0
}

# 2. RC channel refuses stable/draft releases and cleans the temp channel.
t_rc_refuses_non_prereleases() {
  local chroot="$SBX/ch2" mode
  mkdir -p "$chroot"
  for mode in stable draft; do
    build_rc_release "$SBX/rc-$mode.json" "$mode"
    if "$REAL_ROOT/scripts/rc-channel.sh" create \
         --tag scaena/v0.4.0-rc.1 --release "$SBX/rc-$mode.json" --root "$chroot" \
         >/dev/null 2>"$SBX/rc-$mode.err"; then
      echo "create accepted a $mode release" >&2; return 1
    fi
    [[ -z "$(ls -A "$chroot")" ]] || { echo "temp channel left behind for $mode" >&2; return 1; }
  done
  grep -q "prereleases only" "$SBX/rc-stable.err" || return 1
  grep -q "published releases only" "$SBX/rc-draft.err" || return 1
  return 0
}

# 3. RC channel refuses an incomplete 18-archive matrix.
t_rc_refuses_incomplete_matrix() {
  local chroot="$SBX/ch3"
  mkdir -p "$chroot"
  build_rc_release "$SBX/rc-incomplete.json" incomplete
  if "$REAL_ROOT/scripts/rc-channel.sh" create \
       --tag scaena/v0.4.0-rc.1 --release "$SBX/rc-incomplete.json" --root "$chroot" \
       >/dev/null 2>"$SBX/rc-incomplete.err"; then
    echo "create accepted an incomplete matrix" >&2; return 1
  fi
  grep -q "18-archive matrix" "$SBX/rc-incomplete.err" || return 1
  [[ -z "$(ls -A "$chroot")" ]] || return 1
}

# 4. RC generator mode never writes the stable output root; --rc-url-base
#    redirects manifest URLs.
t_rc_generator_isolation_and_url_base() {
  local outroot="$SBX/out-isolated" rcroot="$SBX/rc-isolated"
  mkdir -p "$outroot" "$rcroot"
  build_rc_release "$SBX/rc-release2.json" rc
  "$REAL_ROOT/scripts/generate-package-manifests.sh" \
    --rc-tag scaena/v0.4.0-rc.1 --rc-release "$SBX/rc-release2.json" --rc-root "$rcroot" \
    --rc-url-base "file://$SBX/proxy" --output-root "$outroot" >/dev/null 2>&1 || return 1
  [[ ! -e "$outroot/Casks" && ! -e "$outroot/bucket" ]] || return 1
  grep -qF "url \"file://$SBX/proxy/scaena/v#{version}/scaena-api_darwin_amd64.tar.gz\"," \
    "$rcroot/Tap/Casks/scaena-api.rb" || return 1
  grep -qF "file://$SBX/proxy/scaena/v0.4.0-rc.1/scaena-api_windows_amd64.zip" \
    "$rcroot/Bucket/bucket/scaena-api.json" || return 1
  return 0
}

# 5. The stable generator fails closed when a policy product's latest is a
#    prerelease (RC isolation on the stable path).
t_stable_generator_prerelease_guard() {
  local out="$SBX/gen-pre"
  promote_catalog "$REAL_ROOT/catalog.json" "$SBX/catalog-pre.json" "0.5.0" true \
    || return 1
  if "$REAL_ROOT/scripts/generate-package-manifests.sh" \
       --catalog "$SBX/catalog-pre.json" --output-root "$out" \
       >/dev/null 2>"$SBX/gen-pre.err"; then
    echo "stable generator rendered a prerelease latest" >&2; return 1
  fi
  grep -q "stable manifests render stable releases only" "$SBX/gen-pre.err" || return 1
  [[ ! -e "$out/Casks/scaena.rb" ]] || return 1
}

# 6. catalog latest selection semantics (RC isolation + rollback demotion).
t_catalog_pick_latest_semantics() {
  local rels
  rels='[{"tag":"p/v0.6.0","version":"v0.6.0","prerelease":false},
         {"tag":"p/v0.5.0","version":"v0.5.0","prerelease":true},
         {"tag":"p/v0.4.0","version":"v0.4.0","prerelease":false}]'
  [[ "$(catalog_pick_latest p "$rels" 1)" == "p/v0.6.0" ]] || return 1
  [[ "$(catalog_pick_latest p "$rels" 0)" == "p/v0.6.0" ]] || return 1
  mkdir -p "$ROOT/receipts/p/failures"
  : > "$ROOT/receipts/p/failures/v0.6.0-manifest-rollback.json"
  [[ "$(catalog_pick_latest p "$rels" 1)" == "p/v0.4.0" ]] || return 1
  [[ "$(catalog_pick_latest p "$rels" 0)" == "p/v0.4.0" ]] || return 1
  [[ "$(catalog_pick_latest p "$rels" 1 '["v0.4.0"]')" == "" ]] || return 1
  # The legacy prerelease fallback survives for non-policy products, but only
  # when no eligible stable release remains at all.
  local prels
  prels='[{"tag":"p/v0.5.0","version":"v0.5.0","prerelease":true}]'
  [[ "$(catalog_pick_latest p "$prels" 0)" == "p/v0.5.0" ]] || return 1
  [[ "$(catalog_pick_latest p "$prels" 1)" == "" ]] || return 1
  local vrels
  vrels='[{"tag":"p/v0.6.0","version":"v0.6.0","prerelease":false,
           "verification":{"status":"verified"}},
          {"tag":"p/v0.4.0","version":"v0.4.0","prerelease":false,
           "verification":{"status":"verified"}}]'
  [[ "$(catalog_pick_verified_latest p "$vrels")" == "p/v0.4.0" ]] || return 1
  [[ "$(catalog_pick_verified_latest p "$vrels" '["v0.4.0"]')" == "" ]] || return 1
  return 0
}

# 7. The rollback drill: record, demote, regenerate, receipts immutable,
#    idempotent rerun, next-patch re-promotion.
t_rollback_drill() {
  local drill="$SBX/drill"
  mkdir -p "$drill/receipts/scaena"
  cp "$REAL_ROOT/catalog.json" "$drill/catalog.json"
  cp "$REAL_ROOT/README.md" "$drill/README.md"
  # Seed the promoted (defective) v0.4.0 state exactly like a sync would.
  promote_catalog "$drill/catalog.json" "$drill/catalog.json" "0.4.0" || return 1
  "$REAL_ROOT/scripts/generate-package-manifests.sh" \
    --catalog "$drill/catalog.json" --output-root "$drill" >/dev/null 2>&1 || return 1
  local pkg
  for pkg in "${SCAENA_PKGS[@]}"; do
    [[ -s "$drill/Casks/$pkg.rb" && -s "$drill/bucket/$pkg.json" ]] || return 1
  done
  jq -n '{schema_version:"yeisme.dist_receipt.v1", status:"success",
          product:"scaena", fingerprint_sha256:"sha256:0000000000000000000000000000000000000000000000000000000000000000"}' \
    > "$drill/receipts/scaena/v0.4.0.json"
  cp "$drill/receipts/scaena/v0.4.0.json" "$SBX/receipt-before.json"
  cp "$drill/catalog.json" "$SBX/catalog-promoted.json"

  DIST_VERIFY_NOW="2026-09-09T00:00:00Z" \
    "$REAL_ROOT/scripts/rollback-manifests.sh" --product scaena --version v0.4.0 \
      --reason "drill: defective v0.4.0 manifests" --root "$drill" \
      >/dev/null 2>"$SBX/rollback.err" || { cat "$SBX/rollback.err" >&2; return 1; }

  local record="$drill/receipts/scaena/failures/v0.4.0-manifest-rollback.json"
  [[ -f "$record" ]] || return 1
  jq -e --arg now "2026-09-09T00:00:00Z" '
    .status == "failed" and .reason == "manifest_rollback"
    and .produced_at == $now
    and .detail.dist_tag == "scaena/v0.4.0"
    and .detail.restored_latest == "scaena/v0.2.1"
    and (.detail.remediation | test("next patch release"))
    and (.detail.remediation | test("never reuse"))
  ' "$record" >/dev/null || return 1
  [[ "$(jq -r '.products[] | select(.name=="scaena") | .latest' "$drill/catalog.json")" == "scaena/v0.2.1" ]] || return 1
  [[ "$(jq -r '.products[] | select(.name=="scaena") | .verified_latest' "$drill/catalog.json")" == "null" ]] || return 1
  grep -qF 'version "0.2.1"' "$drill/Casks/scaena.rb" || return 1
  for pkg in scaena-api scaena-production-worker; do
    [[ ! -e "$drill/Casks/$pkg.rb" ]] || return 1
    [[ ! -e "$drill/bucket/$pkg.json" ]] || return 1
  done
  [[ ! -e "$drill/bucket/scaena.json" ]] || return 1
  cmp -s "$SBX/receipt-before.json" "$drill/receipts/scaena/v0.4.0.json" || return 1
  grep -qF '| scaena | scaena/v0.2.1 |' "$drill/README.md" || return 1

  # Idempotent rerun: immutable evidence is never rewritten.
  local rec_sig
  rec_sig="$(sha256sum "$record" | cut -d' ' -f1)"
  "$REAL_ROOT/scripts/rollback-manifests.sh" --product scaena --version v0.4.0 \
      --reason "drill rerun" --root "$drill" >/dev/null 2>&1 || return 1
  [[ "$(sha256sum "$record" | cut -d' ' -f1)" == "$rec_sig" ]] || return 1

  # write_catalog convergence: the picker reproduces the demoted latest from
  # the on-disk failure record (no extra exclusion needed).
  local releases
  releases="$(jq -ce '.products[] | select(.name=="scaena") | .releases' "$drill/catalog.json")"
  [[ "$(ROOT="$drill" catalog_pick_latest scaena "$releases" 1)" == "scaena/v0.2.1" ]] || return 1

  # Next patch re-promotion: v0.4.1 (with a fresh full matrix) is selectable
  # again and the generator re-renders the six-file group at 0.4.1.
  jq --argjson entry "$(scaena_v04_entry_json "0.4.1")" '
    (.products[] | select(.name == "scaena")) |=
      (.latest = "scaena/v0.4.1"
       | .releases = ([$entry] + [.releases[] | select(.tag != "scaena/v0.4.1")])
       | .release_count = (.releases | length))
  ' "$drill/catalog.json" > "$SBX/catalog-fix.json"
  releases="$(jq -ce '.products[] | select(.name=="scaena") | .releases' "$SBX/catalog-fix.json")"
  [[ "$(ROOT="$drill" catalog_pick_latest scaena "$releases" 1)" == "scaena/v0.4.1" ]] || return 1
  "$REAL_ROOT/scripts/generate-package-manifests.sh" \
    --catalog "$SBX/catalog-fix.json" --output-root "$drill" >/dev/null 2>&1 || return 1
  for pkg in "${SCAENA_PKGS[@]}"; do
    grep -qF 'version "0.4.1"' "$drill/Casks/$pkg.rb" || return 1
    jq -e '.version == "0.4.1"' "$drill/bucket/$pkg.json" >/dev/null || return 1
  done
  [[ -f "$record" ]] || return 1   # failure evidence retained
  return 0
}

# 8. Rollback refuses when no previous stable release exists (nothing to
#    restore) and writes no failure record.
t_rollback_requires_previous_stable() {
  local drill="$SBX/drill-noprev"
  mkdir -p "$drill/receipts/scaena"
  jq --argjson entry "$(scaena_v04_entry_json "0.4.0")" '
    (.products[] | select(.name == "scaena")) |=
      (.latest = "scaena/v0.4.0"
       | .releases = [$entry]
       | .release_count = 1)
  ' "$REAL_ROOT/catalog.json" > "$drill/catalog.json"
  local before; before="$(tree_sig "$drill")"
  if "$REAL_ROOT/scripts/rollback-manifests.sh" --product scaena --version v0.4.0 \
       --reason "no prev" --root "$drill" >/dev/null 2>"$SBX/noprev.err"; then
    echo "rollback succeeded without a previous stable" >&2; return 1
  fi
  grep -q "no previous stable" "$SBX/noprev.err" || return 1
  [[ "$(tree_sig "$drill")" == "$before" ]] || return 1
  [[ ! -e "$drill/receipts/scaena/failures" ]] || return 1
}

# 9. Rollback is scaena-only.
t_rollback_non_scaena_refused() {
  if "$REAL_ROOT/scripts/rollback-manifests.sh" --product pinax --version v0.1.0 \
       --reason x >/dev/null 2>"$SBX/nonscaena.err"; then
    return 1
  fi
  grep -q "scaena-only" "$SBX/nonscaena.err"
}

# 10. Dry-run mutates nothing.
t_rollback_dry_run() {
  local drill="$SBX/drill-dry"
  mkdir -p "$drill/receipts/scaena"
  cp "$REAL_ROOT/catalog.json" "$drill/catalog.json"
  promote_catalog "$drill/catalog.json" "$drill/catalog.json" "0.4.0" || return 1
  local before; before="$(tree_sig "$drill")"
  "$REAL_ROOT/scripts/rollback-manifests.sh" --product scaena --version v0.4.0 \
      --reason "dry" --root "$drill" --dry-run >/dev/null || return 1
  [[ "$(tree_sig "$drill")" == "$before" ]]
}

tests=(t_rc_channel_lifecycle t_rc_refuses_non_prereleases
       t_rc_refuses_incomplete_matrix t_rc_generator_isolation_and_url_base
       t_stable_generator_prerelease_guard t_catalog_pick_latest_semantics
       t_rollback_drill t_rollback_requires_previous_stable
       t_rollback_non_scaena_refused t_rollback_dry_run)
for t in "${tests[@]}"; do
  if "$t"; then ok "$t"; else bad "$t"; fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "scaena channel lifecycle tests: FAILED" >&2
  exit 1
fi
echo "scaena channel lifecycle tests: ${#tests[@]}/${#tests[@]} passed"
