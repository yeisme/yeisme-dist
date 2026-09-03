#!/usr/bin/env bash
# Generate public Homebrew casks from the mirrored yeisme-dist catalog.
# Eikona also keeps its public Scoop manifest. This script never reads private
# product repositories and never downloads release assets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT/catalog.json"
OUTPUT_ROOT="$ROOT"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --catalog) CATALOG="$2"; shift 2 ;;
    --output-root) OUTPUT_ROOT="$2"; shift 2 ;;
    *) printf 'unknown flag: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
[[ -f "$CATALOG" ]] || { echo "catalog not found: $CATALOG" >&2; exit 2; }

products=(
  eikona pinax auctra scaena gitea-mcp sonora anatomia
  mcp-gateway credentialctl inferrum quaestor
)

description_for() {
  case "$1" in
    eikona) echo 'Agent-first visual asset runtime and image-generation CLI' ;;
    pinax) echo 'Agent-safe local-first knowledge control plane' ;;
    auctra) echo 'Local-first unified text creation agent CLI' ;;
    scaena) echo 'Short-drama production CLI and backend' ;;
    gitea-mcp) echo 'Model Context Protocol server for Gitea' ;;
    sonora) echo 'Local-first voice, subtitle, and audio workflow CLI' ;;
    anatomia) echo 'Video evidence analysis CLI and local MCP client' ;;
    mcp-gateway) echo 'Local MCP gateway, registry, and policy CLI' ;;
    credentialctl) echo 'Local shared credential and project-secret CLI' ;;
    inferrum) echo 'Local vector and retrieval-augmented generation CLI' ;;
    quaestor) echo 'Deep-research and quantitative validation CLI' ;;
    *) return 1 ;;
  esac
}

binaries_for() {
  case "$1" in
    anatomia) printf '%s\n' anatomia anatomia-video-mcp ;;
    *) printf '%s\n' "$1" ;;
  esac
}

release_for() {
  local product="$1" tag
  tag="$(jq -r --arg product "$product" '
    .products[]? | select(.name == $product) | .latest // empty
  ' "$CATALOG")"
  [[ -n "$tag" ]] || return 1
  jq -ce --arg product "$product" --arg tag "$tag" '
    .products[] | select(.name == $product) | .releases[] | select(.tag == $tag)
  ' "$CATALOG"
}

asset_for() {
  local release_json="$1" product="$2" os_name="$3" arch="$4"
  jq -r --arg product "${product,,}_" --arg os_name "${os_name,,}" --arg arch "$arch" '
    [(.assets // [])[]
      | select((ascii_downcase | startswith($product)))
      | select((ascii_downcase | endswith(".tar.gz")))
      | select((ascii_downcase | contains($os_name)))
      | select(
          if $arch == "arm64" then
            ((ascii_downcase | contains("arm64")) or (ascii_downcase | contains("aarch64")))
          else
            ((ascii_downcase | contains("amd64")) or (ascii_downcase | contains("x86_64")))
          end
        )]
    | first // empty
  ' <<<"$release_json"
}

digest_for() {
  local release_json="$1" asset="$2" digest
  digest="$(jq -er --arg asset "$asset" '
    .asset_digests[$asset] | select(type == "string")
  ' <<<"$release_json")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "missing SHA-256 digest for $asset" >&2
    return 1
  }
  printf '%s\n' "${digest#sha256:}"
}

emit_arch() {
  local release_json="$1" tag="$2" product="$3" os_name="$4" arch="$5"
  local asset sha stanza
  asset="$(asset_for "$release_json" "$product" "$os_name" "$arch")"
  [[ -n "$asset" ]] || return 1
  if ! sha="$(digest_for "$release_json" "$asset")"; then
    # Status 2 distinguishes an available platform with missing or malformed
    # integrity metadata from a platform that the release does not provide.
    return 2
  fi
  [[ "$arch" == arm64 ]] && stanza=on_arm || stanza=on_intel
  printf '    %s do\n' "$stanza"
  printf '      sha256 "%s"\n' "$sha"
  printf '      url "https://github.com/yeisme/yeisme-dist/releases/download/%s/%s",\n' "$tag" "$asset"
  printf '          verified: "github.com/yeisme/yeisme-dist/"\n'
  printf '    end\n'
}

emit_os() {
  local release_json="$1" tag="$2" product="$3" os_name="$4" block="$5"
  local arm intel arm_status intel_status
  if arm="$(emit_arch "$release_json" "$tag" "$product" "$os_name" arm64)"; then
    arm_status=0
  else
    arm_status=$?
    arm=""
  fi
  if intel="$(emit_arch "$release_json" "$tag" "$product" "$os_name" amd64)"; then
    intel_status=0
  else
    intel_status=$?
    intel=""
  fi
  (( arm_status < 2 && intel_status < 2 )) || return 2
  [[ -n "$arm" || -n "$intel" ]] || return 1
  printf '  %s do\n' "$block"
  [[ -n "$arm" ]] && printf '%s\n' "$arm"
  [[ -n "$intel" ]] && printf '%s\n' "$intel"
  printf '  end\n'
}

