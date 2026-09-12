#!/usr/bin/env bash
# test-offline.sh — offline fixture tests for scripts/lib/verify.sh.
# No credentials, no network: gh_api reads tests/fixtures/api, receipts are
# written into a sandbox, and DIST_VERIFY_NOW pins produced_at. Fixture
# assets are generated deterministically, so receipt fingerprints are stable.
#
# Regenerate the golden receipt after an intentional contract change with:
#   GOLDEN_UPDATE=1 scripts/test-offline.sh
set -euo pipefail

REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }
command -v sha256sum >/dev/null || { echo 'sha256sum required' >&2; exit 2; }

SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT

ROOT="$SBX/repo"            # dist_root(): receipts land in the sandbox
export ROOT
export DIST_VERIFY_NOW="2026-08-26T00:00:00Z"
export DIST_VERIFY_FIXTURE_DIR="$REAL_ROOT/tests/fixtures"

source "$REAL_ROOT/scripts/lib/verify.sh"

POLICY="$REAL_ROOT/policy/anatomia.json"
HINTS="$REAL_ROOT/tests/fixtures/hints"
GOLDEN="$REAL_ROOT/tests/fixtures/golden/anatomia-v0.3.0.json"

REV0_TAGOBJ=1111111111111111111111111111111111111111
REV0=2222222222222222222222222222222222222222
REV1=3333333333333333333333333333333333333333

fail=0
ok()   { echo "ok  $1"; }
bad()  { echo "FAIL $1" >&2; fail=1; }

reset_receipts() { rm -rf "$ROOT/receipts"; }

gen_assets() { # <dir> <version-num> [corrupt:<asset>|missing:<asset>|no-checksums]
  local dir="$1" v="$2" mod="${3:-}" n
  rm -rf "$dir"; mkdir -p "$dir"
  local names=(
    "anatomia_${v}_Darwin_arm64.tar.gz"
    "anatomia_${v}_Darwin_x86_64.tar.gz"
    "anatomia_${v}_Linux_arm64.tar.gz"
    "anatomia_${v}_Linux_x86_64.tar.gz"
    "anatomia-server_${v}_Linux_arm64.tar.gz"
    "anatomia-server_${v}_Linux_x86_64.tar.gz"
  )
  for n in "${names[@]}"; do
    printf 'fixture archive %s %s\n' "$n" "v$v" > "$dir/$n"
    printf 'fixture sbom %s\n' "$n" > "$dir/$n.spdx.json"
  done
  (cd "$dir" && sha256sum "${names[@]}" > checksums.txt)
  case "$mod" in
    corrupt:*)  printf 'corrupted bytes\n' >> "$dir/${mod#corrupt:}" ;;
    missing:*)  rm -f "$dir/${mod#missing:}" "$dir/${mod#missing:}.spdx.json" ;;
    no-checksums) rm -f "$dir/checksums.txt" ;;
  esac
}

gen_release() { # <tag> <prerelease:0|1> <file>
  jq -n --arg t "$1" --arg pre "$2" \
    '{tag_name:$t, draft:false, prerelease:($pre == "1"),
      html_url:("https://github.com/yeisme/anatomia/releases/tag/" + $t),
      target_commitish:"main", assets:[]}' > "$3"
}

verify() { # <release_json> <assets_dir> <hint-file|-> → result json (stdout)
  local hint=""
  [[ "$3" != "-" && -n "${3:-}" ]] && hint="$(cat "$3")"
  verify_release_evidence anatomia yeisme/anatomia "" "$POLICY" "$1" "$2" "$hint"
}

expect_reason() { # <result_json> <expected reason>
  [[ "$(jq -r '.reason // ""' <<<"$1")" == "$2" ]]
}

