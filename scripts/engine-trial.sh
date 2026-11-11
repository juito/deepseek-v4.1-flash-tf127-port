#!/usr/bin/env bash
# Start the v1.2.7 trial container. This does not call recipe start.sh.
#
#   scripts/engine-trial.sh --profile profiles/tf127-replay.env --guard-only
#   scripts/engine-trial.sh --stop-live --profile profiles/tf127-replay.env restart
#
# Rank 0 is SparkOne. Rank 1 is SparkTwo. Both get the same TF_DSV41_* values.
# TF_DSV41_SESSION_RESIDENT_GIB must match or both ranks refuse.
# The process binds --host to this node's Tailscale IP, or 127.0.0.1. Never 0.0.0.0.
# --context and TF_DSV41_CONTEXT come from CONTEXT (524288). PARALLEL is --parallel.
# TF_DSV41_SLOTS is the engine's live slot count (default 1). It must equal PARALLEL.
# The family Options struct has no lanes field, so --parallel alone does not raise it.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/trial-guard.sh

PROFILE=""
STOP_LIVE=0
GUARD_ONLY=0
MODE=restart
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-live) STOP_LIVE=1; shift ;;
    --guard-only) GUARD_ONLY=1; shift ;;
    --profile) PROFILE="$2"; shift 2 ;;
    start|restart) MODE=restart; shift ;;
    stop) MODE=stop; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "engine-trial: unknown argument $1" >&2; exit 2 ;;
  esac
done
export STOP_LIVE

