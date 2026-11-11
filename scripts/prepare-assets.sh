#!/usr/bin/env bash
# Host-side asset tools for v1.2.7. Upstream removed tf-dsv41-rank-cache,
# make_token_map, make_rope and build_kit. The replacements are below.
# Rope and the Triton AOT images still come from the external reference tools.
# Run this on the Spark, from a tree produced by scripts/fetch-engine.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${ENGINE_SRC:-engine/src}"
MODEL="${MODEL:?set MODEL to the EAQ v1 directory (45ee5d0f)}"
ASSETS="${TF_DSV41_ASSETS:?set TF_DSV41_ASSETS to the prepared-asset directory}"
mkdir -p "$ASSETS"
cd "$SRC"
zig build dsv41-assets
zig build test-dsv41-assets-host test-dsv41-token-map
./zig-out/bin/tf-dsv41-token-map \
  --tokenizer "$MODEL/tokenizer.json" \
  --config "$MODEL/config.json" \
  --output "$ASSETS/engram-token-map.bin"
if [[ -f "$ASSETS/sigs.json" ]]; then
  ./zig-out/bin/tf-dsv41-assets aot-needs "$ASSETS/sigs.json" "$ASSETS/needs.json"
else
  echo "prepare-assets: $ASSETS/sigs.json is not here yet." >&2
  echo "prepare-assets: the external Triton reference tools write sigs.json, compile needs.json for sm_121, and write aot/." >&2
fi
if [[ ! -f "$ASSETS/rope.bin" ]]; then
  echo "prepare-assets: rope.bin is missing. The reference RoPE generator must cover CONTEXT+2048 rows." >&2
fi
echo "prepare-assets: runtime reads \$TF_DSV41_ASSETS/{rope.bin,engram-token-map.bin,aot/}"
echo "prepare-assets: a prepared-folder rebuild on an engine upgrade is the 1.2.6 #2325 cost (~10.5 min first boot at TP=2, ~5 min later). That is not an EAQ pack swap."