# 1. Happy path: verified facts + receipt matching the committed golden.
t_happy() {
  reset_receipts
  local dir="$SBX/a30"
  gen_assets "$dir" 0.3.0
  gen_release v0.3.0 0 "$SBX/rel30.json"
  local result
  result="$(verify "$SBX/rel30.json" "$dir" "$HINTS/good.json")" || return 1
  jq -e --arg rev "$REV0" \
    '.status != "failed" and .source_revision == $rev and
         (.handoff.sha256 | startswith("sha256:")) and
         (.verified.asset_matrix == {expected:6, matched:6}) and
         (.verified.upstream_assets | length == 6) and
         (.verified.provenance.sbom_assets | length == 6)' <<<"$result" >/dev/null \
    || return 1
  local facts mirrored receipt
  mirrored="$(verify_mirror_assets "$(jq -c '.verified.upstream_assets' <<<"$result")" "$dir")" || return 1
  facts="$(jq --argjson m "$mirrored" '. + {mirrored_assets:$m}' <<<"$result")"
  write_receipt anatomia v0.3.0 "$facts" >/dev/null || return 1
  receipt="$ROOT/receipts/anatomia/v0.3.0.json"
  jq -e '.schema_version == "yeisme.dist_receipt.v1" and .status == "success"
         and .distribution_revision == 1 and .produced_at == "2026-08-26T00:00:00Z"
         and (.fingerprint_sha256 | test("^sha256:[0-9a-f]{64}$"))
         and (.mirrored_assets | length == 6)' "$receipt" >/dev/null || return 1
  # fingerprint is reproducible from the receipt's own fields
  local fp
  fp="$(receipt_fingerprint "$(jq '{product,channel,upstream_tag,source_revision,
      verified:{upstream_assets:.verified.upstream_assets},mirrored_assets,handoff:{sha256:.handoff.sha256}}' "$receipt")")"
  [[ "sha256:$fp" == "$(jq -r .fingerprint_sha256 "$receipt")" ]] || return 1
  if [[ "${GOLDEN_UPDATE:-0}" == "1" ]]; then
    mkdir -p "$(dirname "$GOLDEN")"; jq -S . "$receipt" > "$GOLDEN"
    return 0
  fi
  diff <(jq -S . "$receipt") <(jq -S . "$GOLDEN") >/dev/null
}

# 2. Idempotency: same verified set writes once, then skips immutably.
t_idempotent() {
  reset_receipts
  local dir="$SBX/a30b"
  gen_assets "$dir" 0.3.0
  gen_release v0.3.0 0 "$SBX/rel30b.json"
  local result facts mirrored out1 out2 sum1 sum2
  result="$(verify "$SBX/rel30b.json" "$dir" "$HINTS/good.json")" || return 1
  mirrored="$(verify_mirror_assets "$(jq -c '.verified.upstream_assets' <<<"$result")" "$dir")" || return 1
  facts="$(jq --argjson m "$mirrored" '. + {mirrored_assets:$m}' <<<"$result")"
  out1="$(write_receipt anatomia v0.3.0 "$facts")" || return 1
  [[ "$out1" == "wrote "* ]] || return 1
  sum1="$(sha256sum "$ROOT/receipts/anatomia/v0.3.0.json" | cut -d' ' -f1)"
  out2="$(write_receipt anatomia v0.3.0 "$facts")" || return 1
  [[ "$out2" == "skip-immutable "* ]] || return 1
  sum2="$(sha256sum "$ROOT/receipts/anatomia/v0.3.0.json" | cut -d' ' -f1)"
  [[ "$sum1" == "$sum2" ]]
}

