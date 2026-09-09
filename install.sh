#!/usr/bin/env bash
# Anonymous installer for Yeisme products mirrored in the public
# yeisme/yeisme-dist repository.
#
#   curl -fsSL https://raw.githubusercontent.com/yeisme/yeisme-dist/main/install.sh | bash -s <product> [version] [--to DIR]
#
# Resolves the newest <product>/vX.Y.Z release (catalog.json first, then
# paginated GitHub Releases), picks the archive for the detected OS/arch,
# verifies it against the release checksums, extracts the binary, and
# installs it to ~/.yeisme/bin (override with --to).
set -euo pipefail

DIST_REPO="${DIST_REPO:-yeisme/yeisme-dist}"
DIST_CATALOG_URL="${DIST_CATALOG_URL:-https://raw.githubusercontent.com/${DIST_REPO}/main/catalog.json}"
# Offline fixture tests override the GitHub API base with a local server.
DIST_API_BASE="${DIST_API_BASE:-https://api.github.com}"
DEST="${HOME}/.yeisme/bin"
product=""
version=""

KNOWN_FALLBACK=(eikona pinax auctra scaena gitea-mcp sonora anatomia mcp-gateway credentialctl)

# Static Scaena package aliases (scaena-v0-4-package-channels-v1): one catalog
# product "scaena", three public package names mapping to archive prefixes of
# the same Release. install.sh is curl-piped standalone, so the table is
# embedded here; scripts/lib/scaena-packages.sh and the offline fixture tests
# keep it from drifting against the manifest generator.
scaena_package_product() {
  case "$1" in
    scaena|scaena-api|scaena-production-worker) echo scaena ;;
    *) return 1 ;;
  esac
}
scaena_package_prefix() {
  case "$1" in
    scaena) echo "scaena_" ;;
    scaena-api) echo "scaena-api_" ;;
    scaena-production-worker) echo "scaena-production-worker_" ;;
    *) return 1 ;;
  esac
}

