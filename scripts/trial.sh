#!/usr/bin/env bash
# Start, stop, or roll back the side-by-side trial. This is the only start
# path in this repository. There is no ./start.sh at the repo root.
#
# The live serve is left intact:
#   image      tensorfold-dsv41:exl3-tp2-8a98ae503d85
#   container  dsv41-1017-exl3-tf
#   port       8888 on SparkOne 100.78.243.41, SparkTwo 100.99.140.126
#   tunnel     Mac 18004 -> 8888
#
# The trial uses dsv41-tf127-trial, tensorfold-dsv41:tf127-trial-<hash>, and
# port 8890. HOST is this node's Tailscale IP, or 127.0.0.1. Never 0.0.0.0.
#
# Usage:
#   scripts/trial.sh restart                 # refuse if the live container is running
#   scripts/trial.sh --stop-live restart     # docker stop the live container (never rm), then start the trial
#   scripts/trial.sh stop                    # docker stop the trial container only
#   scripts/trial.sh rollback                # stop the trial, docker start the live container
#   scripts/trial.sh --guard-only restart    # resolve settings and apply the stop-live rule, do not exec start.sh
#
# One model fits in RAM. Stopping the live container is the operator's choice
# and is never implied. Rollback does not rebuild or retag.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/trial-guard.sh

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

STOP_LIVE=0
GUARD_ONLY=0
MODE=start
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stop-live) STOP_LIVE=1; shift ;;
    --guard-only) GUARD_ONLY=1; shift ;;
    -h|--help|help) usage; exit 0 ;;
    start) MODE=start; shift ;;
    restart) MODE=restart; shift ;;
    stop) MODE=stop; shift ;;
    rollback) MODE=rollback; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
export STOP_LIVE

ROOT="$(pwd)"
LOCAL="$ROOT/recipe-tf-fbbc971/scripts/local.sh"
export CONTAINER_NAME="${CONTAINER_NAME:-$TRIAL_CONTAINER}"
export PORT="${PORT:-$TRIAL_PORT}"
HOST="$(trial_pick_host)"
export HOST

if [[ "$MODE" == start || "$MODE" == restart ]]; then
  if [[ -z "${IMAGE:-}" ]]; then
    hash="$(
      cd "$ROOT/recipe-tf-fbbc971"
      # shellcheck disable=SC1091
      source scripts/config.sh
      image_hash
    )"
    [[ "$hash" =~ ^[0-9a-f]{12}$ ]] || { echo "trial: image hash '$hash' is not 12 hex chars" >&2; exit 1; }
    IMAGE="${TRIAL_IMAGE_PREFIX}${hash}"
  fi
  export IMAGE
  trial_refuse_retag "$IMAGE"
fi

trial_assert_identity
trial_scan_local "$LOCAL"

case "$MODE" in
  stop)
    state="$(trial_container_state "$CONTAINER_NAME")"
    case "$state" in
      unknown) trial_die "cannot see $CONTAINER_NAME"; exit 1 ;;
      running) trial_stop_container "$CONTAINER_NAME" ;;
      *) echo "trial: $CONTAINER_NAME is $state; nothing to stop" ;;
    esac
    echo "trial: live container $LIVE_CONTAINER was not touched"
    exit 0
    ;;
  rollback)
    state="$(trial_container_state "$CONTAINER_NAME")"
    case "$state" in
      unknown) trial_die "cannot see the trial container"; exit 1 ;;
      running) trial_stop_container "$CONTAINER_NAME" ;;
      *) echo "trial: $CONTAINER_NAME is $state" ;;
    esac
    if [[ "${DRY_RUN:-0}" == 1 || "$GUARD_ONLY" == 1 ]]; then
      echo "trial-guard: would docker start $LIVE_CONTAINER (image $LIVE_IMAGE stays; no rm, no retag)"
      echo "trial: then verify health on port $LIVE_PORT (not $TRIAL_PORT, not $LIVE_TUNNEL_PORT unless that tunnel still forwards to $LIVE_PORT)"
      exit 0
    fi
    trial_start_live
    echo "trial: live container started. Verify:"
    echo "  curl -fsS --max-time 5 http://127.0.0.1:${LIVE_PORT}/health"
    echo "  curl -fsS --max-time 5 http://${SPARK_ONE_TS}:${LIVE_PORT}/health"
    echo "Weight load is the same few minutes as a normal start (start.sh's load step). No image rebuild."
    exit 0
    ;;
esac

trial_require_live_stopped

echo "trial: container=$CONTAINER_NAME image=${IMAGE:-} port=$PORT host=$HOST"
echo "trial: live image $LIVE_IMAGE and container $LIVE_CONTAINER are not targets"

if [[ "$GUARD_ONLY" == 1 ]]; then
  echo "trial-guard: ok"
  exit 0
fi

if [[ "${DRY_RUN:-0}" == 1 ]]; then
  echo "trial: DRY_RUN=1; recipe start.sh will print commands and change nothing"
fi

# The recipe launcher removes whatever CONTAINER_NAME is. That name was just
# checked against the live container. It must not be the live one. `start` is
# the recipe's default mode; only `restart` is a recipe argument.
cd "$ROOT/recipe-tf-fbbc971"
if [[ "$MODE" == restart ]]; then
  exec ./start.sh restart "${ARGS[@]}"
fi
exec ./start.sh "${ARGS[@]}"