# 3. Corrupted newer release: verification fails, catalog keeps the last
#    verified entry.
t_corrupt_retains_last_verified() {
  reset_receipts
  local dir="$SBX/a20"
  gen_assets "$dir" 0.2.0
  gen_release v0.2.0 0 "$SBX/rel20.json"
  local r20 m20
  r20="$(verify "$SBX/rel20.json" "$dir" -)" || return 1
  m20="$(verify_mirror_assets "$(jq -c '.verified.upstream_assets' <<<"$r20")" "$dir")" || return 1
  write_receipt anatomia v0.2.0 "$(jq --argjson m "$m20" '. + {mirrored_assets:$m}' <<<"$r20")" >/dev/null || return 1

  gen_assets "$SBX/a30c" 0.3.0 "corrupt:anatomia_0.3.0_Linux_x86_64.tar.gz"
  gen_release v0.3.0 0 "$SBX/rel30c.json"
  local r30
  if r30="$(verify "$SBX/rel30c.json" "$SBX/a30c" -)"; then
    return 1   # corrupted asset must fail
  fi
  expect_reason "$r30" checksum_mismatch || return 1
  record_failed_attempt anatomia v0.3.0 "$r30" 2>/dev/null || return 1
  jq -e '.status == "failed" and .reason == "checksum_mismatch" and .produced_at' \
    "$ROOT/receipts/anatomia/failures/v0.3.0.json" >/dev/null || return 1

  local releases joined
  releases="$(jq -n '[
    {tag:"anatomia/v0.3.0", version:"v0.3.0", published_at:"", prerelease:false, asset_count:13, assets:[]},
    {tag:"anatomia/v0.2.0", version:"v0.2.0", published_at:"", prerelease:false, asset_count:13, assets:[]}]')"
  joined="$(catalog_join_receipts anatomia "$releases")"
  jq -e '.[0].verification == null and .[1].verification.status == "verified"
         and .[1].verification.upstream_tag == "v0.2.0"' <<<"$joined" >/dev/null || return 1
  [[ "$(jq -r 'map(select(.prerelease == false and .verification.status == "verified")) | .[0].tag // empty' <<<"$joined")" == "anatomia/v0.2.0" ]]
}

# 4. Missing expected archive: matrix failure, partial sets never eligible.
t_missing_matrix() {
  local dir="$SBX/a30m"
  gen_assets "$dir" 0.3.0 "missing:anatomia-server_0.3.0_Linux_arm64.tar.gz"
  gen_release v0.3.0 0 "$SBX/rel30m.json"
  local r
  r="$(verify "$SBX/rel30m.json" "$dir" -)" && return 1
  expect_reason "$r" asset_matrix_missing
}

# 5. Missing checksums file (policy requires it; legacy path tolerated it).
t_no_checksums() {
  local dir="$SBX/a30n"
  gen_assets "$dir" 0.3.0 no-checksums
  gen_release v0.3.0 0 "$SBX/rel30n.json"
  local r
  r="$(verify "$SBX/rel30n.json" "$dir" -)" && return 1
  expect_reason "$r" checksums_missing
}

# 6. Snapshot / prerelease never enters the stable policy path.
t_snapshot_excluded() {
  gen_release snapshot-abc123 0 "$SBX/relsnap.json"
  policy_check_eligibility "$SBX/relsnap.json" "$POLICY" >/dev/null && return 1
  local dir="$SBX/a30s"
  gen_assets "$dir" 0.3.0
  gen_release v0.3.0 1 "$SBX/relpre.json"
  policy_check_eligibility "$SBX/relpre.json" "$POLICY" >/dev/null && return 1
  local r
  r="$(verify "$SBX/relpre.json" "$dir" -)" && return 1
  expect_reason "$r" prerelease
}

# 7. Stale / wrong-revision / other-product hints fail correlation.
t_hint_mismatch() {
  local dir="$SBX/a30h"
  gen_assets "$dir" 0.3.0
  gen_release v0.3.0 0 "$SBX/rel30h.json"
  local r
  r="$(verify "$SBX/rel30h.json" "$dir" "$HINTS/stale-tag.json")" && return 1
  expect_reason "$r" hint_mismatch || return 1
  r="$(verify "$SBX/rel30h.json" "$dir" "$HINTS/wrong-revision.json")" && return 1
  expect_reason "$r" hint_mismatch || return 1
  r="$(verify "$SBX/rel30h.json" "$dir" "$HINTS/other-product.json")" && return 1
  expect_reason "$r" hint_mismatch
}

