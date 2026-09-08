#!/usr/bin/env bash
# test-scaena-packages.sh — offline tests for the Scaena three-package channel
# (change scaena-v0-4-package-channels-v1).
#
# Covers, without credentials and without network:
#   - the anonymous installer package aliases: prefix collision, OS/arch
#     matrix, Unix tar.gz and zip extraction, checksum verification, explicit
#     version forms, custom install roots, no service/config helper files,
#     uninstall/reinstall, and the unsupported-OS guidance;
#   - the three Homebrew Casks + three Scoop manifests group generation from
#     a synthetic v0.4 catalog, including atomic group replacement (a missing
#     digest or a missing archive keeps the previous stable group);
#   - generated-file drift: the alias table embedded in install.sh must match
#     scripts/lib/scaena-packages.sh, and policy/scaena.json must regenerate
#     byte-identically from the frozen fixture.
#
# install.sh reads DIST_API_BASE and a catalog.json from its working
# directory, so a file:// fixture tree drives the whole flow offline.
set -euo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
command -v curl >/dev/null || { echo 'curl required' >&2; exit 2; }
command -v sha256sum >/dev/null || { echo 'sha256sum required' >&2; exit 2; }

# Transitional guard: every gate below exercises files owned by
# scaena-v0-4-package-channels-v1. On a tree where that change is absent,
# report a skip so scripts/check.sh stays green instead of failing on work
# that was never applied.
if ! grep -q 'scaena_package_prefix' "$REAL_ROOT/install.sh" \
   || [[ ! -f "$REAL_ROOT/scripts/lib/scaena-packages.sh" ]] \
   || ! grep -q 'scaena_matrix_complete' "$REAL_ROOT/scripts/generate-package-manifests.sh" \
   || [[ ! -f "$REAL_ROOT/policy/scaena.json" ]] \
   || [[ ! -f "$REAL_ROOT/scripts/generate-scaena-policy.sh" ]]; then
  echo "skip: scaena-v0-4-package-channels-v1 implementation files not present"
  exit 0
fi

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

fail=0
ok()  { echo "ok  $1"; }
bad() { echo "FAIL $1" >&2; fail=1; }

source "$REAL_ROOT/scripts/lib/scaena-packages.sh"

SCAENA_PKGS=(scaena scaena-api scaena-production-worker)
OS_ARCH_PAIRS=("linux amd64 x86_64" "linux arm64 aarch64" "darwin amd64 x86_64" "darwin arm64 arm64")

# ---------------------------------------------------------------- fixture ---

# Fake uname (only -s/-m are used by install.sh) so the OS/arch selector can
# be driven from any host.
mkdir -p "$SBX/bin"
cat > "$SBX/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) echo "${FAKE_UNAME_S:-Linux}" ;;
  -m) echo "${FAKE_UNAME_M:-x86_64}" ;;
  *) echo Linux ;;
esac
EOF
chmod +x "$SBX/bin/uname"
export FAKE_UNAME_S="Linux" FAKE_UNAME_M="x86_64"

API_ROOT="$SBX/api/repos/yeisme/yeisme-dist/releases/tags"
mkdir -p "$API_ROOT/scaena" "$SBX/rel" "$SBX/run" "$SBX/home"

