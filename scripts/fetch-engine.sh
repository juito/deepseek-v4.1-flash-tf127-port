#!/usr/bin/env bash
# Clone TensorFold v1.2.7 and apply engine/patches. The tree lands in engine/src,
# which is gitignored. Re-run after the pin or a patch changes.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/trial-guard.sh

PIN="$(tr -d '[:space:]' < engine/PIN)"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]] || { echo "fetch-engine: engine/PIN is not a 40-char commit" >&2; exit 1; }
DEST="${ENGINE_SRC:-engine/src}"
REPO="${TF_REPO:-https://github.com/ashhart/TensorFold.git}"

if [[ ! -d "$DEST/.git" ]]; then
  git clone --branch v1.2.7 --depth 1 "$REPO" "$DEST"
fi
git -C "$DEST" fetch --depth 1 origin "$PIN"
git -C "$DEST" reset --hard "$PIN"
git -C "$DEST" clean -fd -e zig-out -e .zig-cache
# Our overlay includes the 0029 budget default. Do not also apply the recipe series.
git -C "$DEST" apply --check "${PWD}/engine/patches/"*.patch
git -C "$DEST" apply "${PWD}/engine/patches/"*.patch
echo "fetch-engine: $DEST at $(git -C "$DEST" rev-parse --short HEAD), patches applied"
echo "fetch-engine: image tag ${TRIAL_IMAGE_PREFIX}$(scripts/port-hash.sh)"