# 8. Fingerprint conflict: a different verified set may not rewrite an
#    existing immutable receipt.
t_fingerprint_conflict() {
  reset_receipts
  local dir="$SBX/a30f"
  gen_assets "$dir" 0.3.0
  gen_release v0.3.0 0 "$SBX/rel30f.json"
  local r m facts sum1
  r="$(verify "$SBX/rel30f.json" "$dir" -)" || return 1
  m="$(verify_mirror_assets "$(jq -c '.verified.upstream_assets' <<<"$r")" "$dir")" || return 1
  facts="$(jq --argjson m "$m" '. + {mirrored_assets:$m}' <<<"$r")"
  write_receipt anatomia v0.3.0 "$facts" >/dev/null || return 1
  sum1="$(sha256sum "$ROOT/receipts/anatomia/v0.3.0.json" | cut -d' ' -f1)"
  # upstream "re-release" with different bits for the same tag
  gen_assets "$dir" 0.3.0 "corrupt:anatomia_0.3.0_Darwin_arm64.tar.gz"
  ( cd "$dir" && sha256sum anatomia_* anatomia-server_* > checksums.txt )
  r="$(verify "$SBX/rel30f.json" "$dir" -)" || return 1
  m="$(verify_mirror_assets "$(jq -c '.verified.upstream_assets' <<<"$r")" "$dir")" || return 1
  facts="$(jq --argjson m "$m" '. + {mirrored_assets:$m}' <<<"$r")"
  if write_receipt anatomia v0.3.0 "$facts" 2>/dev/null; then
    return 1   # must refuse (exit 3)
  fi
  [[ "$(sha256sum "$ROOT/receipts/anatomia/v0.3.0.json" | cut -d' ' -f1)" == "$sum1" ]]
}

# 9. Denied asset names fail verification.
t_denied_asset() {
  local dir="$SBX/a30d"
  gen_assets "$dir" 0.3.0
  printf 'leak\n' > "$dir/anatomia_deploy.env"
  gen_release v0.3.0 0 "$SBX/rel30d.json"
  local r
  r="$(verify "$SBX/rel30d.json" "$dir" -)" && return 1
  expect_reason "$r" denied_asset_name
}

# 10. Catalog join: additive fields from receipts, schema stays 1, digest
#     matches the receipt file, verified_latest picks the newest verified.
t_catalog_join() {
  reset_receipts
  local dir="$SBX/a31"
  gen_assets "$dir" 0.3.1
  gen_release v0.3.1 0 "$SBX/rel31.json"
  local r m
  r="$(verify "$SBX/rel31.json" "$dir" -)" || return 1
  [[ "$(jq -r .source_revision <<<"$r")" == "$REV1" ]] || return 1  # lightweight tag, one hop
  m="$(verify_mirror_assets "$(jq -c '.verified.upstream_assets' <<<"$r")" "$dir")" || return 1
  write_receipt anatomia v0.3.1 "$(jq --argjson m "$m" '. + {mirrored_assets:$m}' <<<"$r")" >/dev/null || return 1

  local releases joined rp rsha
  releases="$(jq -n '[
    {tag:"anatomia/v0.3.1", version:"v0.3.1", published_at:"", prerelease:false, asset_count:13, assets:[]},
    {tag:"anatomia/v0.2.0", version:"v0.2.0", published_at:"", prerelease:false, asset_count:13, assets:[]}]')"
  joined="$(catalog_join_receipts anatomia "$releases")"
  jq -e '.[0].receipt == "receipts/anatomia/v0.3.1.json"
         and .[0].verification.status == "verified"
         and .[0].verification.distribution_revision == 1
         and .[0].verification.handoff_sha256 == null' <<<"$joined" >/dev/null || return 1
  rp="$ROOT/receipts/anatomia/v0.3.1.json"
  rsha="sha256:$(sha256sum "$rp" | cut -d' ' -f1)"
  [[ "$(jq -r '.[0].receipt_sha256' <<<"$joined")" == "$rsha" ]] || return 1
  [[ "$(jq -r 'map(select(.prerelease == false and .verification.status == "verified")) | .[0].tag' <<<"$joined")" == "anatomia/v0.3.1" ]] || return 1
  # empty product: join is a no-op passthrough
  [[ "$(catalog_join_receipts nosuch '[]')" == "[]" ]]
}

