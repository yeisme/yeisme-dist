#!/usr/bin/env bash
# sync.sh — mirror product releases into this public distribution repo.
#
# For every product in products.txt, copies each non-draft release (assets
# byte-identical, notes preserved) from the source repo into
# yeisme/yeisme-dist as release "<name>/<version>". Idempotent: complete
# mirrors are skipped. Incomplete mirrors are deleted and re-copied.
# Never rebuilds from source; refuses assets whose names trip the
# secret-pattern denylist.
#
# Usage: scripts/sync.sh [--limit N] [--product NAME] [--dry-run]
#                        [--no-repair] [--catalog-only]
#   --limit N       mirror at most the newest N releases per product (0 = all)
#   --product X     mirror only product X
#   --dry-run       print what would be mirrored, change nothing
#   --no-repair     leave incomplete mirrors in place (default: repair)
#   --catalog-only  regenerate catalog.json from existing dist releases
# Auth: GH_TOKEN with read access to the source repos and write access to
# this repo. CI uses the DIST_SYNC_TOKEN secret; locally `gh auth login`
# suffices. Requires gh, jq, sha256sum.
set -euo pipefail

DIST_REPO="${DIST_REPO:-yeisme/yeisme-dist}"
LIMIT=0
ONLY_PRODUCT=""
DRY_RUN=0
REPAIR=1
CATALOG_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --product) ONLY_PRODUCT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-repair) REPAIR=0; shift ;;
    --catalog-only) CATALOG_ONLY=1; shift ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo 'gh CLI required' >&2; exit 2; }
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
if [[ -z "${GH_TOKEN:-}" ]] && ! gh auth token >/dev/null 2>&1; then
  echo 'no GitHub credentials: set GH_TOKEN or run gh auth login' >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRODUCTS_FILE="${PRODUCTS_FILE:-$ROOT/products.txt}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Upstream fetch-and-verify + distribution receipts (see
# docs/distribution-contracts.md). Products with policy/<name>.json take the
# verify-before-mutate path; all others keep the legacy mirror flow below.
# On repository_dispatch the workflow sets DIST_HINT_JSON (data-only hint).
source "$ROOT/scripts/lib/verify.sh"

# Stream every JSON object from every GitHub API page into stdout.
# gh --paginate applies --jq per page; '.[]' emits one value per release.
list_releases() {
  local repo="$1"
  gh api --paginate "repos/$repo/releases?per_page=100" --jq '.[]'
}