auth=()
[[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")

curl_json() {
  curl -fsSL --retry 3 --retry-delay 2 "${auth[@]}" "$1"
}

load_catalog() {
  if [[ -f catalog.json ]]; then
    cat catalog.json
    return 0
  fi
  curl_json "$DIST_CATALOG_URL" 2>/dev/null || true
}

product_list() {
  if [[ -f products.txt ]]; then
    awk -F'|' '/^[[:space:]]*#/ {next} NF>=2 {gsub(/[[:space:]]/,"",$1); if($1!="") print $1}' products.txt
    return
  fi
  printf '%s\n' "${KNOWN_FALLBACK[@]}"
}

list_products() {
  local catalog
  catalog="$(load_catalog 2>/dev/null || true)"
  if [[ -n "$catalog" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r '.products[] | "\(.name)  \(.latest // "-")  \(.release_count) releases"' <<<"$catalog"
    else
      sed -n 's/^[[:space:]]*"name": "\([^"]*\)",[[:space:]]*$/\1/p' <<<"$catalog"
    fi
    return
  fi
  product_list
}

usage() {
  local products
  products="$(product_list | paste -sd, - | sed 's/,/, /g')"
  cat <<EOF
usage: install.sh <product> [version] [--to DIR]
       install.sh --list

  product   one of: ${products:-eikona, pinax, auctra, scaena, gitea-mcp, sonora, anatomia, mcp-gateway}
  version   vX.Y.Z (default: newest release); plain X.Y.Z also accepted
  --to      install directory (default: ~/.yeisme/bin)
  --list    print mirrored products and latest tags
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) DEST="$2"; shift 2 ;;
    --list) list_products; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$product" ]]; then product="$1"
      elif [[ -z "$version" ]]; then version="$1"
      else usage >&2; exit 2; fi
      shift ;;
  esac
done
[[ -n "$product" ]] || { usage >&2; exit 2; }

# Resolve Scaena package aliases before any catalog/tag handling: the catalog
# product stays "scaena"; the requested package name drives archive prefix
# and installed binary. Everything else is untouched.
package="$product"
if alias_product="$(scaena_package_product "$product")"; then
  product="$alias_product"
fi
if [[ -n "$version" ]]; then
  case "$version" in
    "$package"/*|"$product"/*) ;;
    v*) version="$product/$version" ;;
    *) version="$product/v$version" ;;
  esac
fi

die() { echo "install: $*" >&2; exit 1; }

os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux) os_re='[Ll]inux' ;;
  Darwin) os_re='[Dd]arwin|[Mm]ac[Oo][Ss]' ;;
  *) die "unsupported OS '$os' (use the release archives directly)" ;;
esac
case "$arch" in
  x86_64|amd64) arch_re='(x86_64|amd64)' ;;
  arm64|aarch64) arch_re='(arm64|aarch64)' ;;
  *) die "unsupported arch '$arch'" ;;
esac
# Scaena v0.4 archive names use goreleaser goos/goarch tokens.
os_token="linux"; [[ "$os" == "Darwin" ]] && os_token="darwin"
arch_token="amd64"; [[ "$arch" == "arm64" || "$arch" == "aarch64" ]] && arch_token="arm64"

catalog_has_product() {
  local catalog="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg p "$product" '(.products // []) | any(.name == $p)' <<<"$catalog" >/dev/null 2>&1
  else
    grep -q "\"name\": \"$product\"" <<<"$catalog"
  fi
}

latest_from_catalog() {
  local catalog="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg p "$product" '
      (.products // [])[]
      | select(.name == $p)
      | .latest // empty
    ' <<<"$catalog" | head -n1
  else
    # Fallback: first <product>/v* tag_name-shaped latest field after the product object.
    grep -A20 "\"name\": \"$product\"" <<<"$catalog" | grep -o "\"latest\": \"[^\"]*\"" | head -n1 | sed 's/.*: "//;s/"$//'
  fi
}

latest_from_api() {
  local page=1 json tag
  while [[ "$page" -le 20 ]]; do
    json="$(curl_json "$DIST_API_BASE/repos/$DIST_REPO/releases?per_page=100&page=$page" 2>/dev/null || true)"
    [[ -n "$json" ]] || return 1
    if command -v jq >/dev/null 2>&1; then
      if [[ "$(jq -r 'length' <<<"$json" 2>/dev/null || echo 0)" -eq 0 ]]; then
        return 1
      fi
      tag="$(jq -r --arg p "$product/" '
        [.[] | select(.draft != true) | .tag_name | select(startswith($p))]
        | .[0] // empty
      ' <<<"$json")"
    else
      if grep -q '^\[\]$' <<<"$json"; then
        return 1
      fi
      tag="$(grep -o "\"tag_name\": \"${product}/[^\"]*\"" <<<"$json" | head -n1 | sed 's/.*: "//;s/"$//')"
    fi
    [[ -n "$tag" ]] && { printf '%s\n' "$tag"; return 0; }
    page=$((page+1))
  done
  return 1
}

catalog="$(load_catalog || true)"
if [[ -n "$catalog" ]]; then
  catalog_has_product "$catalog" || die "unknown product '$product' (not in catalog.json)"
fi

rel_tag="$version"
if [[ -z "$rel_tag" ]]; then
  if [[ -n "$catalog" ]]; then
    rel_tag="$(latest_from_catalog "$catalog" || true)"
  fi
  if [[ -z "$rel_tag" || "$rel_tag" == "null" ]]; then
    rel_tag="$(latest_from_api || true)"
  fi
  [[ -n "$rel_tag" && "$rel_tag" != "null" ]] || die "no release found for '$product' in $DIST_REPO"
fi

rel_json="$(curl_json "$DIST_API_BASE/repos/$DIST_REPO/releases/tags/$rel_tag")" \
  || die "release $rel_tag not found"

if command -v jq >/dev/null 2>&1; then
  urls="$(jq -r '.assets[].browser_download_url' <<<"$rel_json")"
else
  urls="$(grep -o '"browser_download_url": "[^"]*"' <<<"$rel_json" | sed 's/"browser_download_url": "//;s/"$//')"
fi
[[ -n "$urls" ]] || die "release $rel_tag has no assets"

# Prefer the main binary archive over installer bundles, Linux packages, and SBOMs.
pick_archive() {
  local pattern="$1"
  printf '%s\n' "$urls" \
    | grep -E "$pattern" \
    | grep -vE '\.(spdx|sbom)\.json$' \
    | grep -v -- '-installer' \
    | grep -vE '\.(deb|rpm|apk)$' \
    | head -n1 || true
}

asset_url="$(pick_archive "[-_]${os_re}[-_]${arch_re}\.(tar\.gz|tgz|zip)$")"
if [[ -z "$asset_url" ]]; then
  asset_url="$(printf '%s\n' "$urls" \
    | grep -E "[-_]${os_re}[-_]${arch_re}\.(tar\.gz|tgz|zip)$" \
    | grep -vE '\.(spdx|sbom)\.json$' \
    | head -n1 || true)"
fi
# Scaena packages anchor on the exact "<prefix><goos>_<goarch>" asset name so
# "scaena_" can never match "scaena-api_" or "scaena-production-worker_"
# archives living in the same Release.
if package_prefix="$(scaena_package_prefix "$package")"; then
  asset_url=""
  for exact_name in \
    "${package_prefix}${os_token}_${arch_token}.tar.gz" \
    "${package_prefix}${os_token}_${arch_token}.zip"; do
    # Anchor on the full basename with -E: grep -F would treat "$" as a
    # literal character and never match, and an unanchored match could pick
    # up "<archive>.sbom.json" sidecar assets from the same Release.
    if asset_url="$(printf '%s\n' "$urls" | grep -E "/${exact_name//./\\.}$" | head -n1)"; then
      [[ -n "$asset_url" ]] && break
    fi
  done
fi
[[ -n "$asset_url" ]] || die "no $os/$arch archive in $rel_tag"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/$(basename "$asset_url")" "$asset_url" \
  || die "download failed: $asset_url"

ck_url="$(printf '%s\n' "$urls" | grep -E 'checksums[^/]*\.txt$' | head -n1 || true)"
if [[ -n "$ck_url" ]]; then
  curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/$(basename "$ck_url")" "$ck_url" || true
  ckfile="$TMP/$(basename "$ck_url")"
  if [[ -f "$ckfile" ]]; then
    want="$(grep -F "$(basename "$asset_url")" "$ckfile" | head -n1 | awk '{print $1}')"
    if [[ -n "$want" ]]; then
      got=""
      if command -v sha256sum >/dev/null 2>&1; then
        got="$(sha256sum "$TMP/$(basename "$asset_url")" | awk '{print $1}')"
      elif command -v shasum >/dev/null 2>&1; then
        got="$(shasum -a 256 "$TMP/$(basename "$asset_url")" | awk '{print $1}')"
      else
        echo "install: warning: no sha256 tool found, skipping verification" >&2
      fi
      [[ -z "$got" || "$got" == "$want" ]] || die "checksum mismatch for $(basename "$asset_url")"
      [[ -n "$got" ]] && echo "install: checksum ok ($(basename "$asset_url"))"
    fi
  fi
else
  echo "install: warning: release ships no checksums file, skipping verification" >&2
fi

mkdir -p "$TMP/extract"
case "$asset_url" in
  *.zip) unzip -q "$TMP/$(basename "$asset_url")" -d "$TMP/extract" || die "unzip failed" ;;
  *) tar -xzf "$TMP/$(basename "$asset_url")" -C "$TMP/extract" || die "extract failed" ;;
esac

bin="$(find "$TMP/extract" -type f -name "$package" | head -n1 || true)"
if [[ -z "$bin" ]]; then
  bin="$(find "$TMP/extract" -type f -name "${package}.exe" | head -n1 || true)"
fi
if [[ -z "$bin" ]]; then
  bin="$(find "$TMP/extract" -type f -executable | grep -vE '\.(txt|md|json|yml|yaml)$' | head -n1 || true)"
fi
if [[ -z "$bin" ]]; then
  bin="$(find "$TMP/extract" -type f -exec du -k {} + 2>/dev/null | sort -rn | head -n1 | cut -f2-)"
fi
[[ -n "$bin" && -f "$bin" ]] || die "no binary found inside the archive"

mkdir -p "$DEST"
install -m 0755 "$bin" "$DEST/$package" || die "install to $DEST failed"
echo "install: $package $rel_tag -> $DEST/$package"
if [[ ":$PATH:" != *":$DEST:"* ]]; then
  echo "install: add $DEST to PATH, for example:"
  echo "  export PATH=\"$DEST:\$PATH\""
fi
"$DEST/$package" --version 2>/dev/null || echo "install: done (run '$DEST/$package --version' yourself)"
if [[ "$product" == "eikona" ]]; then
  echo "install: next (preview): $DEST/eikona setup"
  echo "install: next (apply):   $DEST/eikona setup --yes"
fi