# 11. Post-mirror digest verification catches a corrupted mirror copy.
t_mirror_verify() {
  local dir="$SBX/a30v" vdir="$SBX/mirror30"
  gen_assets "$dir" 0.3.0
  cp -r "$dir" "$vdir"
  local expected
  expected="$(cd "$dir" && sha256sum anatomia_*.tar.gz anatomia-server_*.tar.gz \
    | jq -R -s 'split("\n") | map(select(length>0)) | map(split("  ")[0] as $d | split("  ")[1] as $n | {name:$n, sha256:("sha256:"+$d)})')"
  verify_mirror_assets "$expected" "$vdir" >/dev/null || return 1
  printf 'bitrot\n' >> "$vdir/anatomia_0.3.0_Linux_arm64.tar.gz"
  verify_mirror_assets "$expected" "$vdir" 2>/dev/null && return 1
  rm "$vdir/anatomia_0.3.0_Linux_x86_64.tar.gz"
  verify_mirror_assets "$expected" "$vdir" 2>/dev/null && return 1
  return 0
}

# 12. Unparseable hint fails closed; missing API fixture fails revision lookup.
t_fail_closed() {
  local dir="$SBX/a30fc"
  gen_assets "$dir" 0.3.0
  gen_release v0.3.0 0 "$SBX/rel30fc.json"
  local r
  r="$(verify "$SBX/rel30fc.json" "$dir" "$HINTS/invalid.json")" && return 1
  expect_reason "$r" hint_invalid || return 1
  local saved="$DIST_VERIFY_FIXTURE_DIR"
  DIST_VERIFY_FIXTURE_DIR="$SBX/no-fixture"
  r="$(verify "$SBX/rel30fc.json" "$dir" -)" && return 1
  expect_reason "$r" source_revision_unavailable || return 1
  DIST_VERIFY_FIXTURE_DIR="$saved"
  return 0
}

# 13. Shared Scaena install manifest declares an exact four-file Skills set.
t_scaena_skills_assets() {
  local dir="$SBX/scaena-skills" version=1.2.3
  rm -rf "$dir"; mkdir -p "$dir"
  printf 'bundle\n' > "$dir/scaena-skills_${version}.tar.gz"
  printf '{"schema_version":"yeisme.agent_skills.bundle.v1"}\n' > "$dir/scaena-skills_${version}.json"
  printf '{"schema_version":"yeisme.agent_skills.catalog.v1"}\n' > "$dir/scaena-skills-catalog_${version}.json"
  local bundle_sha manifest_sha catalog_sha
  bundle_sha="$(sha256sum "$dir/scaena-skills_${version}.tar.gz" | cut -d' ' -f1)"
  manifest_sha="$(sha256sum "$dir/scaena-skills_${version}.json" | cut -d' ' -f1)"
  catalog_sha="$(sha256sum "$dir/scaena-skills-catalog_${version}.json" | cut -d' ' -f1)"
  jq -n --arg version "$version" --arg bundle "$bundle_sha" --arg manifest "$manifest_sha" --arg catalog "$catalog_sha" '
    {schema_version:"yeisme.product_install_manifest.v1", product:"scaena",
     product_version:$version, tag:("scaena/v"+$version), commit:("a"*40),
     skills:{bundle_version:$version, source:{repository:"https://github.com/yeisme/yeisme-agent-my-skills",commit:("b"*40)},
       runtime_targets:["agents","codex","claude"],
       bundle:{name:("scaena-skills_"+$version+".tar.gz"),kind:"skills_bundle",url:("https://example.invalid/scaena-skills_"+$version+".tar.gz"),sha256:("sha256:"+$bundle)},
       manifest:{name:("scaena-skills_"+$version+".json"),kind:"skills_manifest",url:("https://example.invalid/scaena-skills_"+$version+".json"),sha256:("sha256:"+$manifest)},
       catalog:{name:("scaena-skills-catalog_"+$version+".json"),kind:"skills_catalog",url:("https://example.invalid/scaena-skills-catalog_"+$version+".json"),sha256:("sha256:"+$catalog)}}}
  ' > "$dir/scaena-install-manifest.json"
  (cd "$dir" && sha256sum scaena-* > checksums.txt)

  local result
  result="$(verify_declared_skills_assets scaena "scaena/v$version" "$dir")" || return 1
  jq -e '.status == "verified" and (.assets | length == 4)
         and ([.assets[].name] | index("scaena-install-manifest.json") != null)' <<<"$result" >/dev/null || return 1
  printf 'bitrot\n' >> "$dir/scaena-skills_${version}.tar.gz"
  result="$(verify_declared_skills_assets scaena "scaena/v$version" "$dir")" && return 1
  expect_reason "$result" skills_asset_checksum_mismatch || return 1
  printf 'bundle\n' > "$dir/scaena-skills_${version}.tar.gz"
  rm "$dir/scaena-skills-catalog_${version}.json"
  result="$(verify_declared_skills_assets scaena "scaena/v$version" "$dir")" && return 1
  expect_reason "$result" skills_asset_missing
}