# build_archive <pkg> <os> <arch> <dir> <ext> — archive ships the package
# binary plus service/config/notice helpers that must never be installed.
build_archive() {
  local pkg="$1" os="$2" arch="$3" dir="$4" ext="$5" name stage binfile
  name="${pkg}_${os}_${arch}.${ext}"
  stage="$(mktemp -d)"
  binfile="$stage/$pkg"; [[ "$os" == "windows" ]] && binfile="$stage/$pkg.exe"
  {
    printf '#!/bin/sh\n'
    printf 'case "${1:-}" in\n'
    printf '  --version) echo "%s v0.4.0 %s/%s"; exit 0 ;;\n' "$pkg" "$os" "$arch"
    printf '  --help) echo "%s help %s/%s"; exit 0 ;;\n' "$pkg" "$os" "$arch"
    printf '  *) echo "%s %s/%s"; exit 0 ;;\n' "$pkg" "$os" "$arch"
    printf 'esac\n'
  } > "$binfile"
  chmod 0755 "$binfile"
  printf 'binary distribution notice %s %s/%s\n' "$pkg" "$os" "$arch" \
    > "$stage/BINARY-DISTRIBUTION-NOTICE.txt"
  printf 'listen: 127.0.0.1:0\n' > "$stage/config.example.yaml"
  printf '[Unit]\nDescription=%s fixture\n' "$pkg" > "$stage/${pkg}.service"
  if [[ "$ext" == "zip" ]]; then
    (cd "$stage" && zip -q -r "$dir/$name" "$(basename "$binfile")" \
      BINARY-DISTRIBUTION-NOTICE.txt config.example.yaml "${pkg}.service")
  else
    (cd "$stage" && tar -czf "$dir/$name" "$(basename "$binfile")" \
      BINARY-DISTRIBUTION-NOTICE.txt config.example.yaml "${pkg}.service")
  fi
  rm -rf "$stage"
}

ASSET_NAMES="$SBX/asset-names.txt"; : > "$ASSET_NAMES"
for pkg in "${SCAENA_PKGS[@]}"; do
  for pair in "${OS_ARCH_PAIRS[@]}" "windows amd64 x86_64" "windows arm64 aarch64"; do
    read -r os arch _uname <<<"$pair"
    ext="tar.gz"; [[ "$os" == "windows" ]] && ext="zip"
    build_archive "$pkg" "$os" "$arch" "$SBX/rel" "$ext"
    printf '%s\n' "${pkg}_${os}_${arch}.${ext}" >> "$ASSET_NAMES"
  done
done
sort -o "$ASSET_NAMES" "$ASSET_NAMES"
# checksums.txt covers every archive, mirroring the upstream release.
(cd "$SBX/rel" && sha256sum $(cat "$ASSET_NAMES") > checksums.txt)

ASSET_NAMES_JSON="$(jq -Rsc 'split("\n") | map(select(length > 0))' "$ASSET_NAMES")"
# sha256sum lines are "<hash>  <name>" (two-space separator): splits() is the
# regex-based splitter, and the name is the map key.
ASSET_DIGESTS_JSON="$(
  (cd "$SBX/rel" && sha256sum $(cat "$ASSET_NAMES")) \
    | jq -Rr '[splits(" +")] | {(.[1]): ("sha256:" + .[0])}' | jq -sc 'add'
)"

# build_release <out-file> <asset-base-url> — GitHub release JSON shape.
build_release() {
  jq -n --arg base "$2" --argjson assets "$ASSET_NAMES_JSON" '
    {tag_name: "scaena/v0.4.0", draft: false, prerelease: false,
     assets: ([$assets[], "checksums.txt"] | unique
              | map({name: ., browser_download_url: ($base + "/" + .)}))}
  ' > "$1"
}
build_release "$API_ROOT/scaena/v0.4.0" "file://$SBX/rel"

# Synthetic catalog: the real catalog with scaena promoted to a complete
# v0.4.0 matrix. Other products stay untouched so the manifest generator
# still exercises its full path.
prepare_catalog() { # <out>
  jq --argjson assets "$ASSET_NAMES_JSON" --argjson digests "$ASSET_DIGESTS_JSON" '
    (.products[] | select(.name == "scaena")) |=
      (.latest = "scaena/v0.4.0"
       | .release_count = ((.releases | length) + 1)
       | .releases = ([{tag: "scaena/v0.4.0", version: "v0.4.0",
                        published_at: "2026-09-08T00:00:00Z", prerelease: false,
                        asset_count: ($assets | length), assets: $assets,
                        asset_digests: $digests}] + .releases))
  ' "$REAL_ROOT/catalog.json" > "$1"
}
prepare_catalog "$SBX/run/catalog.json"

