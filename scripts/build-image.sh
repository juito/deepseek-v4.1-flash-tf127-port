#!/usr/bin/env bash
# Build tensorfold-dsv41:tf127-trial-<hash> for aarch64 GB10.
# Run on a Spark after scripts/fetch-engine.sh. Refuses the live tag.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/trial-guard.sh

if [[ "$(uname -m)" != "aarch64" && "${FORCE_BUILD:-0}" != 1 ]]; then
  echo "build-image: this host is $(uname -m). The GB10 image builds on aarch64. Set FORCE_BUILD=1 only to try anyway." >&2
  exit 1
fi
[[ -d engine/src/zig ]] || { echo "build-image: run scripts/fetch-engine.sh first" >&2; exit 1; }
hash="$(scripts/port-hash.sh)"
IMAGE="${TRIAL_IMAGE_PREFIX}${hash}"
trial_refuse_retag "$IMAGE"
echo "build-image: docker build -t $IMAGE"
if [[ "${DRY_RUN:-0}" == 1 ]]; then
  echo "build-image: DRY_RUN; not building"
  exit 0
fi
docker build -f docker/Dockerfile.gb10 -t "$IMAGE" .
echo "build-image: $IMAGE"