# 14. Eikona's legacy manifest remains readable and adopts metadata/catalog
#     when the release declares them through files/checksums.
t_eikona_skills_assets() {
  local dir="$SBX/eikona-skills" version=0.7.4
  rm -rf "$dir"; mkdir -p "$dir"
  printf 'bundle\n' > "$dir/eikona-skills_${version}.tar.gz"
  printf '{"schema_version":"eikona.skills_bundle.v1"}\n' > "$dir/eikona-skills_${version}.json"
  printf '{"schema_version":"eikona.command_catalog.v1"}\n' > "$dir/eikona-command-catalog_${version}.json"
  local bundle_sha
  bundle_sha="$(sha256sum "$dir/eikona-skills_${version}.tar.gz" | cut -d' ' -f1)"
  jq -n --arg version "$version" --arg sha "$bundle_sha" '
    {schema_version:"eikona.install_manifest.v1", repository:"https://github.com/yeisme/eikona",
     owner:"yeisme", name:"eikona", channel:"stable", tag:("v"+$version), commit:("a"*40),
     cli_version:$version, skills_bundle_version:$version,
     skills_source_repository:"https://github.com/yeisme/yeisme-agent-my-skills", skills_source_commit:("b"*40),
     runtime_targets:["agents","claude","codex"], skills:[{name:"example",files:[{path:"SKILL.md",sha256:("c"*64)}]}],
     assets:{skills_bundle:{name:("eikona-skills_"+$version+".tar.gz"),kind:"skills_bundle",sha256:$sha}}}
  ' > "$dir/eikona-install-manifest.json"
  (cd "$dir" && sha256sum eikona-* > checksums.txt)

  local result
  result="$(verify_declared_skills_assets eikona "v$version" "$dir")" || return 1
  jq -e '.status == "verified" and (.assets | length == 4)
         and ([.assets[].name] | index("eikona-command-catalog_0.7.4.json") != null)' <<<"$result" >/dev/null
}

# --- Scaena v0.4 three-package channel tests (scaena-v0-4-package-channels) ---

FIXTURE_V04="$REAL_ROOT/tests/fixtures/scaena/scaena-dist-handoff_0.4.0-contract.json"
POLICY_SCAENA="$REAL_ROOT/policy/scaena.json"

SCAENA_REF_SHA=4444444444444444444444444444444444444444