write_catalog() {
  local generated products_json
  generated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  list_releases "$DIST_REPO" > "$WORK/dist-all.ndjson"
  products_json='[]'
  while IFS='|' read -r name src strip; do
    name="${name//[[:space:]]/}"; src="${src//[[:space:]]/}"
    [[ -z "$name" || "$name" == \#* ]] && continue
    local releases latest verified_latest
    releases="$(jq -s --arg p "$name/" '
      [.[] | select(.tag_name | startswith($p)) | {
        tag: .tag_name,
        version: (.tag_name | sub("^.*/";"")),
        published_at: (.published_at // ""),
        prerelease: .prerelease,
        asset_count: (.assets | length),
        assets: [.assets[].name]
      } + (if $p == "eikona/" then {
        asset_digests: (
          .assets
          | map(select(
              (.name | test("^eikona_[0-9]+\\.[0-9]+\\.[0-9]+_(Darwin|Linux)_(arm64|x86_64)\\.tar\\.gz$|^eikona_[0-9]+\\.[0-9]+\\.[0-9]+_Windows_(arm64|x86_64)\\.zip$"))
              and ((.digest // "") | startswith("sha256:"))
            ) | {
              key: .name,
              value: .digest
            })
          | from_entries
        )
      } else {} end)]
    ' "$WORK/dist-all.ndjson")"
    # Additive receipt fields come from the local receipts/ directory so they
    # survive every regeneration; catalog schema_version stays 1.
    releases="$(catalog_join_receipts "$name" "$releases")"
    latest="$(jq -r '
      (map(select(.prerelease == false)) | .[0].tag)
      // .[0].tag
      // empty
    ' <<<"$releases")"
    verified_latest="$(jq -r '
      (map(select(.prerelease == false and .verification.status == "verified")) | .[0].tag)
      // empty
    ' <<<"$releases")"
    products_json="$(jq --arg name "$name" --arg src "$src" --arg latest "$latest" \
        --arg vlatest "$verified_latest" --argjson releases "$releases" '
      . + [{
        name: $name,
        source_repo: $src,
        latest: (if $latest == "" then null else $latest end),
        verified_latest: (if $vlatest == "" then null else $vlatest end),
        release_count: ($releases | length),
        releases: $releases
      }]
    ' <<<"$products_json")"
  done < "$PRODUCTS_FILE"
  jq --arg generated "$generated" '{
    schema_version: 1,
    generated_at: $generated,
    dist_repo: "yeisme/yeisme-dist",
    products: .
  }' <<<"$products_json" > "$ROOT/catalog.json"
  echo "wrote $ROOT/catalog.json"
  write_readme_products
  "$ROOT/scripts/generate-package-manifests.sh"
}

write_readme_products() {
  local table tmp
  [[ -f "$ROOT/README.md" ]] || return 0
  table="$(jq -r '
    ["| Product | Latest | Releases | Upstream repo |",
     "|---|---|---|---|"]
    + [.products[] | "| \(.name) | \(.latest // "-") | \(.release_count) | `\(.source_repo)` |"]
    | .[]
  ' "$ROOT/catalog.json")"
  tmp="$(mktemp)"
  awk -v table="$table" '
    BEGIN { n = split(table, rows, "\n") }
    $0 == "<!-- catalog-products:start -->" {
      print
      for (i = 1; i <= n; i++) print rows[i]
      skip = 1
      next
    }
    $0 == "<!-- catalog-products:end -->" { skip = 0 }
    skip { next }
    { print }
  ' "$ROOT/README.md" > "$tmp"
  mv "$tmp" "$ROOT/README.md"
  echo "updated $ROOT/README.md product table"
}

if [[ "$CATALOG_ONLY" -eq 1 ]]; then
  write_catalog
  exit 0
fi

synced=0 skipped=0 repaired=0 failed=0 receipted=0
failures=()

write_release_notes() { # <src> <tag> <releases_json> <dir>
  local src="$1" tag="$2" reljson="$3" dir="$4"
  jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .body // ""' \
    "$reljson" > "$dir/.notes.md" || printf '' > "$dir/.notes.md"
  {
    echo "Mirror of \`${src}\` release \`${tag}\` (upstream repo is private)."
    echo
    echo "Assets are byte-identical copies of the upstream release. Verify with the bundled checksums and SBOM. Binaries © Yeisme, provided as-is."
    echo
    echo '---'
    echo
    cat "$dir/.notes.md"
  } > "$dir/.notes-full.md"
}

while IFS='|' read -r name src strip; do
  name="${name//[[:space:]]/}"; src="${src//[[:space:]]/}"; strip="${strip//[[:space:]]/}"
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -n "$ONLY_PRODUCT" && "$name" != "$ONLY_PRODUCT" ]] && continue
  echo "==> $name  (source $src)"

  POLICY_FILE=""
  if verify_policy_has "$name"; then
    POLICY_FILE="$ROOT/policy/$name.json"
    echo "    policy: policy/$name.json (verify-before-mutate)"
  fi

  if ! list_releases "$src" | jq -s '[.[] | select(.draft == false)]' > "$WORK/$name.json"; then
    failures+=("$name: release list failed")
    failed=$((failed+1))
    continue
  fi

  if ! list_releases "$DIST_REPO" | jq -s --arg p "$name/" \
      '[.[] | select(.tag_name | startswith($p)) | {tag:.tag_name, n:(.assets|length)}]' \
      > "$WORK/$name.existing.json"; then
    echo "    warn: could not list existing dist releases; treating as empty"
    echo '[]' > "$WORK/$name.existing.json"
  fi

  mapfile -t tags < <(jq -r '.[].tag_name' "$WORK/$name.json")
  idx=0
  for tag in "${tags[@]}"; do
    idx=$((idx+1))
    if [[ "$LIMIT" -gt 0 && "$idx" -gt "$LIMIT" ]]; then break; fi
    ver="${tag#"$strip"}"
    dist_tag="$name/$ver"

    n_assets="$(jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .assets | length' "$WORK/$name.json")"
    existing_n="$(jq -r --arg t "$dist_tag" '.[] | select(.tag == $t) | .n' "$WORK/$name.existing.json" | head -n1)"
    [[ -z "$existing_n" || "$existing_n" == "null" ]] && existing_n=0

    if [[ "$n_assets" -eq 0 ]]; then
      echo "    skip  $dist_tag (no assets)"
      skipped=$((skipped+1)); continue
    fi

    if [[ -n "$POLICY_FILE" ]]; then
      # Verify-before-mutate path (docs/distribution-contracts.md): the
      # dispatch/handoff hint is a wake-up only; independently downloaded
      # upstream evidence is verified before any mirror or catalog mutation.
      jq --arg t "$tag" '.[] | select(.tag_name == $t)' \
        "$WORK/$name.json" > "$WORK/$name.rel.json"
      if ! reason="$(policy_check_eligibility "$WORK/$name.rel.json" "$POLICY_FILE")"; then
        echo "    skip  $dist_tag (policy excludes: $reason)"
        skipped=$((skipped+1)); continue
      fi

      receipt_file="$ROOT/receipts/$name/$ver.json"
      if [[ "$existing_n" -eq "$n_assets" && -f "$receipt_file" ]]; then
        echo "    skip  $dist_tag (already mirrored, receipt present)"
        skipped=$((skipped+1)); continue
      fi

      if [[ "$DRY_RUN" -eq 1 ]]; then
        if [[ "$existing_n" -eq "$n_assets" ]]; then
          echo "    dry-run would verify and write receipt for $dist_tag ($n_assets assets)"
        else
          echo "    dry-run would verify and mirror/repair $dist_tag ($n_assets assets)"
        fi
        continue
      fi

      dir="$WORK/$name/$ver"; rm -rf "$dir"; mkdir -p "$dir"
      if ! gh release download "$tag" -R "$src" --dir "$dir" --clobber; then
        record_failed_attempt "$name" "$ver" "$(emit_fail upstream_download_failed)"
        failures+=("$name: $dist_tag upstream download failed"); failed=$((failed+1)); continue
      fi

      hint="$(hint_for_product "$name" || true)"
      if ! result="$(verify_release_evidence "$name" "$src" "$strip" "$POLICY_FILE" \
                     "$WORK/$name.rel.json" "$dir" "$hint")"; then
        reason="$(jq -r '.reason // "verify_failed"' <<<"$result")"
        echo "    ERROR $dist_tag verification failed: $reason" >&2
        record_failed_attempt "$name" "$ver" "$result"
        failures+=("$name: $dist_tag verify: $reason"); failed=$((failed+1)); continue
      fi

      action="mirror"
      if [[ "$existing_n" -eq "$n_assets" ]]; then
        action="receipt-only"   # pre-policy mirror converging to a receipt
      elif [[ "$existing_n" -gt 0 ]]; then
        action="repair"
        echo "    repair $dist_tag (dist has $existing_n/$n_assets assets, upstream verified)"
        gh release delete "$dist_tag" --repo "$DIST_REPO" --cleanup-tag --yes \
          || { failures+=("$name: $dist_tag delete failed"); failed=$((failed+1)); continue; }
        repaired=$((repaired+1))
      fi

      if [[ "$action" != "receipt-only" ]]; then
        write_release_notes "$src" "$tag" "$WORK/$name.json" "$dir"
        if ! gh release create "$dist_tag" --repo "$DIST_REPO" \
             --title "$name $ver" --notes-file "$dir/.notes-full.md" "$dir"/*; then
          record_failed_attempt "$name" "$ver" "$(emit_fail mirror_publish_failed)"
          failures+=("$name: $dist_tag publish failed"); failed=$((failed+1)); continue
        fi
      fi

      # Post-mirror exact digest verification: re-download the public mirror
      # and re-hash every expected asset before writing the receipt.
      vdir="$dir.verify"; rm -rf "$vdir"; mkdir -p "$vdir"
      if ! gh release download "$dist_tag" -R "$DIST_REPO" --dir "$vdir" --clobber; then
        record_failed_attempt "$name" "$ver" "$(emit_fail mirror_download_failed)"
        failures+=("$name: $dist_tag mirror download failed"); failed=$((failed+1)); continue
      fi
      if ! mirrored="$(verify_mirror_assets \
          "$(jq -c '.verified.upstream_assets' <<<"$result")" "$vdir")"; then
        record_failed_attempt "$name" "$ver" "$(emit_fail mirror_digest_mismatch)"
        failures+=("$name: $dist_tag mirrored digest mismatch"); failed=$((failed+1)); continue
      fi

      facts="$(jq --argjson m "$mirrored" '. + {mirrored_assets: $m}' <<<"$result")"
      if ! wout="$(write_receipt "$name" "$ver" "$facts")"; then
        record_failed_attempt "$name" "$ver" "$(emit_fail receipt_fingerprint_conflict)"
        failures+=("$name: $dist_tag receipt fingerprint conflict"); failed=$((failed+1)); continue
      fi
      if [[ "$action" == "receipt-only" ]]; then
        echo "    receipt-only $dist_tag ($wout)"
        receipted=$((receipted+1))
      else
        echo "    sync  $dist_tag ($n_assets assets, $wout)"
        synced=$((synced+1))
      fi
      continue
    fi

    if [[ "$existing_n" -eq "$n_assets" ]]; then
      echo "    skip  $dist_tag (already mirrored, $n_assets assets)"
      skipped=$((skipped+1)); continue
    fi

    if [[ "$existing_n" -gt 0 ]]; then
      echo "    repair $dist_tag (dist has $existing_n/$n_assets assets)"
      if [[ "$REPAIR" -eq 0 ]]; then
        echo "    skip  $dist_tag (--no-repair)"
        skipped=$((skipped+1)); continue
      fi
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "    dry-run would delete and re-mirror $dist_tag"
        continue
      fi
      gh release delete "$dist_tag" --repo "$DIST_REPO" --cleanup-tag --yes \
        || { failures+=("$name: $dist_tag delete failed"); failed=$((failed+1)); continue; }
      repaired=$((repaired+1))
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "    dry-run would mirror $dist_tag ($n_assets assets)"
      continue
    fi

    jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .assets[].name' \
      "$WORK/$name.json" > "$WORK/assets.txt"
    bad=""
    while IFS= read -r a; do
      if denied "$a" "$name"; then bad="$bad $a"; fi
    done < "$WORK/assets.txt"
    if [[ -n "$bad" ]]; then
      echo "    ERROR $dist_tag: denied asset name(s):$bad" >&2
      failures+=("$name: $dist_tag denied asset:$bad"); failed=$((failed+1)); continue
    fi

    dir="$WORK/$name/$ver"; rm -rf "$dir"; mkdir -p "$dir"
    echo "    sync  $dist_tag ($n_assets assets)"
    gh release download "$tag" -R "$src" --dir "$dir" --clobber \
      || { failures+=("$name: $dist_tag download failed"); failed=$((failed+1)); continue; }

    ck="$(cd "$dir" && ls -- *checksums*.txt 2>/dev/null | head -n1 || true)"
    if [[ -n "$ck" ]]; then
      (cd "$dir" && sha256sum --check "$ck" --ignore-missing >/dev/null) \
        || { failures+=("$name: $dist_tag checksum mismatch"); failed=$((failed+1)); continue; }
    fi

    write_release_notes "$src" "$tag" "$WORK/$name.json" "$dir"

    args=(release create "$dist_tag" --repo "$DIST_REPO"
          --title "$name $ver" --notes-file "$dir/.notes-full.md")
    if [[ "$(jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .prerelease' "$WORK/$name.json")" == "true" ]]; then
      args+=(--prerelease)
    fi
    gh "${args[@]}" "$dir"/* \
      || { failures+=("$name: $dist_tag publish failed"); failed=$((failed+1)); continue; }

    mirrored="$(gh release view "$dist_tag" -R "$DIST_REPO" --json assets --jq '.assets | length')"
    if [[ "$mirrored" -eq "$n_assets" ]]; then
      synced=$((synced+1))
    else
      failures+=("$name: $dist_tag mirrored $mirrored/$n_assets assets")
      failed=$((failed+1))
    fi
  done
done < "$PRODUCTS_FILE"

if [[ "$DRY_RUN" -eq 0 ]]; then
  write_catalog
fi

echo
echo "sync done: synced=$synced skipped=$skipped repaired=$repaired receipt-only=$receipted failed=$failed"
if [[ ${#failures[@]} -gt 0 ]]; then
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi
