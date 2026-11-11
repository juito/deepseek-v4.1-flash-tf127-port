#!/usr/bin/env bash
# Plans how to spend the RAM left on a Spark after the weights load.
#
# KV cost: ~1.0 GiB a rank per 1,048,576 positions replicated, ~0.55 GiB with
# KV_SHARD=1 (measured at 2,101,248 positions: 1,783 MiB against 1,062 MiB).
# Reserve: MEMGUARD_GIB (2.5) plus ~1.0 GiB slack for the head's other work.
#
# Usage: scripts/memory-plan.sh [FREE_GIB]
# The default 9 is an unmeasured assumption. The recipe records about
# 6.2-6.5 GiB MemAvailable after the weights load (docs/memory-and-safety.md,
# CHANGELOG). Pass the number you actually read.
set -uo pipefail

free="${1:-9}"
if [ "$#" -eq 0 ]; then
  echo "note: 9 GiB is an unmeasured assumption. The recipe records ~6.2-6.5 GiB MemAvailable after load. Pass the number you measure." >&2
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
  if (best > 0) {
    printf "recommended: POOL=%d with KV_SHARD=0 (%.2f GiB, %.2f GiB headroom left)\n", best, best / 1048576 * 1.0, free - best / 1048576 * 1.0
    printf "  the documented case: four concurrent 500K-token prompts\n"
    if (ceiling > best)
      printf "  ceiling if you routinely hold >4 long conversations: POOL=%d (%.2f GiB, %.2f GiB headroom)\n", ceiling, ceiling / 1048576 * 1.0, free - ceiling / 1048576 * 1.0
    printf "  beyond ~4M the typical working set is already resident; extra pool is given-away headroom\n"
  } else {
    printf "recommended: keep POOL empty (the window only) and leave the RAM as Engram page cache\n"
  }
  printf "KV sharding would halve the KV cost but costs 1-4%% decode; with this much spare you do not need it\n"
}'