scaena_gen_assets() { # <dir> [mod]  mod: missing:<name> | corrupt:<name> | bad-sbom:<name> | drop-sbom:<name> | no-handoff
  local dir="$1" mod="${2:-}" name pkg os arch ext
  rm -rf "$dir"; mkdir -p "$dir"
  for pkg in scaena scaena-api scaena-production-worker; do
    for os_arch_ext in "linux amd64 tar.gz" "linux arm64 tar.gz" \
                       "darwin amd64 tar.gz" "darwin arm64 tar.gz" \
                       "windows amd64 zip" "windows arm64 zip"; do
      read -r os arch ext <<<"$os_arch_ext"
      name="${pkg}_${os}_${arch}.${ext}"
      printf 'scaena v0.4.0 fixture archive %s\n' "$name" > "$dir/$name"
      printf '{"spdxVersion":"SPDX-2.3","name":"%s"}\n' "$name" > "$dir/$name.sbom.json"
    done
  done
  cp "$FIXTURE_V04" "$dir/scaena-dist-handoff_0.4.0.json"
  printf '{"commands":[]}\n' > "$dir/scaena-command-catalog_0.4.0.json"
  printf '{"spdxVersion":"SPDX-2.3","name":"scaena"}\n' > "$dir/scaena.spdx.json"
  # checksums.txt covers all 37 owner-contract entries (18 archives + 18 SBOMs
  # + command catalog) plus the handoff asset, mirroring the real release.
  scaena_checksums() {
    (cd "$dir" && sha256sum scaena-*.json *.sbom.json $(ls | grep -E '\.(tar\.gz|zip)$' | sort) > checksums.txt)
  }
  scaena_checksums
  case "$mod" in
    missing:*)  rm -f "$dir/${mod#missing:}" "$dir/${mod#missing:}.sbom.json" ;;
    corrupt:*)  printf 'corrupted bytes\n' >> "$dir/${mod#corrupt:}" ;;
    bad-sbom:*) printf 'tampered sbom\n' >> "$dir/${mod#bad-sbom:}.sbom.json" ;;
    # release pipeline forgot one SBOM entirely: checksums stay self-consistent
    # over the present files, so only the provenance gate catches it.
    drop-sbom:*) rm -f "$dir/${mod#drop-sbom:}.sbom.json"; scaena_checksums ;;
    no-handoff) rm -f "$dir/scaena-dist-handoff_0.4.0.json" ;;
  esac
}

scaena_gen_release() { # <file> <prerelease:0|1>
  jq -n --arg pre "$2" \
    '{tag_name:"scaena/v0.4.0", draft:false, prerelease:($pre == "1"),
      html_url:"https://github.com/yeisme/scaena/releases/tag/scaena/v0.4.0",
      target_commitish:"main", assets:[]}' > "$1"
}

scaena_verify() { # <release_json> <assets_dir>
  verify_release_evidence scaena yeisme/scaena "scaena/" \
    "$POLICY_SCAENA" "$1" "$2" ""
}

# 15. Policy is deterministically generated from the frozen fixture.
t_scaena_policy_deterministic() {
  local tmp
  tmp="$(mktemp)"
  "$REAL_ROOT/scripts/generate-scaena-policy.sh" --output "$tmp" >/dev/null \
    && diff -q "$tmp" "$POLICY_SCAENA" >/dev/null
  rm -f "$tmp"
}

# 16. Full 18-archive matrix verifies end-to-end with .sbom.json provenance
#     and {version}-interpolated required assets (catalog + handoff).
t_scaena_happy() {
  scaena_gen_assets "$SBX/s40"
  scaena_gen_release "$SBX/rel40.json" 0
  local result
  result="$(scaena_verify "$SBX/rel40.json" "$SBX/s40")" || return 1
  jq -e --arg rev "$SCAENA_REF_SHA" \
    '.status != "failed" and .source_revision == $rev and
     .channel == "stable" and .dist_tag == "scaena/v0.4.0" and
     (.verified.asset_matrix == {expected:18, matched:18}) and
     (.verified.upstream_assets | length == 18) and
     (.verified.provenance.sbom_assets | length == 18) and
     ([.verified.provenance.sbom_assets[] | select(endswith(".sbom.json"))] | length == 18)' \
    <<<"$result" >/dev/null
}

# 17. Missing worker ARM archive fails closed on the asset matrix.
t_scaena_missing_worker_arm() {
  scaena_gen_assets "$SBX/s40m" "missing:scaena-production-worker_linux_arm64.tar.gz"
  scaena_gen_release "$SBX/rel40m.json" 0
  local result
  result="$(scaena_verify "$SBX/rel40m.json" "$SBX/s40m")" && return 1
  expect_reason "$result" asset_matrix_missing
}

