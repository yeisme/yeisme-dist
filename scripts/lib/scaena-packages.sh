#!/usr/bin/env bash
# Shared static Scaena package descriptors (scaena-v0-4-package-channels-v1
# design §1). Both install.sh and scripts/generate-package-manifests.sh source
# this file so the two surfaces cannot drift. Catalog identity stays one
# product ("scaena", schema 1); the public package names below are bounded
# aliases resolving to archive prefixes of the same Release.
#
# Do not extend this table to other products without a new OpenSpec change
# (single multi-package product by design).

# scaena_package_product <requested>   -> catalog product name (or empty)
scaena_package_product() {
  case "$1" in
    scaena|scaena-api|scaena-production-worker) echo scaena ;;
    *) return 1 ;;
  esac
}

# scaena_package_prefix <requested>    -> archive name prefix with full-boundary
# semantics ("scaena_" never matches "scaena-api_").
scaena_package_prefix() {
  case "$1" in
    scaena) echo "scaena_" ;;
    scaena-api) echo "scaena-api_" ;;
    scaena-production-worker) echo "scaena-production-worker_" ;;
    *) return 1 ;;
  esac
}

# scaena_package_binary <requested>    -> installed binary name
scaena_package_binary() {
  case "$1" in
    scaena|scaena-api|scaena-production-worker) echo "$1" ;;
    *) return 1 ;;
  esac
}

# scaena_package_defaults -> the three public package names
scaena_package_defaults() {
  printf '%s\n' scaena scaena-api scaena-production-worker
}