if [[ -n "$PROFILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$PROFILE"
  set +a
fi

export CONTAINER_NAME="${CONTAINER_NAME:-$TRIAL_CONTAINER}"
export PORT="${PORT:-$TRIAL_PORT}"
export CONTEXT="${CONTEXT:-524288}"
export PARALLEL="${PARALLEL:-4}"
HOST="$(trial_pick_host)"
export HOST
export TF_DSV41_CONTEXT="${TF_DSV41_CONTEXT:-$CONTEXT}"

if [[ "$CONTEXT" -gt "$MAX_CONTEXT" || "$TF_DSV41_CONTEXT" -gt "$MAX_CONTEXT" ]]; then
  echo "engine-trial: CONTEXT=$CONTEXT is above $MAX_CONTEXT" >&2
  exit 1
fi
if [[ -n "${TENSORFOLD_MEMORY_RESERVE_GIB:-}" ]]; then
  awk -v v="$TENSORFOLD_MEMORY_RESERVE_GIB" 'BEGIN{exit !(v+0 >= 12.2)}' \
    || { echo "engine-trial: TENSORFOLD_MEMORY_RESERVE_GIB is below 12.2" >&2; exit 1; }
fi
if [[ "${TF_DSV41_PREFILL:-}" == replay && -z "${TF_DSV41_SESSION_RESIDENT_GIB:-}" ]]; then
  echo "engine-trial: replay with TF_DSV41_SESSION_RESIDENT_GIB unset is unlimited. Set 3, or 2 under a 4 GiB trough." >&2
  exit 1
fi
if [[ "${TF_DSV41_SLOTS:-}" != "$PARALLEL" ]]; then
  echo "engine-trial: TF_DSV41_SLOTS=${TF_DSV41_SLOTS:-unset} must equal PARALLEL=$PARALLEL. The engine default is 1 slot, so four HTTP agents would run one at a time." >&2
  exit 1
fi
if [[ "${TF_DSV41_POOL_TOKENS:-}" != 1048576 ]]; then
  echo "engine-trial: TF_DSV41_POOL_TOKENS must be 1048576 (the live 1M pool). Four slots need that pool. 2097152 spends SparkOne's page cache." >&2
  exit 1
fi
if [[ "${TF_DSV41_SLOT_DRAFTS:-}" != 1 ]]; then
  echo "engine-trial: TF_DSV41_SLOT_DRAFTS=1 keeps DSpark on all $PARALLEL slots." >&2
  exit 1
fi
if [[ "${TF_DSV41_SESSION_SLOTS:-}" != 1 ]]; then
  echo "engine-trial: TF_DSV41_SESSION_SLOTS=1 or the session store turns off when TF_DSV41_SLOTS is above 1." >&2
  exit 1
fi

hash="$(scripts/port-hash.sh)"
IMAGE="${TRIAL_IMAGE_PREFIX}${hash}"
export IMAGE
trial_refuse_retag "$IMAGE"
trial_assert_identity

if [[ "$GUARD_ONLY" == 1 || "${DRY_RUN:-0}" == 1 ]]; then
  echo "engine-trial: container=$CONTAINER_NAME image=$IMAGE port=$PORT host=$HOST"
  echo "engine-trial: TF_DSV41_PREFILL=${TF_DSV41_PREFILL:-full} TF_DSV41_SLOTS=${TF_DSV41_SLOTS:-unset} TF_DSV41_SESSION_RESIDENT_GIB=${TF_DSV41_SESSION_RESIDENT_GIB:-unset} TF_DSV41_CONTEXT=$TF_DSV41_CONTEXT"
  echo "engine-trial: live image $LIVE_IMAGE and container $LIVE_CONTAINER are not targets"
  echo "trial-guard: ok"
  exit 0
fi

if [[ -n "${TF_DSV41_SESSION_DISK:-}" ]]; then
  if [[ ! -d "$TF_DSV41_SESSION_DISK" ]]; then
    echo "engine-trial: TF_DSV41_SESSION_DISK=$TF_DSV41_SESSION_DISK is not a directory on this Spark." >&2
    exit 1
  fi
  fstype="$(findmnt -n -o FSTYPE -T "$TF_DSV41_SESSION_DISK" 2>/dev/null || true)"
  case "$fstype" in
    nfs|nfs4)
      echo "engine-trial: $TF_DSV41_SESSION_DISK is $fstype. Use a directory on local NVMe." >&2
      exit 1
      ;;
  esac
fi

mem_kib="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo || true)"
floor_kib=$((35 * 1024 * 1024 / 10))
if [[ -z "$mem_kib" || "$mem_kib" -lt "$floor_kib" ]]; then
  echo "engine-trial: MemAvailable ${mem_kib:-missing} KiB is under 3.5 GiB. Not starting." >&2
  exit 3
fi

RANK=0
ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
if [[ "${RANK_OVERRIDE:-}" == 1 || "$ip" == "$SPARK_TWO_TS" ]]; then
  RANK=1
fi

args=(
  serve "${MODEL:?set MODEL to the EAQ v1 directory @ 45ee5d0f}"
  --tp 2
  --rank "$RANK"
  --master "$SPARK_ONE_TS"
  --context "$CONTEXT"
  --parallel "$PARALLEL"
  --name "${SERVED_NAME:-DeepSeek-V4.1-Flash-1017}"
)
if [[ "$RANK" == 0 ]]; then
  args+=(--host "$HOST" --port "$PORT")
fi

echo "engine-trial: container=$CONTAINER_NAME image=$IMAGE port=$PORT host=$HOST rank=$RANK"
echo "engine-trial: set the same TF_DSV41_SESSION_RESIDENT_GIB on both ranks"

if [[ "$MODE" == stop ]]; then
  trial_stop_container "$TRIAL_CONTAINER"
  echo "engine-trial: live container $LIVE_CONTAINER was not touched"
  exit 0
fi

trial_require_live_stopped
[[ "$CONTAINER_NAME" == "$TRIAL_CONTAINER" ]] || {
  echo "engine-trial: refusing to replace container $CONTAINER_NAME" >&2
  exit 1
}
docker rm -f "$TRIAL_CONTAINER" >/dev/null 2>&1 || true

env_file="$(mktemp)"
trap 'rm -f "$env_file"' EXIT
# Forward the v1.2.7 knobs. The recipe start.sh does not know these names.
env | awk -F= '/^(TF_DSV41_|TENSORFOLD_)/ {print}' >"$env_file"

run=(docker run -d
  --name "$TRIAL_CONTAINER"
  --gpus all
  --network host
  --env-file "$env_file"
  -v "${MODEL}:${MODEL}:ro")
if [[ -n "${TF_DSV41_ASSETS:-}" ]]; then
  run+=(-v "${TF_DSV41_ASSETS}:${TF_DSV41_ASSETS}:ro")
fi
if [[ -n "${TF_DSV41_SESSION_DISK:-}" ]]; then
  run+=(-v "${TF_DSV41_SESSION_DISK}:${TF_DSV41_SESSION_DISK}")
fi
run+=("$IMAGE" "${args[@]}")
"${run[@]}"

echo "engine-trial: started $TRIAL_CONTAINER. Health: curl -fsS --max-time 5 http://${HOST}:${PORT}/health"
if [[ -n "${WORKER:-}" && "$RANK" == 0 ]]; then
  echo "engine-trial: start rank 1 on $WORKER with the same profile and RANK_OVERRIDE=1."
  echo "engine-trial: a different TF_DSV41_SESSION_RESIDENT_GIB on that rank refuses on both."
fi