# 18. Corrupted archive and tampered SBOM both fail checksum verification.
t_scaena_checksum_and_sbom() {
  scaena_gen_assets "$SBX/s40c" "corrupt:scaena_linux_amd64.tar.gz"
  scaena_gen_release "$SBX/rel40c.json" 0
  local result
  result="$(scaena_verify "$SBX/rel40c.json" "$SBX/s40c")" && return 1
  expect_reason "$result" checksum_mismatch || return 1
  scaena_gen_assets "$SBX/s40s" "bad-sbom:scaena-api_darwin_arm64.tar.gz"
  scaena_gen_release "$SBX/rel40s.json" 0
  result="$(scaena_verify "$SBX/rel40s.json" "$SBX/s40s")" && return 1
  expect_reason "$result" checksum_mismatch
}

# 19. A per-archive SBOM missing from the release (checksums re-covered over
#     the present files) fails the provenance gate with the product-specific
#     .sbom.json suffix; restoring the SBOM and re-covering checksums recovers.
t_scaena_sbom_missing() {
  scaena_gen_assets "$SBX/s40b" "drop-sbom:scaena-api_windows_arm64.zip"
  scaena_gen_release "$SBX/rel40b.json" 0
  local result
  result="$(scaena_verify "$SBX/rel40b.json" "$SBX/s40b")" && return 1
  expect_reason "$result" sbom_missing || return 1
  printf '{"spdxVersion":"SPDX-2.3","name":"scaena-api_windows_arm64.zip"}\n' \
    > "$SBX/s40b/scaena-api_windows_arm64.zip.sbom.json"
  (cd "$SBX/s40b" && sha256sum scaena-*.json *.sbom.json $(ls | grep -E '\.(tar\.gz|zip)$' | sort) > checksums.txt)
  result="$(scaena_verify "$SBX/rel40b.json" "$SBX/s40b")" || return 1
  jq -e '.status != "failed"' <<<"$result" >/dev/null
}

# 20. Missing owner handoff asset blocks verification.
t_scaena_handoff_missing() {
  scaena_gen_assets "$SBX/s40h" no-handoff
  scaena_gen_release "$SBX/rel40h.json" 0
  local result
  result="$(scaena_verify "$SBX/rel40h.json" "$SBX/s40h")" && return 1
  expect_reason "$result" asset_matrix_missing
}

# 21. RC prerelease tags never pass the stable policy.
t_scaena_prerelease_excluded() {
  scaena_gen_assets "$SBX/s40rc"
  scaena_gen_release "$SBX/rel40rc.json" 1
  local result
  result="$(scaena_verify "$SBX/rel40rc.json" "$SBX/s40rc")" && return 1
  expect_reason "$result" prerelease
}

# 22. Mirrored bytes must match the verified upstream digests exactly.
t_scaena_mirror_digest_mismatch() {
  scaena_gen_assets "$SBX/s40"
  scaena_gen_release "$SBX/rel40.json" 0
  local result
  result="$(scaena_verify "$SBX/rel40.json" "$SBX/s40")" || return 1
  cp -r "$SBX/s40" "$SBX/s40mirror"
  printf 'drift\n' >> "$SBX/s40mirror/scaena-production-worker_linux_arm64.tar.gz"
  verify_mirror_assets "$(jq -c '.verified.upstream_assets' <<<"$result")" \
    "$SBX/s40mirror" >/dev/null 2>&1 && return 1
  verify_mirror_assets "$(jq -c '.verified.upstream_assets' <<<"$result")" \
    "$SBX/s40" >/dev/null
}

tests=(t_happy t_idempotent t_corrupt_retains_last_verified t_missing_matrix
       t_no_checksums t_snapshot_excluded t_hint_mismatch t_fingerprint_conflict
       t_denied_asset t_catalog_join t_mirror_verify t_fail_closed
       t_scaena_skills_assets t_eikona_skills_assets
       t_scaena_policy_deterministic t_scaena_happy t_scaena_missing_worker_arm
       t_scaena_checksum_and_sbom t_scaena_sbom_missing t_scaena_handoff_missing
       t_scaena_prerelease_excluded t_scaena_mirror_digest_mismatch)
for t in "${tests[@]}"; do
  if "$t"; then ok "$t"; else bad "$t"; fi
done

if [[ "$fail" -eq 0 ]]; then
  echo "offline tests: ${#tests[@]}/${#tests[@]} passed"
else
  echo "offline tests FAILED" >&2
fi
exit "$fail"
