#!/usr/bin/env bash
# Anonymous installer for Yeisme products mirrored in the public
# yeisme/yeisme-dist repository.
#
#   curl -fsSL https://raw.githubusercontent.com/yeisme/yeisme-dist/main/install.sh | bash -s <product> [version] [--to DIR]
#
# Resolves the newest <product>/vX.Y.Z release, picks the archive for the
# detected OS/arch, verifies it against the release checksums, extracts the
# binary, and installs it to ~/.yeisme/bin (override with --to).
set -euo pipefail

DIST_REPO="${DIST_REPO:-yeisme/yeisme-dist}"
DEST="${HOME}/.yeisme/bin"
product=""
version=""

usage() {
  cat <<'EOF'
usage: install.sh <product> [version] [--to DIR]

  product   one of: eikona, pinax, auctra, scaena, gitea-mcp
  version   vX.Y.Z (default: newest release); plain X.Y.Z also accepted
  --to      install directory (default: ~/.yeisme/bin)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) DEST="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$product" ]]; then product="$1"
      elif [[ -z "$version" ]]; then version="$1"
      else usage >&2; exit 2; fi
      shift ;;
  esac
done
[[ -n "$product" ]] || { usage >&2; exit 2; }
if [[ -n "$version" ]]; then
  case "$version" in
    "$product"/*) ;;
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

auth=()
[[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")

# Newest release for the product (releases are listed newest-first).
rel_tag="$version"
if [[ -z "$rel_tag" ]]; then
  rel_tag="$(curl -fsSL "${auth[@]}" \
    "https://api.github.com/repos/$DIST_REPO/releases?per_page=100" \
    | grep -o "\"tag_name\": \"${product}/[^\"]*\"" | head -n1 \
    | sed 's/.*: "//;s/"$//')" || rel_tag=""
  [[ -n "$rel_tag" ]] || die "no release found for '$product' in $DIST_REPO"
fi

rel_json="$(curl -fsSL "${auth[@]}" "https://api.github.com/repos/$DIST_REPO/releases/tags/$rel_tag")" \
  || die "release $rel_tag not found"
urls="$(grep -o '"browser_download_url": "[^"]*"' <<<"$rel_json" | sed 's/"browser_download_url": "//;s/"$//')"
[[ -n "$urls" ]] || die "release $rel_tag has no assets"

# Pick the archive for this platform; prefer the main binary over *-installer.
asset_url="$(printf '%s\n' "$urls" \
  | grep -E "[-_]${os_re}[-_]${arch_re}\.(tar\.gz|tgz|zip)$" | grep -v -- '-installer' | head -n1 || true)"
if [[ -z "$asset_url" ]]; then
  asset_url="$(printf '%s\n' "$urls" \
    | grep -E "[-_]${os_re}[-_]${arch_re}\.(tar\.gz|tgz|zip)$" | head -n1 || true)"
fi
[[ -n "$asset_url" ]] || die "no $os/$arch archive in $rel_tag"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$(basename "$asset_url")" "$asset_url" || die "download failed: $asset_url"

# Verify against the release checksums when shipped.
ck_url="$(printf '%s\n' "$urls" | grep -E 'checksums[^/]*\.txt$' | head -n1 || true)"
if [[ -n "$ck_url" ]]; then
  curl -fsSL -o "$TMP/$(basename "$ck_url")" "$ck_url" || true
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

bin="$(find "$TMP/extract" -type f -name "$product" | head -n1 || true)"
if [[ -z "$bin" ]]; then
  bin="$(find "$TMP/extract" -type f -exec du -k {} + 2>/dev/null | sort -rn | head -n1 | cut -f2-)"
fi
[[ -n "$bin" && -f "$bin" ]] || die "no binary found inside the archive"

mkdir -p "$DEST"
install -m 0755 "$bin" "$DEST/$product" || die "install to $DEST failed"
echo "install: $product $rel_tag -> $DEST/$product"
"$DEST/$product" --version 2>/dev/null || echo "install: done (run '$DEST/$product --version' yourself)"
