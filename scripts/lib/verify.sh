#!/usr/bin/env bash
# verify.sh — upstream fetch-and-verify and distribution receipt library.
# Sourced by scripts/sync.sh (and by scripts/test-offline.sh). See
# docs/distribution-contracts.md for the contracts implemented here.
#
# Offline testing: set DIST_VERIFY_FIXTURE_DIR to make gh_api read fixture
# files instead of calling the network, and DIST_VERIFY_NOW to pin receipt
# produced_at. These are the only test seams.

# Single network choke point. <logical> names the call for fixtures; the
# fixture file is "$DIST_VERIFY_FIXTURE_DIR/api/<logical with / and : as _>.json".
gh_api() {
  local logical="$1" path="$2"
  if [[ -n "${DIST_VERIFY_FIXTURE_DIR:-}" ]]; then
    local f
    f="$DIST_VERIFY_FIXTURE_DIR/api/$(printf '%s' "$logical" | tr '/:' '__').json"
    [[ -f "$f" ]] || { echo "gh_api fixture missing: $logical" >&2; return 1; }
    cat "$f"
  else
    gh api "$path"
  fi
}

dist_root() {
  if [[ -n "${ROOT:-}" ]]; then
    printf '%s' "$ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
  fi
}

denied() {
  local low product="${2:-}"
  low="$(basename "$1" | tr '[:upper:]' '[:lower:]')"
  if [[ "$product" == "credentialctl" ]] &&
      [[ "$low" =~ ^credentialctl_[0-9]+\.[0-9]+\.[0-9]+_(darwin|linux)_(aarch64|x86_64)\.tar\.gz(\.spdx\.json)?$|^credentialctl_[0-9]+\.[0-9]+\.[0-9]+_windows_x86_64\.zip(\.spdx\.json)?$ ]]; then
    return 1
  fi
  case "$low" in
    *token*|*secret*|*credential*|*.pem|*.key|*.env|*.p12|*id_rsa*|*.kdbx) return 0 ;;
    *) return 1 ;;
  esac
}

verify_policy_has() { # <product>
  [[ -f "$(dist_root)/policy/$1.json" ]]
}

# Cheap pre-check that avoids downloading assets for releases the policy
# excludes entirely (draft / prerelease / ineligible tag). Echoes the reason
# and returns 1 when ineligible; returns 0 when eligible.
policy_check_eligibility() { # <release_json_file> <policy_file>
  local rel="$1" policy="$2" pattern ok
  if [[ "$(jq -r '.draft // false' "$rel")" == "true" ]]; then
    echo "draft"; return 1
  fi
  if [[ "$(jq -r '.prerelease // false' "$rel")" == "true" ]] \
     && [[ "$(jq -r '.exclude_prerelease // true' "$policy")" == "true" ]]; then
    echo "prerelease"; return 1
  fi
  pattern="$(jq -r '.eligible_tag_pattern // ".*"' "$policy")"
  ok="$(jq -n --arg t "$(jq -r '.tag_name // ""' "$rel")" --arg pat "$pattern" \
        '$t | test($pat)' 2>/dev/null || true)"
  if [[ "$ok" != "true" ]]; then
    echo "tag_ineligible"; return 1
  fi
  return 0
}

emit_fail() { # <reason> [detail_json] — redacted failure result on stdout
  jq -n --arg r "$1" --argjson d "${2:-{\}}" '{status:"failed", reason:$r, detail:$d}'
}