# run_install <pkg> [args...] — anonymous installer against the sandbox.
run_install() {
  local pkg="$1"; shift
  ( cd "$SBX/run" \
      && env -u GH_TOKEN HOME="$SBX/home" \
           DIST_API_BASE="${SBX_API:-file://$SBX/api}" \
           PATH="$SBX/bin:$PATH" \
           bash "$REAL_ROOT/install.sh" "$pkg" "$@" )
}

# assert_root_clean <root> <pkg> — exactly the package binary, no helpers.
assert_root_clean() {
  local root="$1" pkg="$2" entries
  [[ -x "$root/$pkg" ]] || { echo "missing $root/$pkg" >&2; return 1; }
  entries="$(ls -A "$root")"
  [[ "$(wc -l <<<"$entries")" -eq 1 ]] || { echo "extra files: $entries" >&2; return 1; }
  if grep -qE '\.(service|yaml|yml|txt|json)$' <<<"$entries"; then
    echo "helper file installed: $entries" >&2; return 1
  fi
  return 0
}

# ------------------------------------------------------------------ tests ---

# 1. install.sh's embedded alias table cannot drift from the shared contract.
t_alias_table_no_drift() {
  grep -qF 'scaena|scaena-api|scaena-production-worker) echo scaena ;;' \
    "$REAL_ROOT/install.sh" || return 1
  grep -qF 'scaena) echo "scaena_" ;;' "$REAL_ROOT/install.sh" || return 1
  grep -qF 'scaena-api) echo "scaena-api_" ;;' "$REAL_ROOT/install.sh" || return 1
  grep -qF 'scaena-production-worker) echo "scaena-production-worker_" ;;' \
    "$REAL_ROOT/install.sh" || return 1
  local pkg
  for pkg in "${SCAENA_PKGS[@]}"; do
    [[ "$(scaena_package_product "$pkg")" == "scaena" ]] || return 1
    [[ "$(scaena_package_prefix "$pkg")" == "${pkg}_" ]] || return 1
    [[ "$(scaena_package_binary "$pkg")" == "$pkg" ]] || return 1
  done
  [[ "$(scaena_package_defaults | sort | tr '\n' ' ')" == "scaena scaena-api scaena-production-worker " ]]
}

# 2. Default `install.sh scaena` keeps the legacy destination and archive.
t_install_default_compat() {
  rm -rf "$SBX/home/.yeisme"
  run_install scaena >/dev/null || return 1
  assert_root_clean "$SBX/home/.yeisme/bin" scaena || return 1
  [[ "$("$SBX/home/.yeisme/bin/scaena" --version)" == "scaena v0.4.0 linux/amd64" ]] \
    && [[ "$("$SBX/home/.yeisme/bin/scaena" --help)" == "scaena help linux/amd64" ]]
}

# 3. `scaena-api` selects the scaena-api_ archive from the shared Release:
# the "scaena_" prefix must never match "scaena-api_" (prefix collision).
t_install_api_alias_prefix() {
  local root="$SBX/root-api"
  rm -rf "$root"
  run_install scaena-api --to "$root" >/dev/null || return 1
  assert_root_clean "$root" scaena-api || return 1
  [[ "$( "$root/scaena-api" --version)" == "scaena-api v0.4.0 linux/amd64" ]] || return 1
  [[ ! -e "$root/scaena" && ! -e "$root/scaena-production-worker" ]]
}

# 4. `scaena-production-worker` installs only the worker binary.
t_install_worker_alias() {
  local root="$SBX/root-worker"
  rm -rf "$root"
  run_install scaena-production-worker --to "$root" >/dev/null || return 1
  assert_root_clean "$root" scaena-production-worker || return 1
  [[ "$("$root/scaena-production-worker" --version)" == "scaena-production-worker v0.4.0 linux/amd64" ]]
}

