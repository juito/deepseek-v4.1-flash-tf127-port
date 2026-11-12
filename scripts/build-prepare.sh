#!/usr/bin/env bash
# One command on a Spark: fetch TensorFold v1.2.7, build the trial image, pack Engram.
# Does not start a server, does not bind a port, does not stop or retag the live serve.
#
#   MODEL=/path/to/eaq-v1-45ee5d0f \
#   ENGRAM_RELEASE=/path/to/DeepSeek-V4.1-Flash-1017-snapshot \
#   TF_DSV41_ASSETS=/nvme/dsv41-assets \
#   scripts/build-prepare.sh
#
# ENGRAM_RELEASE is the release checkpoint that holds the FP8 Engram tables
# (shards model-00047-of-00048 and model-00048-of-00048), not the EXL3 pack.
# The packed files land in ~/.cache/dsv41-tensorfold/engram-1bae0e10/ as
# engram-l{1,14}-r{0,1}of2.bin. Both rank names are hardlinks of the full table:
# the header does not store the rank, and each rank's hash indexes the whole table.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/trial-guard.sh

MODEL="${MODEL:?set MODEL to the EAQ v1 directory (45ee5d0f)}"
ENGRAM_RELEASE="${ENGRAM_RELEASE:?set ENGRAM_RELEASE to the release snapshot with the FP8 Engram shards}"
ASSETS="${TF_DSV41_ASSETS:?set TF_DSV41_ASSETS to the prepared-asset directory}"
ENGRAM_OUT="${ENGRAM_CACHE:-$HOME/.cache/dsv41-tensorfold/engram-1bae0e10}"
LAYERS="${ENGRAM_LAYERS:-1,14}"

[[ -d "$MODEL" ]] || { echo "build-prepare: MODEL=$MODEL is not a directory" >&2; exit 1; }
[[ -d "$ENGRAM_RELEASE" ]] || { echo "build-prepare: ENGRAM_RELEASE=$ENGRAM_RELEASE is not a directory" >&2; exit 1; }
mkdir -p "$ASSETS" "$ENGRAM_OUT"

scripts/fetch-engine.sh
scripts/build-image.sh

hash="$(scripts/port-hash.sh)"
IMAGE="${TRIAL_IMAGE_PREFIX}${hash}"
trial_refuse_retag "$IMAGE"

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  echo "build-prepare: DRY_RUN image=$IMAGE engram=$ENGRAM_OUT assets=$ASSETS dip=2.5"
  echo "build-prepare: next: scripts/engine-trial.sh --stop-live --profile profiles/tf127-speed.env restart"
  exit 0
fi

echo "build-prepare: packing Engram layers $LAYERS into $ENGRAM_OUT"
docker run --rm --network none --entrypoint tf-dsv41-engram-pack \
  -v "${ENGRAM_RELEASE}:${ENGRAM_RELEASE}:ro" \
  -v "${ENGRAM_OUT}:${ENGRAM_OUT}" \
  "$IMAGE" pack "$ENGRAM_RELEASE" "$ENGRAM_OUT" --layers "$LAYERS"

shopt -s nullglob
packed=("$ENGRAM_OUT"/engram-l*-r0of1.bin)
[[ ${#packed[@]} -gt 0 ]] || { echo "build-prepare: pack wrote no engram-l*-r0of1.bin" >&2; exit 1; }
for src in "${packed[@]}"; do
  base="$(basename "$src")"
  layer="${base#engram-l}"
  layer="${layer%-r0of1.bin}"
  ln -f "$src" "$ENGRAM_OUT/engram-l${layer}-r0of2.bin"
  ln -f "$src" "$ENGRAM_OUT/engram-l${layer}-r1of2.bin"
  echo "build-prepare: $base -> engram-l${layer}-r0of2.bin and engram-l${layer}-r1of2.bin"
done

if [[ -f "$MODEL/tokenizer.json" && -f "$MODEL/config.json" ]]; then
  docker run --rm --network none --entrypoint tf-dsv41-token-map \
    -v "${MODEL}:${MODEL}:ro" \
    -v "${ASSETS}:${ASSETS}" \
    "$IMAGE" \
    --tokenizer "$MODEL/tokenizer.json" \
    --config "$MODEL/config.json" \
    --output "$ASSETS/engram-token-map.bin"
else
  echo "build-prepare: $MODEL has no tokenizer.json or config.json; token map not written" >&2
fi

if [[ ! -f "$ASSETS/rope.bin" || ! -d "$ASSETS/aot" ]]; then
  echo "build-prepare: $ASSETS still needs rope.bin and aot/ from the external Triton reference tools (sm_121)." >&2
  echo "build-prepare: serving reads \$TF_DSV41_ASSETS/{rope.bin,engram-token-map.bin,aot/}." >&2
fi

echo "build-prepare: image $IMAGE"
echo "build-prepare: TF_DSV41_ENGRAM_DIR=$ENGRAM_OUT"
echo "build-prepare: TF_DSV41_SERVE_DIP_GIB=2.5 (engine-trial.sh sets this when the profile does not)"
echo "build-prepare: rank 0, after rope.bin and aot/ exist:"
echo "  MODEL=$MODEL TF_DSV41_ASSETS=$ASSETS TF_DSV41_ENGRAM_DIR=$ENGRAM_OUT \\"
echo "    scripts/engine-trial.sh --stop-live --profile profiles/tf127-speed.env restart"
echo "build-prepare: rank 1, same profile, RANK_OVERRIDE=1. The script binds the Tailscale address, never 0.0.0.0."
