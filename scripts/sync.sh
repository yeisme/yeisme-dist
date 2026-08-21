#!/usr/bin/env bash
# sync.sh — mirror product releases into this public distribution repo.
#
# For every product in products.txt, copies each non-draft release (assets
# byte-identical, notes preserved) from the source repo into
# yeisme/yeisme-dist as release "<name>/<version>". Idempotent: releases
# already mirrored are skipped. Never rebuilds from source; refuses to
# mirror assets whose names trip the secret-pattern denylist.
#
# Usage: scripts/sync.sh [--limit N] [--product NAME] [--dry-run]
#   --limit N     mirror at most the newest N releases per product (0 = all)
#   --product X   mirror only product X
#   --dry-run     print what would be mirrored, change nothing
# Auth: GH_TOKEN with read access to the source repos and write access to
# this repo. CI uses the DIST_SYNC_TOKEN secret; locally `gh auth login`
# suffices. Requires gh, jq, sha256sum.
#
# Note: source release listing is capped at 100 per product per run.
set -euo pipefail

DIST_REPO="${DIST_REPO:-yeisme/yeisme-dist}"
LIMIT=0
ONLY_PRODUCT=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --product) ONLY_PRODUCT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
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

# Tripwire: asset file names that must never become public.
denied() {
  local low
  low="$(basename "$1" | tr '[:upper:]' '[:lower:]')"
  case "$low" in
    *token*|*secret*|*credential*|*.pem|*.key|*.env|*.p12|*id_rsa*|*.kdbx) return 0 ;;
    *) return 1 ;;
  esac
}

synced=0 skipped=0 failed=0
failures=()

while IFS='|' read -r name src strip; do
  name="${name//[[:space:]]/}"; src="${src//[[:space:]]/}"; strip="${strip//[[:space:]]/}"
  [[ -z "$name" || "$name" == \#* ]] && continue
  [[ -n "$ONLY_PRODUCT" && "$name" != "$ONLY_PRODUCT" ]] && continue
  echo "==> $name  (source $src)"

  gh api "repos/$src/releases?per_page=100" \
    --jq '[.[] | select(.draft == false)]' > "$WORK/$name.json" \
    || { failures+=("$name: release list failed"); failed=$((failed+1)); continue; }

  # Release tags already mirrored here (idempotency set).
  gh api --paginate "repos/$DIST_REPO/releases?per_page=100" \
    --jq '.[].tag_name' 2>/dev/null | grep -F "$name/" > "$WORK/$name.existing" || true

  mapfile -t tags < <(jq -r '.[].tag_name' "$WORK/$name.json")
  idx=0
  for tag in "${tags[@]}"; do
    idx=$((idx+1))
    if [[ "$LIMIT" -gt 0 && "$idx" -gt "$LIMIT" ]]; then break; fi
    ver="${tag#"$strip"}"
    dist_tag="$name/$ver"

    if grep -qxF "$dist_tag" "$WORK/$name.existing"; then
      echo "    skip  $dist_tag (already mirrored)"
      skipped=$((skipped+1)); continue
    fi

    n_assets="$(jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .assets | length' "$WORK/$name.json")"
    if [[ "$n_assets" -eq 0 ]]; then
      echo "    skip  $dist_tag (no assets)"
      skipped=$((skipped+1)); continue
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "    dry-run would mirror $dist_tag ($n_assets assets)"
      continue
    fi

    # Denylist check before touching the network for downloads.
    jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .assets[].name' \
      "$WORK/$name.json" > "$WORK/assets.txt"
    bad=""
    while IFS= read -r a; do
      if denied "$a"; then bad="$bad $a"; fi
    done < "$WORK/assets.txt"
    if [[ -n "$bad" ]]; then
      echo "    ERROR $dist_tag: denied asset name(s):$bad" >&2
      failures+=("$name: $dist_tag denied asset:$bad"); failed=$((failed+1)); continue
    fi

    dir="$WORK/$name/$ver"; rm -rf "$dir"; mkdir -p "$dir"
    echo "    sync  $dist_tag ($n_assets assets)"
    gh release download "$tag" -R "$src" --dir "$dir" --clobber \
      || { failures+=("$name: $dist_tag download failed"); failed=$((failed+1)); continue; }

    # Verify integrity before publishing when the release ships checksums.
    ck="$(cd "$dir" && ls -- *checksums*.txt 2>/dev/null | head -n1 || true)"
    if [[ -n "$ck" ]]; then
      (cd "$dir" && sha256sum --check "$ck" --ignore-missing >/dev/null) \
        || { failures+=("$name: $dist_tag checksum mismatch"); failed=$((failed+1)); continue; }
    fi

    jq -r --arg t "$tag" '.[] | select(.tag_name == $t) | .body // ""' \
      "$WORK/$name.json" > "$dir/.notes.md" || printf '' > "$dir/.notes.md"
    {
      echo "Mirror of \`${src}\` release \`${tag}\` (upstream repo is private)."
      echo
      echo "Assets are byte-identical copies of the upstream release. Verify with the bundled checksums and SBOM. Binaries © Yeisme, provided as-is."
      echo
      echo '---'
      echo
      cat "$dir/.notes.md"
    } > "$dir/.notes-full.md"

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

echo
echo "sync done: synced=$synced skipped=$skipped failed=$failed"
if [[ ${#failures[@]} -gt 0 ]]; then
  printf '  - %s\n' "${failures[@]}" >&2
  exit 1
fi