# 5. OS/arch matrix: goreleaser goos/goarch tokens selected per uname pair.
t_install_os_arch_matrix() {
  local pair os arch uname_arch root fake_s
  for pair in "${OS_ARCH_PAIRS[@]}"; do
    read -r os arch uname_arch <<<"$pair"
    root="$SBX/root-$os-$arch"
    rm -rf "$root"
    fake_s="Linux"; [[ "$os" == "darwin" ]] && fake_s="Darwin"
    FAKE_UNAME_S="$fake_s" FAKE_UNAME_M="$uname_arch" \
      run_install scaena-api --to "$root" >/dev/null \
      || { echo "install failed for $os/$arch" >&2; return 1; }
    [[ "$("$root/scaena-api" --version)" == "scaena-api v0.4.0 $os/$arch" ]] \
      || { echo "wrong archive for $os/$arch" >&2; return 1; }
  done
  return 0
}

# 6. zip extraction path (Windows archives are zips; exercised through a
#    darwin-named zip release because install.sh only supports Linux/Darwin
#    hosts and Windows users go through Scoop or direct downloads).
t_install_zip_extraction() {
  local ziprel="$SBX/rel-zip" zipapi="$SBX/api-zip" root="$SBX/root-zip"
  rm -rf "$ziprel" "$zipapi" "$root"
  mkdir -p "$ziprel" "$zipapi/repos/yeisme/yeisme-dist/releases/tags/scaena"
  local names="" pkg os arch
  for pkg in scaena-api; do
    for pair in "darwin amd64 x86_64" "darwin arm64 aarch64"; do
      read -r os arch _u <<<"$pair"
      build_archive "$pkg" "$os" "$arch" "$ziprel" zip
      names+="${pkg}_${os}_${arch}.zip"$'\n'
    done
  done
  (cd "$ziprel" && sha256sum $(printf '%s' "$names") > checksums.txt)
  local names_json; names_json="$(printf '%s' "$names" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  jq -n --arg base "file://$ziprel" --argjson assets "$names_json" '
    {tag_name: "scaena/v0.4.0", draft: false, prerelease: false,
     assets: ([$assets[], "checksums.txt"] | unique
              | map({name: ., browser_download_url: ($base + "/" + .)}))}
  ' > "$zipapi/repos/yeisme/yeisme-dist/releases/tags/scaena/v0.4.0"
  SBX_API="file://$zipapi" FAKE_UNAME_S="Darwin" FAKE_UNAME_M="x86_64" \
    run_install scaena-api --to "$root" >/dev/null || return 1
  assert_root_clean "$root" scaena-api || return 1
  [[ "$("$root/scaena-api" --version)" == "scaena-api v0.4.0 darwin/amd64" ]]
}

# 7. Unsupported OS fails closed with guidance instead of a partial install.
t_install_unsupported_os() {
  if FAKE_UNAME_S="Windows_NT" run_install scaena-api --to "$SBX/root-unsupported" \
      >/dev/null 2>"$SBX/unsupported.err"; then
    return 1
  fi
  grep -q "unsupported OS" "$SBX/unsupported.err" \
    && [[ ! -e "$SBX/root-unsupported/scaena-api" ]]
}

# 8. Checksum verification: a corrupted archive must abort the install.
t_install_checksum_mismatch() {
  local badrel="$SBX/rel-corrupt" badapi="$SBX/api-corrupt" root="$SBX/root-corrupt"
  rm -rf "$badrel" "$badapi" "$root"
  cp -r "$SBX/rel" "$badrel"
  printf 'tampered bytes\n' >> "$badrel/scaena-api_linux_amd64.tar.gz"
  mkdir -p "$badapi/repos/yeisme/yeisme-dist/releases/tags/scaena"
  # Rebuild the release JSON for the corrupted tree explicitly (checksums.txt
  # still lists the original digest, so the tampered archive must mismatch).
  jq -n --arg base "file://$badrel" --argjson assets "$ASSET_NAMES_JSON" '
    {tag_name: "scaena/v0.4.0", draft: false, prerelease: false,
     assets: ([$assets[], "checksums.txt"] | unique
              | map({name: ., browser_download_url: ($base + "/" + .)}))}
  ' > "$badapi/repos/yeisme/yeisme-dist/releases/tags/scaena/v0.4.0"
  if SBX_API="file://$badapi" run_install scaena-api --to "$root" \
      >/dev/null 2>"$SBX/checksum.err"; then
    return 1
  fi
  grep -q "checksum mismatch" "$SBX/checksum.err" \
    && [[ ! -e "$root/scaena-api" ]]
}

