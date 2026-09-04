#!/usr/bin/env bash
# Local / CI sanity checks that do not require GitHub credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
check() {
  if "$@"; then
    echo "ok  $*"
  else
    echo "FAIL $*" >&2
    fail=1
  fi
}

check bash -n scripts/sync.sh
check bash -n scripts/check.sh
check bash -n scripts/lib/verify.sh
check bash -n scripts/test-offline.sh
check bash -n scripts/generate-package-manifests.sh
check bash -n install.sh
check scripts/test-offline.sh

if ! grep -qE '^eikona\|yeisme/eikona\|' products.txt; then
  echo "FAIL products.txt missing eikona row" >&2
  fail=1
else
  echo "ok  products.txt has eikona"
fi

if [[ -f catalog.json ]]; then
  package_tmp="$(mktemp -d)"
  if scripts/generate-package-manifests.sh --output-root "$package_tmp" \
      && diff -ru Casks "$package_tmp/Casks" >/dev/null \
      && diff -ru bucket "$package_tmp/bucket" >/dev/null; then
    echo "ok  public package manifests are generated from catalog.json"
  else
    echo "FAIL public package manifests are stale or cannot be generated" >&2
    fail=1
  fi

  for product in eikona pinax auctra scaena gitea-mcp sonora anatomia credentialctl; do
    if [[ -f "Casks/$product.rb" ]] \
        && ruby -c "Casks/$product.rb" >/dev/null \
        && grep -q "github.com/yeisme/yeisme-dist/releases/download/$product/" "Casks/$product.rb"; then
      echo "ok  Homebrew cask $product"
    else
      echo "FAIL Homebrew cask $product" >&2
      fail=1
    fi
  done

  for product in eikona pinax auctra gitea-mcp sonora credentialctl; do
    if jq -e '
        (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
        (.architecture | type == "object") and
        ((.architecture | length) > 0)
      ' "bucket/$product.json" >/dev/null \
        && grep -q "github.com/yeisme/yeisme-dist/releases/download/$product/" "bucket/$product.json"; then
      echo "ok  Scoop manifest $product"
    else
      echo "FAIL Scoop manifest $product" >&2
      fail=1
    fi
  done
  if [[ ! -e bucket/scaena.json && ! -e bucket/anatomia.json ]]; then
    echo "ok  Scoop excludes products without Windows archives"
  else
    echo "FAIL Scoop manifest generated without a Windows archive" >&2
    fail=1
  fi
  rm -rf "$package_tmp"

  if ruby -c Casks/eikona.rb >/dev/null \
      && ! grep -q 'github.com/yeisme/eikona/releases/download' Casks/eikona.rb \
      && grep -q 'github.com/yeisme/yeisme-dist/releases/download/eikona/' Casks/eikona.rb \
      && grep -q 'eikona setup' Casks/eikona.rb \
      && grep -q 'eikona setup --yes' Casks/eikona.rb; then
    echo "ok  Homebrew cask syntax, public download source, and setup hints"
  else
    echo "FAIL Homebrew cask must use the public yeisme-dist release" >&2
    fail=1
  fi

  if jq -e '
      .version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")
    ' bucket/eikona.json >/dev/null \
      && ! grep -q 'github.com/yeisme/eikona/releases/download' bucket/eikona.json \
      && grep -q 'github.com/yeisme/yeisme-dist/releases/download/eikona/' bucket/eikona.json \
      && jq -e '.notes | any(contains("eikona setup")) and any(contains("eikona setup --yes"))' bucket/eikona.json >/dev/null; then
    echo "ok  Scoop manifest schema, public download source, and setup notes"
  else
    echo "FAIL Scoop manifest must use the public yeisme-dist release" >&2
    fail=1
  fi

  latest_eikona="$(jq -r '.products[] | select(.name == "eikona") | .latest' catalog.json)"
  latest_eikona_version="${latest_eikona#eikona/v}"
  missing_asset_catalog="$(mktemp)"
  missing_digest_catalog="$(mktemp)"
  jq --arg tag "$latest_eikona" --arg name "eikona-skills_${latest_eikona_version}.tar.gz" '
    (.products[] | select(.name == "eikona") | .releases[] | select(.tag == $tag) | .assets) -= [$name]
  ' catalog.json > "$missing_asset_catalog"
  if scripts/generate-package-manifests.sh --catalog "$missing_asset_catalog" --output-root "$package_tmp" >/dev/null 2>&1; then
    echo "FAIL package manifest generation accepted a missing Skills asset" >&2
    fail=1
  else
    echo "ok  package manifest generation fails on missing required assets"
  fi
  jq --arg tag "$latest_eikona" --arg name "eikona_${latest_eikona_version}_Darwin_arm64.tar.gz" '
    del(.products[] | select(.name == "eikona") | .releases[] | select(.tag == $tag) | .asset_digests[$name])
  ' catalog.json > "$missing_digest_catalog"
  if scripts/generate-package-manifests.sh --catalog "$missing_digest_catalog" --output-root "$package_tmp" >/dev/null 2>&1; then
    echo "FAIL package manifest generation accepted a missing archive digest" >&2
    fail=1
  else
    echo "ok  package manifest generation fails on missing archive digests"
  fi
  rm -f "$missing_asset_catalog" "$missing_digest_catalog"
  rm -rf "$package_tmp"
fi

if ! grep -qE '^credentialctl\|yeisme/credentialctl\|' products.txt; then
  echo "FAIL products.txt missing credentialctl row" >&2
  fail=1
else
  echo "ok  products.txt has credentialctl"
fi
if jq -e '
    .schema_version == "yeisme.dist_verify_policy.v1" and
    .product == "credentialctl" and
    .source_repo == "yeisme/credentialctl" and
    (.expected_assets | length == 5) and
    .provenance.sbom_required_per_archive == true
  ' policy/credentialctl.json >/dev/null; then
  echo "ok  credentialctl verify policy"
else
  echo "FAIL credentialctl verify policy" >&2
  fail=1
fi
credentialctl_tag_pattern="$(jq -r '.eligible_tag_pattern' policy/credentialctl.json)"
if jq -ne --arg pattern "$credentialctl_tag_pattern" '"v0.3.0" | test($pattern)' >/dev/null \
    && ! jq -ne --arg pattern "$credentialctl_tag_pattern" '"v0.2.0" | test($pattern)' >/dev/null; then
  echo "ok  credentialctl policy starts at the v0.3 supply-chain contract"
else
  echo "FAIL credentialctl policy version boundary" >&2
  fail=1
fi

source scripts/lib/verify.sh
if denied credentialctl_0.3.0_darwin_aarch64.tar.gz credentialctl \
    || denied credentialctl_0.3.0_linux_x86_64.tar.gz.spdx.json credentialctl; then
  echo "FAIL credentialctl release asset allowlist" >&2
  fail=1
else
  echo "ok  credentialctl release archives and SBOMs bypass only the product-name tripwire"
fi
if denied credentialctl_secret.env credentialctl; then
  echo "ok  credentialctl suspicious asset names remain denied"
else
  echo "FAIL credentialctl suspicious asset bypassed the denylist" >&2
  fail=1
fi

credentialctl_catalog="$(mktemp)"
credentialctl_output="$(mktemp -d)"
jq '
  .products = ([.products[] | select(.name != "credentialctl")] + [{
    name: "credentialctl",
    source_repo: "yeisme/credentialctl",
    latest: "credentialctl/v0.3.0",
    verified_latest: null,
    release_count: 1,
    releases: [{
      tag: "credentialctl/v0.3.0",
      version: "v0.3.0",
      published_at: "2026-09-04T00:00:00Z",
      prerelease: false,
      asset_count: 5,
      assets: [
        "credentialctl_0.3.0_darwin_aarch64.tar.gz",
        "credentialctl_0.3.0_darwin_x86_64.tar.gz",
        "credentialctl_0.3.0_linux_aarch64.tar.gz",
        "credentialctl_0.3.0_linux_x86_64.tar.gz",
        "credentialctl_0.3.0_windows_x86_64.zip"
      ],
      asset_digests: {
        "credentialctl_0.3.0_darwin_aarch64.tar.gz": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "credentialctl_0.3.0_darwin_x86_64.tar.gz": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "credentialctl_0.3.0_linux_aarch64.tar.gz": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "credentialctl_0.3.0_linux_x86_64.tar.gz": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "credentialctl_0.3.0_windows_x86_64.zip": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      }
    }]
  }])
' catalog.json > "$credentialctl_catalog"
if scripts/generate-package-manifests.sh --catalog "$credentialctl_catalog" --output-root "$credentialctl_output" \
    && ruby -c "$credentialctl_output/Casks/credentialctl.rb" >/dev/null \
    && grep -q 'github.com/yeisme/yeisme-dist/releases/download/credentialctl/v#{version}/' \
      "$credentialctl_output/Casks/credentialctl.rb" \
    && grep -q 'skills add https://github.com/yeisme/yeisme-agent-my-skills' \
      "$credentialctl_output/Casks/credentialctl.rb" \
    && jq -e '.architecture["64bit"].hash and (.notes | any(contains("credentialctl-usage")))' \
      "$credentialctl_output/bucket/credentialctl.json" >/dev/null; then
  echo "ok  credentialctl Homebrew/Scoop fixtures and Skill hint"
else
  echo "FAIL credentialctl Homebrew/Scoop fixture" >&2
  fail=1
fi
rm -f "$credentialctl_catalog"
rm -rf "$credentialctl_output"

if ! grep -qE '^sonora\|yeisme/sonora\|' products.txt; then
  echo "FAIL products.txt missing sonora row" >&2
  fail=1
else
  echo "ok  products.txt has sonora"
fi

if ! grep -qE '^KNOWN_FALLBACK=\(.*sonora' install.sh; then
  echo "FAIL install.sh fallback missing sonora" >&2
  fail=1
else
  echo "ok  install.sh fallback has sonora"
fi
if ! grep -qE '^KNOWN_FALLBACK=\(.*credentialctl' install.sh; then
  echo "FAIL install.sh fallback missing credentialctl" >&2
  fail=1
else
  echo "ok  install.sh fallback has credentialctl"
fi

while IFS='|' read -r name src _strip; do
  name="${name//[[:space:]]/}"; src="${src//[[:space:]]/}"
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ ! "$name" =~ ^[a-z0-9-]+$ ]]; then
    echo "FAIL products.txt invalid name: $name" >&2
    fail=1
  fi
  if [[ ! "$src" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "FAIL products.txt invalid source_repo: $src" >&2
    fail=1
  fi
done < products.txt
echo "ok  products.txt rows"

if [[ -f catalog.json ]]; then
  if command -v jq >/dev/null; then
    jq -e '.schema_version == 1 and (.products | type == "array") and (.products | length > 0)' catalog.json >/dev/null
    echo "ok  catalog.json schema"
    expected="$(awk -F'|' '/^[[:space:]]*#/ {next} NF>=2 {gsub(/[[:space:]]/,"",$1); if($1!="") print $1}' products.txt | wc -l)"
    got="$(jq '.products | length' catalog.json)"
    if [[ "$got" -ne "$expected" ]]; then
      echo "FAIL catalog.json product count $got != products.txt $expected" >&2
      fail=1
    else
      echo "ok  catalog.json product count ($got)"
    fi
    # Every mirrored product with releases must ship a Linux amd64/x86_64 archive
    # the anonymous installer can pick (not only .deb/.rpm).
    while IFS= read -r name; do
      latest="$(jq -r --arg p "$name" '.products[] | select(.name == $p) | .latest // empty' catalog.json)"
      [[ -n "$latest" ]] || continue
      assets="$(jq -r --arg p "$name" '.products[] | select(.name == $p) | .releases[0].assets[]' catalog.json)"
      if ! grep -Eqi 'linux[-_](x86_64|amd64)\.(tar\.gz|tgz|zip)$' <<<"$assets"; then
        echo "FAIL $name latest has no Linux x86_64/amd64 archive:" >&2
        echo "$assets" >&2
        fail=1
      else
        echo "ok  $name has Linux x86_64/amd64 archive"
      fi
    done < <(awk -F'|' '/^[[:space:]]*#/ {next} NF>=2 {gsub(/[[:space:]]/,"",$1); if($1!="") print $1}' products.txt)
  else
    echo "skip catalog.json jq (jq not installed)"
  fi
else
  echo "skip catalog.json (not generated yet)"
fi

help_out="$(bash install.sh --help)"
echo "$help_out" | grep -q 'usage: install.sh' || { echo "FAIL install.sh --help" >&2; fail=1; }
echo "$help_out" | grep -q -- '--list' || { echo "FAIL install.sh --help missing --list" >&2; fail=1; }
grep -q sonora <<<"$help_out" || { echo "FAIL install.sh --help missing sonora" >&2; fail=1; }
grep -q credentialctl <<<"$help_out" || { echo "FAIL install.sh --help missing credentialctl" >&2; fail=1; }
list_out="$(bash install.sh --list)"
echo "$list_out" | grep -q eikona || { echo "FAIL install.sh --list missing eikona" >&2; fail=1; }
grep -q sonora <<<"$list_out" || { echo "FAIL install.sh --list missing sonora" >&2; fail=1; }
grep -q credentialctl <<<"$list_out" || { echo "FAIL install.sh --list missing credentialctl" >&2; fail=1; }
echo "ok  install.sh --list"
grep -q 'eikona setup' install.sh || { echo "FAIL install.sh missing Eikona setup hint" >&2; fail=1; }
grep -q 'eikona setup --yes' install.sh || { echo "FAIL install.sh missing Eikona apply hint" >&2; fail=1; }
if bash install.sh 2>/dev/null; then
  echo "FAIL install.sh without product should exit non-zero" >&2
  fail=1
else
  echo "ok  install.sh requires product"
fi
if bash install.sh definitely-not-a-product 2>/dev/null; then
  echo "FAIL unknown product should exit non-zero" >&2
  fail=1
else
  echo "ok  install.sh rejects unknown product"
fi

# Receipt / catalog cross-consistency (only when receipts exist). Additive
# receipt fields must survive catalog regeneration: a join regression fails
# here instead of silently dropping verification evidence.
if [[ -d receipts ]]; then
  bad_receipt=0
  while IFS= read -r r; do
    [[ "$r" == */failures/* ]] && continue
    if ! jq -e '.schema_version == "yeisme.dist_receipt.v1" and .status == "success"
                and (.fingerprint_sha256 | test("^sha256:[0-9a-f]{64}$"))' \
         "$r" >/dev/null 2>&1; then
      echo "FAIL receipt schema: $r" >&2
      bad_receipt=1
    fi
  done < <(find receipts -name '*.json' -type f)
  if [[ $bad_receipt -eq 0 ]]; then echo "ok  receipts schema"; else fail=1; fi

  if [[ -f catalog.json ]]; then
    bad_join=0
    while IFS=$'\t' read -r product receipt rsha; do
      [[ -n "$product" ]] || continue
      if [[ ! -f "$receipt" ]]; then
        echo "FAIL catalog receipt missing: $receipt" >&2
        bad_join=1; continue
      fi
      actual="sha256:$(sha256sum "$receipt" | cut -d' ' -f1)"
      if [[ "$actual" != "$rsha" ]]; then
        echo "FAIL catalog receipt_sha256 mismatch: $receipt" >&2
        bad_join=1
      fi
    done < <(jq -r '.products[] as $p | $p.releases[]? | select(.receipt) |
                    "\($p.name)\t\(.receipt)\t\(.receipt_sha256)"' catalog.json)
    while IFS=$'\t' read -r product vl; do
      [[ -n "$product" ]] || continue
      if ! jq -e --arg p "$product" --arg vl "$vl" \
           '.products[] | select(.name == $p) | .releases[] | select(.tag == $vl) |
            .verification.status == "verified"' catalog.json >/dev/null 2>&1; then
        echo "FAIL verified_latest $product/$vl lacks a verified receipt" >&2
        bad_join=1
      fi
    done < <(jq -r '.products[] | select(.verified_latest) | "\(.name)\t\(.verified_latest)"' catalog.json)
    if [[ $bad_join -eq 0 ]]; then echo "ok  catalog receipt join"; else fail=1; fi
  fi
fi

exit "$fail"
