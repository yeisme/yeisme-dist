#!/usr/bin/env bash
# catalog.sh — shared catalog presentation helpers. Sourced by scripts/sync.sh
# (write_catalog) and scripts/rollback-manifests.sh so the README product
# table is rendered by exactly one implementation.
#
# Respects the ROOT variable (the distribution repo root to operate on) so
# sandboxed drills can point it at a copy of the tree.

write_readme_products() {
  local table tmp
  [[ -f "${ROOT:?}/README.md" ]] || return 0
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