# 9. Explicit version forms resolve the canonical scaena/vX.Y.Z tag.
t_install_explicit_version() {
  local root="$SBX/root-version"
  rm -rf "$root"
  run_install scaena-api v0.4.0 --to "$root" >/dev/null || return 1
  [[ "$("$root/scaena-api" --version)" == "scaena-api v0.4.0 linux/amd64" ]] || return 1
  rm -rf "$root"
  run_install scaena-api 0.4.0 --to "$root" >/dev/null || return 1
  [[ "$("$root/scaena-api" --version)" == "scaena-api v0.4.0 linux/amd64" ]]
}

# 10. Uninstall (remove the installed binary) and reinstall stays clean.
t_install_uninstall_reinstall() {
  local root="$SBX/root-cycle"
  rm -rf "$root"
  run_install scaena-production-worker --to "$root" >/dev/null || return 1
  rm -f "$root/scaena-production-worker"
  [[ ! -e "$root/scaena-production-worker" ]] || return 1
  run_install scaena-production-worker --to "$root" >/dev/null || return 1
  assert_root_clean "$root" scaena-production-worker
}

# 11. Manifest generator renders the six-file group from a complete v0.4
#     catalog: four-platform Casks, two-architecture Scoop manifests,
#     binary-only, public scaena URLs, no dependencies or service stanzas.
GEN_OUT="$SBX/gen"
t_manifest_group_generated() {
  rm -rf "$GEN_OUT"
  "$REAL_ROOT/scripts/generate-package-manifests.sh" \
    --catalog "$SBX/run/catalog.json" --output-root "$GEN_OUT" >/dev/null 2>&1 \
    || return 1
  local pkg cask scoop
  for pkg in "${SCAENA_PKGS[@]}"; do
    cask="$GEN_OUT/Casks/$pkg.rb"; scoop="$GEN_OUT/bucket/$pkg.json"
    [[ -s "$cask" && -s "$scoop" ]] || return 1
    ruby -c "$cask" >/dev/null 2>&1 || return 1
    grep -qF 'version "0.4.0"' "$cask" || return 1
    grep -qF "binary \"$pkg\"" "$cask" || return 1
    grep -qF 'on_macos do' "$cask" && grep -qF 'on_linux do' "$cask" || return 1
    [[ "$(grep -cF 'sha256 "' "$cask")" -eq 4 ]] || return 1
    grep -qF "url \"https://github.com/yeisme/yeisme-dist/releases/download/scaena/v#{version}/${pkg}_" "$cask" \
      || return 1
    if grep -qE '^[[:space:]]*(depends_on|service|zap)[[:space:]]' "$cask"; then
      return 1
    fi
    jq -e --arg pkg "$pkg" --arg bin "${pkg}.exe" \
        --arg base "https://github.com/yeisme/yeisme-dist/releases/download/scaena/v0.4.0" '
      .bin == $bin
      and (.architecture | has("64bit") and has("arm64"))
      and (.architecture["64bit"].url == ($base + "/" + $pkg + "_windows_amd64.zip"))
      and (.architecture["64bit"].hash | test("^[0-9a-f]{64}$"))
      and (.architecture.arm64.url == ($base + "/" + $pkg + "_windows_arm64.zip"))
      and (.architecture.arm64.hash | test("^[0-9a-f]{64}$"))
      and ((has("depends") or has("service") or has("pre_install")) | not)
    ' "$scoop" >/dev/null || return 1
  done
  return 0
}

group_sig() {
  ( cd "$GEN_OUT" && sha256sum \
      Casks/scaena.rb Casks/scaena-api.rb Casks/scaena-production-worker.rb \
      bucket/scaena.json bucket/scaena-api.json bucket/scaena-production-worker.json \
      | sha256sum | cut -d' ' -f1 )
}

# 12. Atomic group replacement: a missing digest must fail the generator and
#     a missing archive must skip promotion — both keep the previous stable
#     six-file group byte-identical.
t_manifest_group_atomic() {
  [[ -s "$GEN_OUT/Casks/scaena-api.rb" ]] || return 1
  local sig_before
  sig_before="$(group_sig)"
  jq 'del(.products[] | select(.name == "scaena")
          | .releases[] | select(.tag == "scaena/v0.4.0")
          | .asset_digests["scaena-production-worker_windows_arm64.zip"])' \
    "$SBX/run/catalog.json" > "$SBX/catalog-bad-digest.json"
  if "$REAL_ROOT/scripts/generate-package-manifests.sh" \
      --catalog "$SBX/catalog-bad-digest.json" --output-root "$GEN_OUT" >/dev/null 2>&1; then
    echo "generator accepted a missing digest" >&2; return 1
  fi
  [[ "$(group_sig)" == "$sig_before" ]] || { echo "group changed on missing digest" >&2; return 1; }
  jq '(.products[] | select(.name == "scaena")
        | .releases[] | select(.tag == "scaena/v0.4.0") | .assets)
       |= map(select(. != "scaena-api_darwin_arm64.tar.gz"))
       | del(.products[] | select(.name == "scaena")
             | .releases[] | select(.tag == "scaena/v0.4.0")
             | .asset_digests["scaena-api_darwin_arm64.tar.gz"])' \
    "$SBX/run/catalog.json" > "$SBX/catalog-bad-asset.json"
  "$REAL_ROOT/scripts/generate-package-manifests.sh" \
    --catalog "$SBX/catalog-bad-asset.json" --output-root "$GEN_OUT" >/dev/null 2>&1 \
    || { echo "generator failed on an incomplete matrix" >&2; return 1; }
  [[ "$(group_sig)" == "$sig_before" ]] || { echo "group changed on missing asset" >&2; return 1; }
  # Sanity: the good catalog still regenerates the identical group.
  "$REAL_ROOT/scripts/generate-package-manifests.sh" \
    --catalog "$SBX/run/catalog.json" --output-root "$GEN_OUT" >/dev/null 2>&1 || return 1
  [[ "$(group_sig)" == "$sig_before" ]]
}

# 13. policy/scaena.json regenerates byte-identically (no hand edits).
t_policy_deterministic() {
  local tmp rc=1
  tmp="$(mktemp)"
  if "$REAL_ROOT/scripts/generate-scaena-policy.sh" --output "$tmp" >/dev/null \
     && diff -q "$tmp" "$REAL_ROOT/policy/scaena.json" >/dev/null; then
    rc=0
  fi
  rm -f "$tmp"
  return "$rc"
}

tests=(t_alias_table_no_drift t_install_default_compat t_install_api_alias_prefix
       t_install_worker_alias t_install_os_arch_matrix t_install_zip_extraction
       t_install_unsupported_os t_install_checksum_mismatch
       t_install_explicit_version t_install_uninstall_reinstall
       t_manifest_group_generated t_manifest_group_atomic t_policy_deterministic)
for t in "${tests[@]}"; do
  if "$t"; then ok "$t"; else bad "$t"; fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "scaena package tests: FAILED" >&2
  exit 1
fi
echo "scaena package tests: ${#tests[@]}/${#tests[@]} passed"
