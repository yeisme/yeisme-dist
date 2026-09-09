#!/usr/bin/env bash
# rc-channel.sh — lifecycle wrapper for the Scaena RC temporary Tap/Bucket
# (scaena-v0-4-package-channels-v1 §4.1).
#
#   scripts/rc-channel.sh create  --tag scaena/v0.4.0-rc.1 --release <file> [--root <dir>]
#   scripts/rc-channel.sh destroy --root <channel-root>
#
# create renders the six RC manifests (three Homebrew Casks under Tap/Casks,
# three Scoop manifests under Bucket/bucket) into a throwaway channel root
# and snapshots the stable generated surface. destroy proves the stable
# surface is still byte-identical and then deletes the temporary channel —
# run it with `if: always()` in CI so the channel cannot outlive the job.
#
# The temporary channel never advances the stable catalog, success receipts
# or public manifests; it exists only for pre-release smoke evidence.
# Mirrored-bytes and receipts are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD=""
RC_TAG=""
RC_RELEASE=""
ROOT_ARG=""

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    create|destroy) CMD="$1"; shift ;;
    --tag) RC_TAG="$2"; shift 2 ;;
    --release) RC_RELEASE="$2"; shift 2 ;;
    --root) ROOT_ARG="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$CMD" ]] || usage
command -v jq >/dev/null || { echo 'jq required' >&2; exit 2; }

# Digest over the stable generated surface (manifests, policies, receipts,
# catalog, product manifest list). destroy recomputes it and refuses to
# delete the channel when the stable surface changed while the RC channel
# existed.
stable_state_sig() {
  {
    ( find "$ROOT/Casks" "$ROOT/bucket" "$ROOT/policy" "$ROOT/receipts" \
        -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum ) || true
    [[ -f "$ROOT/catalog.json" ]] && sha256sum "$ROOT/catalog.json"
    [[ -f "$ROOT/products.txt" ]] && sha256sum "$ROOT/products.txt"
  } | sha256sum | cut -d' ' -f1
}

case "$CMD" in
  create)
    [[ -n "$RC_TAG" && -n "$RC_RELEASE" ]] || usage
    channel_root="$(mktemp -d "${ROOT_ARG:-${TMPDIR:-/tmp}}/scaena-rc-channel.XXXXXXXX")"
    stable_state_sig > "$channel_root/.stable-state.sig"
    # stdout stays machine-clean: only the channel root path.
    if ! "$ROOT/scripts/generate-package-manifests.sh" \
         --rc-tag "$RC_TAG" --rc-release "$RC_RELEASE" --rc-root "$channel_root" 1>&2; then
      rm -rf "$channel_root"
      echo "rc channel create failed; temporary channel destroyed" >&2
      exit 1
    fi
    for f in scaena scaena-api scaena-production-worker; do
      if [[ ! -s "$channel_root/Tap/Casks/$f.rb" || ! -s "$channel_root/Bucket/bucket/$f.json" ]]; then
        rm -rf "$channel_root"
        echo "rc channel incomplete: $f" >&2
        exit 1
      fi
    done
    echo "$channel_root"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "root=$channel_root" >> "$GITHUB_OUTPUT"
    fi
    ;;
  destroy)
    [[ -n "$ROOT_ARG" ]] || usage
    channel_root="$ROOT_ARG"
    if [[ ! -f "$channel_root/.stable-state.sig" ]]; then
      echo "not an rc channel root (missing .stable-state.sig): $channel_root" >&2
      exit 2
    fi
    expected="$(cat "$channel_root/.stable-state.sig")"
    actual="$(stable_state_sig)"
    if [[ "$actual" != "$expected" ]]; then
      echo "stable generated surface changed while the rc channel existed; investigate before deleting evidence" >&2
      exit 1
    fi
    rm -rf "$channel_root"
    echo "destroyed rc channel $channel_root (stable surface verified byte-identical)"
    ;;
esac
