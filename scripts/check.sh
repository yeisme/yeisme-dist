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
check bash -n install.sh

if ! grep -qE '^eikona\|yeisme/eikona\|' products.txt; then
  echo "FAIL products.txt missing eikona row" >&2
  fail=1
else
  echo "ok  products.txt has eikona"
fi

while IFS='|' read -r name src strip; do
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

exit "$fail"