checksum_digest_for_asset() { # <checksums-file> <asset-name>
  awk -v expected="$2" '
    NF >= 2 {
      name = $2
      sub(/^\*/, "", name)
      sub(/^\.\//, "", name)
      if (name == expected) print tolower($1)
    }
  ' "$1"
}

# Validate the optional product-owned Agent Skills asset declaration without
# expanding or rebuilding the bundle. Old releases without an install
# manifest remain compatible. Supported manifests are the shared product
# contract and Eikona's release-bound legacy contract.
verify_declared_skills_assets() { # <product> <upstream-tag> <assets-dir>
  local product="$1" tag="$2" dir="$3"
  local manifest="$dir/$product-install-manifest.json"
  if [[ ! -f "$manifest" ]]; then
    jq -cn '{status:"absent", assets:[]}'
    return 0
  fi

  local ck schema version declared_assets
  ck="$(cd "$dir" && ls -- *checksums*.txt 2>/dev/null | head -n1 || true)"
  if [[ -z "$ck" ]]; then
    emit_fail skills_checksums_missing; return 1
  fi
  if ! schema="$(jq -er '.schema_version | strings' "$manifest" 2>/dev/null)"; then
    emit_fail skills_install_manifest_invalid; return 1
  fi
  version="${tag##*/}"; version="${version#v}"

  case "$schema" in
    yeisme.product_install_manifest.v1)
      if ! jq -e --arg product "$product" --arg tag "$tag" --arg version "$version" '
          .product == $product and .tag == $tag and .product_version == $version and
          (.skills | type == "object") and
          .skills.bundle.kind == "skills_bundle" and
          .skills.manifest.kind == "skills_manifest" and
          .skills.catalog.kind == "skills_catalog" and
          ([.skills.bundle, .skills.manifest, .skills.catalog] | all(
            . as $asset |
            ($asset.name | type == "string" and length > 0) and
            ($asset.sha256 | type == "string" and test("^(sha256:)?[0-9a-fA-F]{64}$")) and
            ($asset.url | type == "string" and endswith("/" + $asset.name))
          ))
        ' "$manifest" >/dev/null 2>&1; then
        emit_fail skills_install_manifest_invalid; return 1
      fi
      declared_assets="$(jq -c '[.skills.bundle, .skills.manifest, .skills.catalog]
        | map({name, sha256})' "$manifest")"
      ;;
    eikona.install_manifest.v1)
      if [[ "$product" != "eikona" ]] || ! jq -e --arg tag "$tag" --arg version "$version" '
          .name == "eikona" and .tag == $tag and
          .cli_version == $version and .skills_bundle_version == $version and
          (.assets.skills_bundle.name | type == "string" and length > 0) and
          (.assets.skills_bundle.sha256 | type == "string" and test("^(sha256:)?[0-9a-fA-F]{64}$"))
        ' "$manifest" >/dev/null 2>&1; then
        emit_fail skills_install_manifest_invalid; return 1
      fi
      declared_assets="$(jq -c '[.assets.skills_bundle | {name, sha256}]' "$manifest")"
      local legacy_name
      for legacy_name in "eikona-skills_${version}.json" "eikona-command-catalog_${version}.json"; do
        if [[ -f "$dir/$legacy_name" ]] \
           || [[ -n "$(checksum_digest_for_asset "$dir/$ck" "$legacy_name")" ]]; then
          declared_assets="$(jq -cn --argjson assets "$declared_assets" --arg name "$legacy_name" \
            '$assets + [{name:$name, sha256:""}]')"
        fi
      done
      ;;
    *)
      emit_fail skills_install_manifest_schema_unsupported \
        "$(jq -cn --arg schema "$schema" '{schema:$schema}')"; return 1
      ;;
  esac

  declared_assets="$(jq -cn --argjson assets "$declared_assets" \
    --arg name "$(basename "$manifest")" '$assets + [{name:$name, sha256:""}]')"

  local rows="" name declared actual checksum_digest
  local -a checksum_matches=()
  local -A seen=()
  while IFS=$'\t' read -r name declared; do
    if [[ ! "$name" =~ ^[A-Za-z0-9._+-]+$ ]] || [[ "$name" != "$(basename "$name")" ]] \
       || denied "$name" || [[ -n "${seen[$name]:-}" ]]; then
      emit_fail skills_asset_name_invalid \
        "$(jq -cn --arg asset "$name" '{asset:$asset}')"; return 1
    fi
    seen[$name]=1
    if [[ ! -f "$dir/$name" ]]; then
      emit_fail skills_asset_missing \
        "$(jq -cn --arg asset "$name" '{asset:$asset}')"; return 1
    fi

    mapfile -t checksum_matches < <(checksum_digest_for_asset "$dir/$ck" "$name")
    if [[ "${#checksum_matches[@]}" -ne 1 ]] \
       || [[ ! "${checksum_matches[0]}" =~ ^[0-9a-f]{64}$ ]]; then
      emit_fail skills_asset_checksum_undeclared \
        "$(jq -cn --arg asset "$name" '{asset:$asset}')"; return 1
    fi
    checksum_digest="${checksum_matches[0]}"
    actual="$(sha256sum "$dir/$name" | cut -d' ' -f1)"
    if [[ "$checksum_digest" != "$actual" ]]; then
      emit_fail skills_asset_checksum_mismatch \
        "$(jq -cn --arg asset "$name" '{asset:$asset}')"; return 1
    fi
    declared="${declared#sha256:}"; declared="${declared,,}"
    if [[ -n "$declared" ]] && { [[ ! "$declared" =~ ^[0-9a-f]{64}$ ]] || [[ "$declared" != "$actual" ]]; }; then
      emit_fail skills_asset_manifest_digest_mismatch \
        "$(jq -cn --arg asset "$name" '{asset:$asset}')"; return 1
    fi
    rows+="$(jq -cn --arg name "$name" --arg sha "sha256:$actual" \
      '{name:$name, sha256:$sha}')"$'\n'
  done < <(jq -r '.[] | [.name, (.sha256 // "")] | @tsv' <<<"$declared_assets")

  local assets
  assets="$(jq -s 'sort_by(.name)' <<<"$rows")"
  jq -cn --arg manifest "$(basename "$manifest")" --argjson assets "$assets" \
    '{status:"verified", manifest:$manifest, assets:$assets}'
}

