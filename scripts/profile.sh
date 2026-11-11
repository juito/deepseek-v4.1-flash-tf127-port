#!/usr/bin/env bash
# Writes a profile from profiles/ into the recipe's layered settings file,
# scripts/local.sh (which config.sh reads over the environment and .env).
#
# Usage:
#   scripts/profile.sh ttft
#   scripts/profile.sh balanced --force     # overwrite an existing local.sh
#
# Nothing is started. Apply, then restart and measure:
#   ./start.sh restart
#   python3 -I tools/ttft.py --out runs/ttft-after.json
set -uo pipefail
cd "$(dirname "$0")/.."

name="${1:-}"
force="${2:-}"
if [ -z "$name" ]; then
  echo "usage: scripts/profile.sh <$(ls profiles/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env//' | tr '\n' '|' | sed 's/|$//')>" >&2
  exit 2
fi

src="profiles/${name%.env}.env"
[ -f "$src" ] || { echo "no such profile: $src" >&2; exit 2; }

scripts/check-profiles.sh >/dev/null || { echo "profiles failed validation; run scripts/check-profiles.sh" >&2; exit 1; }

dst="recipe-tf-fbbc971/scripts/local.sh"
if [ -f "$dst" ] && [ "$force" != "--force" ]; then
  echo "$dst exists; pass --force to overwrite (back it up first)" >&2
  exit 1
fi

{
  echo "# Written by scripts/profile.sh from $src"
  echo "# Layered settings: config.sh reads this over the environment."
  echo "# Every value is scheduling; the 2.9 bpw EAQ v1 pack is unchanged."
  echo
  cat "$src"
} > "$dst"

echo "wrote $dst from $src"
echo
echo "next:"
echo "  ./start.sh restart"
echo "  python3 -I tools/ttft.py --sizes 512,2048,8192,32768,131072 --reps 5 --out runs/ttft-${name%.env}.json --label ${name%.env}"
echo "  python3 -I tools/bench.py --suite prefill,decode --out runs/bench-${name%.env}.json"
echo "  python3 -I tools/exact.py --compare runs/exact-baseline.json   # replies must not move"
