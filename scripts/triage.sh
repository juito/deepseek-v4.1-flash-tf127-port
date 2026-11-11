#!/usr/bin/env bash
# Re-runs the patch triage against a TensorFold tag.
# Applies every patch in recipe-tf-fbbc971/zig/patches in filename order (as
# zig/Dockerfile does) to a clean checkout of the pinned upstream tag, and
# writes triage.csv: patch,status,touched_files.
#
# Usage:
#   scripts/triage.sh                 # tag v1.2.7
#   TF_TAG=v1.2.6 scripts/triage.sh
#   scripts/triage.sh --check         # exit 1 if the APPLIES count drifts
set -uo pipefail

TAG="${TF_TAG:-v1.2.7}"
REPO="${TF_REPO:-https://github.com/ashhart/TensorFold.git}"
PATCH_DIR="$(cd "$(dirname "$0")/.." && pwd)/recipe-tf-fbbc971/zig/patches"
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/triage.csv}"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "cloning $REPO at $TAG"
git clone --filter=blob:none --no-checkout "$REPO" "$WORK/up" -q || exit 1
git -C "$WORK/up" checkout -q "$TAG" || exit 1

printf 'patch,status,touched_files\n' > "$OUT"

applies=0
blocked=0
for p in "$PATCH_DIR"/*.patch; do
  b="$(basename "$p")"
  files="$(grep -E '^(\+\+\+|---) ' "$p" \
    | sed -E 's/^(\+\+\+|---) [ab]\///' \
    | grep -v '^/dev/null' \
    | sort -u | tr '\n' ';')"
  if git -C "$WORK/up" apply "$p" 2>/dev/null; then
    st=APPLIES; applies=$((applies + 1))
  else
    st=BLOCKED; blocked=$((blocked + 1))
  fi
  printf '%s,%s,"%s"\n' "$b" "$st" "$files" >> "$OUT"
done

total=$((applies + blocked))
echo "tag $TAG: $total patches, $applies apply, $blocked blocked"
echo "wrote $OUT"

if [ "$CHECK" = 1 ]; then
  expected="${EXPECTED_APPLIES:-1}"
  if [ "$applies" != "$expected" ]; then
    echo "DRIFT: expected $expected applying patches, got $applies" >&2
    exit 1
  fi
  echo "no drift"
fi
