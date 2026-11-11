#!/usr/bin/env bash
# Plans how to spend the RAM left on a Spark after the weights load.
#
# KV cost: ~1.0 GiB a rank per 1,048,576 positions replicated, ~0.55 GiB with
# KV_SHARD=1 (measured at 2,101,248 positions: 1,783 MiB against 1,062 MiB).
# Reserve: MEMGUARD_GIB (2.5) plus ~1.0 GiB slack for the head's other work.
#
# Usage: scripts/memory-plan.sh [FREE_GIB]
# Nov 11 ~2 PM PST, live Sparks: SparkOne MemAvailable 6.96-6.98 GiB, of which
# 1.23 GiB is truly free (the rest is Engram page cache and margin). Headroom
# is about 2-3 GiB. SparkTwo MemAvailable 8.59 GiB. Do not spend that on a
# larger POOL or on more bits. The v1.2.7 trial caps TF_DSV41_SESSION_RESIDENT_GIB
# at 3 (fallback 2) and leaves the 12.2 GiB engine reserve alone.
# The table below is the old pool math. It treats the number you pass as
# spendable. MemAvailable on Nov 11 was not spendable.
set -uo pipefail

free="${1:-6.97}"
if [ "$#" -eq 0 ]; then
  echo "note: defaulting to SparkOne's Nov 11 MemAvailable, 6.97 GiB. Only 1.23 GiB of that was truly free. Pass the number you read." >&2
fi
reserve=3.5

awk -v free="$free" -v reserve="$reserve" '
BEGIN {
  printf "free %.2f GiB | reserve %.2f GiB (memguard 2.5 + 1.0 slack) | spendable %.2f GiB\n\n", free, reserve, free - reserve
  spend = free - reserve
  printf "%-12s %-12s %-12s %-12s %s\n", "POOL", "replicated", "sharded", "headroom", "verdict"
  n = split("1048576 2097152 4194304 6291456 8388608", pools, " ")
  best = 0; ceiling = 0
  for (i = 1; i <= n; i++) {
    p = pools[i]
    u = p / 1048576 * 1.0
    s = p / 1048576 * 0.55
    head = free - u
    verdict = ""
    if (u > spend) verdict = "over budget"
    else if (head < 2.5) verdict = "below memguard floor"
    else if (p <= 4194304) { verdict = "fits"; ceiling = p; if (p <= 2097152) best = p }
    else verdict = "tight"
    printf "%-12d %-12.2f %-12.2f %-12.2f %s\n", p, u, s, head, verdict
  }
  printf "\n"
  printf "trial budget: leave POOL unset. Cap TF_DSV41_SESSION_RESIDENT_GIB at 3 on both ranks (2 if the MemAvailable trough is under 4 GiB).\n"
  printf "  SparkOne headroom is about 2-3 GiB. Truly free on Nov 11 was 1.23 GiB; the rest of MemAvailable is Engram page cache.\n"
  printf "  Memguard still kills at 2.5 GiB for 4 s (hard 1 GiB). Do not lower TENSORFOLD_MEMORY_RESERVE_GIB below 12.2.\n"
  if (best > 0) {
    printf "old pool math would have said POOL=%d (%.2f GiB). That spends the page cache. The v1.2.7 profiles do not set it.\n", best, best / 1048576 * 1.0
  }
}'