render_cask() {
  local product="$1" release_json="$2" tag version description tmp macos linux
  tag="$(jq -er '.tag' <<<"$release_json")"
  version="$(jq -er '.version | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' <<<"$release_json")"
  version="${version#v}"
  [[ "$tag" == "$product/v$version" ]] || {
    echo "$product release tag/version mismatch: $tag" >&2
    return 1
  }
  description="$(description_for "$product")"
  local macos_status linux_status
  if macos="$(emit_os "$release_json" "$tag" "$product" darwin on_macos)"; then
    macos_status=0
  else
    macos_status=$?
    macos=""
  fi
  if linux="$(emit_os "$release_json" "$tag" "$product" linux on_linux)"; then
    linux_status=0
  else
    linux_status=$?
    linux=""
  fi
  (( macos_status < 2 && linux_status < 2 )) || {
    echo "$product release $tag has an archive without a valid SHA-256 digest" >&2
    return 1
  }
  [[ -n "$macos" || -n "$linux" ]] || {
    echo "$product release $tag has no Homebrew-compatible archive" >&2
    return 1
  }

  tmp="$(mktemp)"
  {
    echo '# This file is generated by scripts/generate-package-manifests.sh. DO NOT EDIT.'
    printf 'cask "%s" do\n' "$product"
    printf '  version "%s"\n\n' "$version"
    [[ -n "$macos" ]] && printf '%s\n' "$macos"
    [[ -n "$linux" ]] && printf '%s\n' "$linux"
    echo
    printf '  name "%s"\n' "$product"
    printf '  desc "%s"\n' "$description"
    echo '  homepage "https://github.com/yeisme/yeisme-dist"'
    echo
    echo '  livecheck do'
    echo '    skip "Generated from the verified yeisme-dist catalog."'
    echo '  end'
    echo
    while IFS= read -r binary; do
      printf '  binary "%s"\n' "$binary"
    done < <(binaries_for "$product")
    if [[ "$product" == eikona ]]; then
      cat <<'EOF'

  caveats <<~EOS
    Preview local configuration and exact-version Agent Skills setup:
      eikona setup
    Apply the reviewed local setup:
      eikona setup --yes
  EOS
EOF
    fi
    echo
    echo '  # No zap stanza required'
    echo 'end'
  } > "$tmp"
  mv "$tmp" "$OUTPUT_ROOT/Casks/$product.rb"
  echo "generated $OUTPUT_ROOT/Casks/$product.rb"
}

render_eikona_bucket() {
  local release_json="$1" tag version windows_amd64 windows_arm64 amd64_sha arm64_sha tmp
  tag="$(jq -er '.tag' <<<"$release_json")"
  version="${tag#eikona/v}"
  windows_amd64="eikona_${version}_Windows_x86_64.zip"
  windows_arm64="eikona_${version}_Windows_arm64.zip"
  amd64_sha="$(digest_for "$release_json" "$windows_amd64")"
  arm64_sha="$(digest_for "$release_json" "$windows_arm64")"
  tmp="$(mktemp)"
  jq -n \
    --arg version "$version" \
    --arg base "https://github.com/yeisme/yeisme-dist/releases/download/$tag" \
    --arg amd64_asset "$windows_amd64" \
    --arg amd64_sha "$amd64_sha" \
    --arg arm64_asset "$windows_arm64" \
    --arg arm64_sha "$arm64_sha" '
    {
      version: $version,
      description: "Agent-first visual asset runtime and image-generation CLI.",
      homepage: "https://github.com/yeisme/yeisme-dist",
      license: "MIT",
      architecture: {
        "64bit": {url: ($base + "/" + $amd64_asset), hash: $amd64_sha},
        arm64: {url: ($base + "/" + $arm64_asset), hash: $arm64_sha}
      },
      bin: "eikona.exe",
      notes: [
        "Preview local configuration and exact-version Agent Skills setup: eikona setup",
        "Apply the reviewed local setup: eikona setup --yes"
      ]
    }
  ' > "$tmp"
  mv "$tmp" "$OUTPUT_ROOT/bucket/eikona.json"
  echo "generated $OUTPUT_ROOT/bucket/eikona.json"
}

validate_eikona_release() {
  local release_json="$1" version required
  version="$(jq -er '.version | ltrimstr("v")' <<<"$release_json")"
  local required_assets=(
    checksums.txt
    eikona-install-manifest.json
    "eikona-command-catalog_${version}.json"
    "eikona-skills_${version}.json"
    "eikona-skills_${version}.tar.gz"
    "eikona_${version}_Darwin_arm64.tar.gz"
    "eikona_${version}_Darwin_x86_64.tar.gz"
    "eikona_${version}_Linux_arm64.tar.gz"
    "eikona_${version}_Linux_x86_64.tar.gz"
    "eikona_${version}_Windows_arm64.zip"
    "eikona_${version}_Windows_x86_64.zip"
  )
  for required in "${required_assets[@]}"; do
    jq -e --arg required "$required" '(.assets // []) | index($required) != null' \
      <<<"$release_json" >/dev/null || {
        echo "eikona release is missing required asset $required" >&2
        return 1
      }
    case "$required" in
      *.tar.gz|*.zip) digest_for "$release_json" "$required" >/dev/null || return 1 ;;
    esac
  done
}

mkdir -p "$OUTPUT_ROOT/Casks" "$OUTPUT_ROOT/bucket"
for product in "${products[@]}"; do
  if release_json="$(release_for "$product")"; then
    [[ "$product" != eikona ]] || validate_eikona_release "$release_json"
    render_cask "$product" "$release_json"
    [[ "$product" == eikona ]] && render_eikona_bucket "$release_json"
  fi
done
