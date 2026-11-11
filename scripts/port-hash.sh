#!/usr/bin/env bash
# 12 hex chars over the upstream pin and this repo's overlay patches.
# The trial image tag is tensorfold-dsv41:tf127-trial-<this>.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f engine/PIN ]] || { echo "port-hash: engine/PIN missing" >&2; exit 1; }
{
  cat engine/PIN
  cat engine/patches/*.patch
} | sha256sum | cut -c1-12
