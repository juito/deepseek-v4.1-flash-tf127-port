#!/usr/bin/env bash
# Writes a profile from profiles/ into the recipe's layered settings file,
# scripts/local.sh (which config.sh reads over the environment and .env).
#
# Usage:
#   scripts/profile.sh ttft
#   scripts/profile.sh balanced --force     # overwrite an existing local.sh
#
# Nothing is started. The file is a trial serve, not the live one.
# Apply, then restart the trial and measure:
#   scripts/trial.sh restart          # add --stop-live if dsv41-1017-exl3-tf is up
#   source scripts/trial-env.sh
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
  echo "# Trial serve only. Do not run recipe-tf-fbbc971/start.sh directly."
  echo "# Launch with: scripts/trial.sh restart"
  echo "#   add --stop-live to docker stop dsv41-1017-exl3-tf first (never docker rm)."
  echo "# Live serve, left untouched: container dsv41-1017-exl3-tf,"
  echo "#   image tensorfold-dsv41:exl3-tp2-8a98ae503d85, port 8888."
  echo "# There is no start.sh at the repository root."
  echo "CONTAINER_NAME=dsv41-tf127-trial"
  echo "PORT=8890"
  echo "HOST=127.0.0.1"
  echo "# HOST above is the loopback floor, never 0.0.0.0. scripts/trial.sh"
  echo "# overrides it with this node's Tailscale IP when it has one."
  echo "# IMAGE is tensorfold-dsv41:tf127-trial-<hash>, set by scripts/trial.sh."
  echo "# Do not retag tensorfold-dsv41:exl3-tp2-8a98ae503d85."
  echo
  cat "$src"
} > "$dst"

echo "wrote $dst from $src"
echo
echo "next:"
echo "  scripts/trial.sh restart"
echo "  source scripts/trial-env.sh"
echo "  python3 -I tools/ttft.py --sizes 512,2048,8192,32768,131072 --reps 5 --out runs/ttft-${name%.env}.json --label ${name%.env}"
echo "  python3 -I tools/bench.py --suite prefill,decode --out runs/bench-${name%.env}.json"
echo "  # validation gate: docs/trial-runbook.md (exact.py 31/31 against the current image)"