# Verify independently downloaded upstream assets in <assets_dir> against the
# policy and the (optional, untrusted) producer wake-up hint. On success,
# prints the verified facts JSON (receipt input minus mirrored_assets) and
# returns 0. On failure prints a redacted failure result and returns 1.
verify_release_evidence() { # <product> <src> <strip> <policy_file> <release_json_file> <assets_dir> [hint_json]
  local product="$1" src="$2" strip="$3" policy="$4" rel="$5" dir="$6"
  local hint="${7:-}"
  local tag ver ver_num dist_tag pattern

  if [[ "$(jq -r '.product // ""' "$policy")" != "$product" ]] \
     || [[ "$(jq -r '.source_repo // ""' "$policy")" != "$src" ]]; then
    emit_fail policy_mismatch; return 1
  fi

  tag="$(jq -r '.tag_name // ""' "$rel")"
  ver="${tag#"$strip"}"
  ver_num="${ver#v}"
  dist_tag="$product/$ver"

  if ! reason="$(policy_check_eligibility "$rel" "$policy")"; then
    emit_fail "$reason" "{\"tag\":\"$tag\"}"; return 1
  fi

  # Expand the expected asset matrix ({version} = version without leading v,
  # matching goreleaser {{ .Version }} archive names).
  local -a expected=() required=() allowed=()
  local pat e
  mapfile -t expected < <(jq -r --arg v "$ver_num" '.expected_assets[]? | sub("\\{version\\}"; $v)' "$policy")
  mapfile -t required < <(jq -r '.required_assets[]?' "$policy")
  while IFS= read -r pat; do
    if [[ "$pat" == *'{expected_archive}'* ]]; then
      for e in "${expected[@]}"; do allowed+=("${pat/\{expected_archive\}/$e}"); done
    else
      allowed+=("$pat")
    fi
  done < <(jq -r '.allowed_extra_assets[]?' "$policy")
  if [[ "${#expected[@]}" -eq 0 ]]; then
    emit_fail policy_invalid "{\"policy\":\"empty expected_assets\"}"; return 1
  fi

  # Exact matrix presence; extras must be allowed (per-archive SBOMs); names
  # must not trip the secret-pattern denylist.
  local missing="" f bn known="" unexpected=""
  for f in "${expected[@]}" "${required[@]}"; do
    # checksums files are reported by the dedicated checksums step below
    [[ "$f" == *checksums*.txt ]] && continue
    [[ -e "$dir/$f" ]] || missing+=" $f"
  done
  if [[ -n "$missing" ]]; then
    emit_fail asset_matrix_missing "{\"missing\":\"$missing\"}"; return 1
  fi
  for f in "${expected[@]}" "${required[@]}" "${allowed[@]}"; do
    known+="$f"$'\n'
  done
  for f in "$dir"/*; do
    [[ -e "$f" ]] || continue
    bn="$(basename "$f")"
    if denied "$bn" "$product"; then
      emit_fail denied_asset_name "{\"asset\":\"$bn\"}"; return 1
    fi
    grep -qxF "$bn" <<<"$known" || unexpected+=" $bn"
  done
  if [[ -n "$unexpected" ]]; then
    emit_fail unexpected_asset "{\"unexpected\":\"$unexpected\"}"; return 1
  fi

  # Checksums must pass in full (no --ignore-missing).
  local ck
  ck="$(cd "$dir" && ls -- *checksums*.txt 2>/dev/null | head -n1 || true)"
  if [[ -z "$ck" ]]; then
    emit_fail checksums_missing; return 1
  fi
  if ! (cd "$dir" && sha256sum --check "$ck" >/dev/null 2>&1); then
    emit_fail checksum_mismatch "{\"checksums_file\":\"$ck\"}"; return 1
  fi

  # Record per-asset upstream digests and required SBOMs.
  local assets_json="[" sbom_json="[" first=1 d
  local sbom_required
  sbom_required="$(jq -r '.provenance.sbom_required_per_archive // false' "$policy")"
  for f in "${expected[@]}"; do
    if [[ "$sbom_required" == "true" && ! -e "$dir/$f.spdx.json" ]]; then
      emit_fail sbom_missing "{\"archive\":\"$f\"}"; return 1
    fi
    d="$(sha256sum "$dir/$f" | cut -d' ' -f1)"
    [[ $first -eq 1 ]] || assets_json+=","
    assets_json+="{\"name\":\"$f\",\"sha256\":\"sha256:$d\"}"
    if [[ -e "$dir/$f.spdx.json" ]]; then
      [[ "$sbom_json" == "[" ]] || sbom_json+=","
      sbom_json+="\"$f.spdx.json\""
    fi
    first=0
  done
  assets_json+="]"
  sbom_json+="]"

  # Product install manifests are optional for old releases. Once present,
  # their complete Skills asset set becomes part of the exact mirrored digest
  # set and therefore of the immutable receipt fingerprint.
  local skills_result skills_assets
  if ! skills_result="$(verify_declared_skills_assets "$product" "$tag" "$dir")"; then
    printf '%s\n' "$skills_result"
    return 1
  fi
  skills_assets="$(jq -c '.assets' <<<"$skills_result")"
  assets_json="$(jq -cn --argjson base "$assets_json" --argjson skills "$skills_assets" \
    'reduce ($base + $skills)[] as $item ([];
      if (map(.name) | index($item.name)) != null then . else . + [$item] end)')"

  # Resolve the tag to a commit SHA (annotated tags need the extra hop).
  local revision="none"
  if [[ "$(jq -r '.source_revision_required // false' "$policy")" == "true" ]]; then
    local ref_json sha objtype
    ref_json="$(gh_api "tag_ref:$src:$tag" "repos/$src/git/ref/tags/$tag")" \
      || { emit_fail source_revision_unavailable; return 1; }
    sha="$(jq -r '.object.sha // empty' <<<"$ref_json")"
    objtype="$(jq -r '.object.type // "commit"' <<<"$ref_json")"
    if [[ "$objtype" == "tag" ]]; then
      ref_json="$(gh_api "tag_obj:$src:$sha" "repos/$src/git/tags/$sha")" \
        || { emit_fail source_revision_unavailable; return 1; }
      sha="$(jq -r '.object.sha // empty' <<<"$ref_json")"
    fi
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      emit_fail source_revision_unavailable; return 1
    fi
    revision="$sha"
  fi

  # Wake-up hint correlation: every provided field must match verified facts.
  local policy_channel handoff_sha='null'
  policy_channel="$(jq -r '.channel // "stable"' "$policy")"
  if [[ -n "$hint" ]]; then
    if ! jq -e 'type == "object"' <<<"$hint" >/dev/null 2>&1; then
      emit_fail hint_invalid; return 1
    fi
    local mismatch="" hp ht hr hc hsha
    hp="$(jq -r '.product // empty' <<<"$hint")"
    ht="$(jq -r '.release_tag // empty' <<<"$hint")"
    hr="$(jq -r '.source_revision // empty' <<<"$hint")"
    hc="$(jq -r '.channel // empty' <<<"$hint")"
    [[ "$hp" == "$product" ]] || mismatch="product"
    [[ -z "$ht" || "$ht" == "$tag" ]] || mismatch="release_tag"
    [[ -z "$hr" || "$hr" == "$revision" ]] || mismatch="source_revision"
    [[ -z "$hc" || "$hc" == "$policy_channel" ]] || mismatch="channel"
    if [[ -n "$mismatch" ]]; then
      emit_fail hint_mismatch "{\"field\":\"$mismatch\"}"; return 1
    fi
    hsha="$(jq -r '.handoff_sha256 // empty' <<<"$hint")"
    if [[ -n "$hsha" ]]; then
      handoff_sha="\"sha256:${hsha#sha256:}\""
    fi
  fi

  local pol_rel pol_sha ref_url
  pol_rel="policy/$(basename "$policy")"
  pol_sha="sha256:$(sha256sum "$policy" | cut -d' ' -f1)"
  ref_url="$(jq -r '.html_url // empty' "$rel")"
  [[ -n "$ref_url" ]] || ref_url="https://github.com/$src/releases/tag/$tag"

  jq -n \
    --arg product "$product" --arg channel "$policy_channel" \
    --arg tag "$tag" --arg ref "$ref_url" --arg dist_tag "$dist_tag" \
    --arg rev "$revision" --argjson handoff_sha "$handoff_sha" \
    --arg pol "$pol_rel" --arg polsha "$pol_sha" \
    --arg ckname "$ck" \
    --arg cksha "sha256:$(sha256sum "$dir/$ck" | cut -d' ' -f1)" \
    --argjson nexp "${#expected[@]}" \
    --argjson assets "$assets_json" --argjson sboms "$sbom_json" \
    '{product:$product, channel:$channel,
      upstream_tag:$tag, upstream_release_ref:$ref, dist_tag:$dist_tag,
      source_revision:$rev,
      handoff:{schema_version:"yeisme.product_release_handoff.v1", sha256:$handoff_sha},
      policy:{file:$pol, sha256:$polsha},
      verified:{checksums:{name:$ckname, sha256:$cksha},
                asset_matrix:{expected:$nexp, matched:$nexp},
                upstream_assets:$assets,
                provenance:{sbom_assets:$sboms,
                           attestation_subject:("github-attestation:" + $cksha)}}}'
}

# Re-hash mirrored assets and compare against the verified upstream digests.
# On success prints the mirrored_assets JSON array and returns 0.
verify_mirror_assets() { # <upstream_assets_json> <mirror_dir>
  local expected_json="$1" dir="$2"
  local mirrored="[" ok=0 name d exp
  ok=1
  while IFS= read -r name; do
    if [[ ! -e "$dir/$name" ]]; then
      echo "missing mirrored asset: $name" >&2
      ok=0; continue
    fi
    d="$(sha256sum "$dir/$name" | cut -d' ' -f1)"
    exp="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .sha256' <<<"$expected_json")"
    if [[ "sha256:$d" != "$exp" ]]; then
      echo "mirrored digest mismatch: $name" >&2
      ok=0; continue
    fi
    [[ "$mirrored" == "[" ]] || mirrored+=","
    mirrored+="{\"name\":\"$name\",\"sha256\":\"sha256:$d\"}"
  done < <(jq -r '.[].name' <<<"$expected_json")
  mirrored+="]"
  [[ "$ok" -eq 1 ]] || return 1
  printf '%s\n' "$mirrored"
}

# Idempotency fingerprint over the verified identity: same product/channel/
# tag/revision/asset-digest set (and consumed handoff digest) always hashes
# the same.
receipt_fingerprint() { # <facts_json_with_mirrored>
  printf '%s' "$1" | jq -S -c \
    '{product, channel, upstream_tag, source_revision,
      upstream_assets: .verified.upstream_assets, mirrored_assets,
      handoff_sha256: .handoff.sha256}' \
    | sha256sum | cut -d' ' -f1
}

# Write receipts/<product>/<version>.json from verified facts. Append-only:
# an existing receipt with the same fingerprint is left byte-identical
# (stdout "skip-immutable ...", exit 0); a different fingerprint refuses the
# rewrite (exit 3). distribution_revision counts prior successful receipts.
write_receipt() { # <product> <version> <facts_json_with_mirrored>
  local product="$1" version="$2" facts="$3"
  local rdir rfile fp
  rdir="$(dist_root)/receipts/$product"
  rfile="$rdir/$version.json"
  fp="$(receipt_fingerprint "$facts")"
  if [[ -f "$rfile" ]]; then
    if [[ "$(jq -r '.fingerprint_sha256 // ""' "$rfile")" == "sha256:$fp" ]]; then
      echo "skip-immutable $rfile"
      return 0
    fi
    echo "fingerprint-conflict $rfile" >&2
    return 3
  fi
  mkdir -p "$rdir"
  local rev_count now
  rev_count="$(ls "$rdir"/*.json 2>/dev/null | wc -l)"
  now="${DIST_VERIFY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  jq -n --argjson facts "$facts" --arg fp "sha256:$fp" \
       --argjson rev "$((rev_count + 1))" --arg now "$now" '
    {schema_version:"yeisme.dist_receipt.v1",
     product:$facts.product, channel:$facts.channel, status:"success",
     upstream_tag:$facts.upstream_tag,
     upstream_release_ref:$facts.upstream_release_ref,
     dist_tag:$facts.dist_tag, source_revision:$facts.source_revision,
     handoff:$facts.handoff, policy:$facts.policy, verified:$facts.verified,
     mirrored_assets:$facts.mirrored_assets,
     distribution_revision:$rev, fingerprint_sha256:$fp, produced_at:$now}' > "$rfile"
  echo "wrote $rfile"
}

# Failed, stale, partial or mismatched attempts: redacted diagnostics under
# receipts/<product>/failures/; never referenced by the catalog.
record_failed_attempt() { # <product> <version> <result_json>
  local product="$1" version="$2" result="$3"
  local fdir
  fdir="$(dist_root)/receipts/$product/failures"
  mkdir -p "$fdir"
  jq --arg now "${DIST_VERIFY_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
     '. + {produced_at: $now}' <<<"$result" > "$fdir/$version.json"
  echo "recorded failure $fdir/$version.json" >&2
}

# Attach receipt fields to a product's catalog releases. Fields come from the
# local receipts/ directory (never from GitHub API data) so they survive every
# catalog regeneration. Catalog schema_version stays 1; fields are optional.
catalog_join_receipts() { # <name> <releases_json>
  local name="$1" releases="$2"
  local out="[" first=1 rel ver rp rsha
  while IFS= read -r rel; do
    ver="$(jq -r '.version' <<<"$rel")"
    rp="$(dist_root)/receipts/$name/$ver.json"
    if [[ -f "$rp" ]] \
       && jq -e '.schema_version == "yeisme.dist_receipt.v1" and .status == "success"' "$rp" >/dev/null 2>&1; then
      rsha="sha256:$(sha256sum "$rp" | cut -d' ' -f1)"
      rel="$(jq --arg receipt "receipts/$name/$ver.json" --arg rsha "$rsha" \
                --slurpfile r "$rp" '
        . + {receipt:$receipt, receipt_sha256:$rsha,
             verification:($r[0] | {status:"verified", channel, upstream_tag,
                                    source_revision, handoff_sha256:.handoff.sha256,
                                    distribution_revision})}' <<<"$rel")"
    fi
    if [[ "$first" -eq 1 ]]; then out+="$rel"; first=0; else out+=",$rel"; fi
  done < <(jq -c '.[]' <<<"$releases")
  out+="]"
  printf '%s' "$out"
}

# A hint only applies to the product it names; hints for other products (and
# unparseable hints) are ignored — upstream verification is the authority.
hint_for_product() { # <product>; prints hint JSON when it applies
  local p="$1" hp
  [[ -n "${DIST_HINT_JSON:-}" ]] || return 1
  hp="$(jq -r '.product // empty' <<<"$DIST_HINT_JSON" 2>/dev/null)" || return 1
  [[ -n "$hp" && "$hp" == "$p" ]] || return 1
  printf '%s' "$DIST_HINT_JSON"
}
