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

    # passthrough variables reach both ranks. TF_DSV41_* is the v1.2.7 family.
    # The recipe launcher only forwards names it scans; scripts/engine-trial.sh
    # forwards TF_DSV41_* itself. A fork profile's TF_DS_* names are not v1.2.7 levers.
    case "$key" in
      TENSORFOLD_*|TF_DS_*|TF_FILL_*|TF_SPILL_*|TF_RDMA_*|TF_DSV41_*) ;;
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

  kv() {
    grep -E "^$1=" "$f" | head -1 | cut -d= -f2- | sed 's/#.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
  }
  prefill="$(kv TF_DSV41_PREFILL)"
  resident="$(kv TF_DSV41_SESSION_RESIDENT_GIB)"
  disk="$(kv TF_DSV41_SESSION_DISK)"
  disk_gib="$(kv TF_DSV41_SESSION_DISK_GIB)"
  reserve="$(kv TENSORFOLD_MEMORY_RESERVE_GIB)"
  eaq="$(kv EAQ_V1_1)"
  ablit="$(kv ABLIT)"
  pf4k="$(kv TF_DSV41_PF_4K)"
  pf4k_ok="$(kv TF_DSV41_PF_4K_MEMORY_OK)"
  gm="$(kv TF_DSV41_GM_V2)"
  pieces="$(kv TF_DSV41_PREFILL_PIECES)"
  own="$(kv TF_DSV41_OWN_PREFILL)"
  tail="$(kv TF_DSV41_PROMPT_TAIL)"
  floor_flag="$(kv TF_DSV41_PIECES_FLOOR)"
  dsv_ctx="$(kv TF_DSV41_CONTEXT)"
  par="$(kv PARALLEL)"
  base="$(basename "$f")"

  if [ "$eaq" = 1 ]; then
    echo "FAIL $f: EAQ_V1_1=1 changes bits. Stay on EAQ v1 45ee5d0f." >&2
    bad=1
  fi
  if [ "$ablit" = 1 ]; then
    echo "FAIL $f: ABLIT=1 is refused." >&2
    bad=1
  fi
  if [ -n "$reserve" ]; then
    if ! awk -v v="$reserve" 'BEGIN{exit !(v+0 >= 12.2)}'; then
      echo "FAIL $f: TENSORFOLD_MEMORY_RESERVE_GIB=$reserve is below 12.2. Leave the engine reserve alone." >&2
      bad=1
    fi
  fi
  if [ -n "$resident" ]; then
    if ! awk -v v="$resident" 'BEGIN{exit !(v+0 > 0 && v+0 <= 3)}'; then
      echo "FAIL $f: TF_DSV41_SESSION_RESIDENT_GIB=$resident must be above 0 and at most 3. Unset is unlimited." >&2
      bad=1
    fi
  fi
  if [ "$prefill" = replay ]; then
    if [ -z "$resident" ]; then
      echo "FAIL $f: TF_DSV41_PREFILL=replay with TF_DSV41_SESSION_RESIDENT_GIB unset is unlimited. Set 3, or 2 when the trough is under 4 GiB." >&2
      bad=1
    fi
    if [ -z "$disk" ]; then
      echo "FAIL $f: TF_DSV41_PREFILL=replay needs TF_DSV41_SESSION_DISK on local NVMe." >&2
      bad=1
    fi
    if [ "$disk_gib" != 64 ]; then
      echo "FAIL $f: TF_DSV41_SESSION_DISK_GIB must be 64 (the budget). Got '${disk_gib:-unset}'." >&2
      bad=1
    fi
  fi
  if [ "$pf4k" = 1 ]; then
    if [ "$pf4k_ok" != 1 ] || [ "$prefill" != replay ] || { [ "$gm" != 1 ] && [ "$gm" != split ]; }; then
      echo "FAIL $f: TF_DSV41_PF_4K=1 needs TF_DSV41_PF_4K_MEMORY_OK=1, TF_DSV41_PREFILL=replay, and TF_DSV41_GM_V2=1 or split." >&2
      bad=1
    fi
  fi
  if [ "$pieces" = 1 ]; then
    if [ "$own" != 1 ] || [ "$tail" != verify ]; then
      echo "FAIL $f: TF_DSV41_PREFILL_PIECES=1 needs TF_DSV41_OWN_PREFILL=1 and TF_DSV41_PROMPT_TAIL=verify, or prompts run whole." >&2
      bad=1
    fi
  fi
  if [ "$floor_flag" = 1 ]; then
    echo "FAIL $f: TF_DSV41_PIECES_FLOOR=1 turns on a hard floor of 4 GiB. SparkOne's headroom is 2-3 GiB." >&2
    bad=1
  fi
  if [ -n "$dsv_ctx" ] && [ -n "$ctx" ] && [ "$dsv_ctx" != "$ctx" ]; then
    echo "FAIL $f: TF_DSV41_CONTEXT=$dsv_ctx disagrees with CONTEXT=$ctx." >&2
    bad=1
  fi
  case "$base" in
    tf127-*)
      if [ "$ctx" != 524288 ]; then
        echo "FAIL $f: v1.2.7 profiles keep CONTEXT=524288." >&2
        bad=1
      fi
      if [ "$par" != 4 ]; then
        echo "FAIL $f: v1.2.7 profiles keep PARALLEL=4." >&2
        bad=1
      fi
      if [ -n "$pool" ]; then
        echo "FAIL $f: v1.2.7 profiles leave POOL unset. MemAvailable on SparkOne is mostly Engram page cache." >&2
        bad=1
      fi
      if [ -z "$resident" ]; then
        echo "FAIL $f: v1.2.7 profiles set TF_DSV41_SESSION_RESIDENT_GIB. Unset is unlimited." >&2
        bad=1
      fi
      if [ "$dsv_ctx" != 524288 ]; then
        echo "FAIL $f: v1.2.7 profiles set TF_DSV41_CONTEXT=524288. The engine default slot is 4096." >&2
        bad=1
      fi
      ;;
  esac
done

if [ "$bad" = 0 ]; then
  echo "profiles OK: $(ls profiles/*.env | wc -l | tr -d ' ') profile(s)"
fi
exit "$bad"
