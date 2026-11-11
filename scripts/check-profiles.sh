#!/usr/bin/env bash
# Validates every profile in profiles/ against the recipe's own settings.
# A key that config.sh and port.sh do not know would be silently ignored by
# the launcher, which is the worst kind of typo: the setting looks applied.
#
# Usage: scripts/check-profiles.sh
set -uo pipefail
cd "$(dirname "$0")/.."

CONFIG=recipe-tf-fbbc971/scripts/config.sh
PORT=recipe-tf-fbbc971/scripts/port.sh
[ -f "$CONFIG" ] && [ -f "$PORT" ] || { echo "recipe reference tree missing" >&2; exit 1; }

known="$(grep -oE '^[A-Z][A-Z0-9_]*=' "$CONFIG" "$PORT" | sed 's/.*://;s/=//' | sort -u)"
bad=0

for f in profiles/*.env; do
  [ -e "$f" ] || continue
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    key="${key#export }"
    val="${line#*=}"
    val="${val%%#*}"; val="$(echo "$val" | tr -d '[:space:]')"

    # passthrough variables reach both ranks through start.sh's env scan
    case "$key" in
      TENSORFOLD_*|TF_DS_*|TF_FILL_*|TF_SPILL_*|TF_RDMA_*) ;;
      *)
        if ! grep -qx "$key" <<<"$known"; then
          echo "FAIL $f: unknown setting '$key' (not in config.sh/port.sh)" >&2
          bad=1
        fi
        ;;
    esac

    case "$key" in
      HOST)
        case "$val" in
          0.0.0.0|::|"[::]"|"*")
            echo "FAIL $f: HOST=$val is refused (never 0.0.0.0)" >&2
            bad=1
            ;;
        esac
        ;;
      PORT)
        case "$val" in
          8888|18004)
            echo "FAIL $f: PORT=$val is the live serve or the Mac tunnel" >&2
            bad=1
            ;;
        esac
        ;;
      CONTAINER_NAME)
        if [ "$val" = "dsv41-1017-exl3-tf" ]; then
          echo "FAIL $f: CONTAINER_NAME is the live serve" >&2
          bad=1
        fi
        ;;
      IMAGE)
        case "$val" in
          *exl3-tp2-8a98ae503d85*)
            echo "FAIL $f: IMAGE would retag the live image" >&2
            bad=1
            ;;
        esac
        ;;
      CONTEXT|POOL)
        if [ -n "$val" ]; then
          if ! [[ "$val" =~ ^[0-9]+$ ]]; then
            echo "FAIL $f: $key='$val' is not an integer" >&2; bad=1
          elif (( val % 4096 != 0 )); then
            echo "FAIL $f: $key=$val is off the 4096 grid (an off-grid cap gives the indexer a tile count the kit has no variant for)" >&2; bad=1
          fi
        fi
        ;;
      MAX_TOKENS|PARALLEL|GRAPH_CAP)
        [[ "$val" =~ ^[0-9]+$ ]] || { echo "FAIL $f: $key='$val' is not an integer" >&2; bad=1; }
        ;;
      ROUND_ROWS)
        case "$val" in
          ''|16) ;;
          32) echo "WARN $f: ROUND_ROWS=32 needs the opt-in kernel build (-Dport_kernels); re-run tools/exact.py" ;;
          *) echo "FAIL $f: ROUND_ROWS='$val' is not 16 or 32" >&2; bad=1 ;;
        esac
        ;;
    esac
  done < "$f"

  # POOL may not be smaller than CONTEXT. CONTEXT is capped at the live
  # window: 524288. A reported run at 655360 killed a 464K-token turn.
  ctx="$(grep -E '^CONTEXT=' "$f" | head -1 | cut -d= -f2 | sed 's/#.*//' | tr -d '[:space:]')"
  pool="$(grep -E '^POOL=' "$f" | head -1 | cut -d= -f2 | sed 's/#.*//' | tr -d '[:space:]')"
  if [ -z "$ctx" ]; then
    echo "FAIL $f: CONTEXT is unset (the recipe default is 1048576, above the 524288 cap)" >&2
    bad=1
  elif (( ctx > 524288 )); then
    echo "FAIL $f: CONTEXT=$ctx exceeds 524288 (live serve; 655360 killed a 464K-token turn)" >&2
    bad=1
  fi
  if [ -n "$pool" ] && [ -n "$ctx" ] && (( pool < ctx )); then
    echo "FAIL $f: POOL=$pool is smaller than CONTEXT=$ctx" >&2; bad=1
  fi

  # TF_FILL_CHUNKS turns the 0005 interleave off. A profile must not set both.
  fill="$(grep -E '^TF_FILL_CHUNKS=' "$f" | head -1 | cut -d= -f2 | sed 's/#.*//' | tr -d '[:space:]')"
  inter="$(grep -E '^PREFILL_INTERLEAVE_MS=' "$f" | head -1 | cut -d= -f2 | sed 's/#.*//' | tr -d '[:space:]')"
  if [ -n "$fill" ] && [ "$fill" != 0 ] && [ "$inter" != 0 ]; then
    echo "FAIL $f: TF_FILL_CHUNKS=$fill and PREFILL_INTERLEAVE_MS=${inter:-<unset, recipe default 250>} are mutually exclusive. Use ttft-fill (chunks, interleave 0) or ttft-interleave (interleave 250, no TF_FILL_CHUNKS)." >&2
    bad=1
  fi
done

if [ "$bad" = 0 ]; then
  echo "profiles OK: $(ls profiles/*.env | wc -l | tr -d ' ') profile(s)"
fi
exit "$bad"
