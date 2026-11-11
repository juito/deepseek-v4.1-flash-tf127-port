#!/usr/bin/env bash
# Guards for a side-by-side TensorFold trial. Source this file, or run:
#   scripts/trial-guard.sh check
#
# The live serve stays on disk for rollback. This file never removes it and
# never retags its image. Stopping it, when the operator passes --stop-live,
# is `docker stop` only.

LIVE_IMAGE=tensorfold-dsv41:exl3-tp2-8a98ae503d85
LIVE_TAG=exl3-tp2-8a98ae503d85
LIVE_CONTAINER=dsv41-1017-exl3-tf
LIVE_PORT=8888
LIVE_TUNNEL_PORT=18004
TRIAL_CONTAINER=dsv41-tf127-trial
TRIAL_PORT=8890
TRIAL_IMAGE_PREFIX=tensorfold-dsv41:tf127-trial-
SPARK_ONE_TS=100.78.243.41
SPARK_TWO_TS=100.99.140.126
MAX_CONTEXT=524288

trial_die() {
  echo "trial-guard: $*" >&2
  return 1
}

# True (0) when the image reference is the live tag, or would retag it.
trial_image_is_live() {
  local img="$1" tag="${1##*:}"
  [[ "$img" == "$LIVE_IMAGE" || "$tag" == "$LIVE_TAG" || "$img" == *"$LIVE_TAG"* ]]
}

trial_host_ok() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  [[ "$host" == "0.0.0.0" || "$host" == "::" || "$host" == "[::]" || "$host" == "*" ]] && return 1
  return 0
}

# This node's Tailscale address when it is one, otherwise 127.0.0.1.
# An explicit HOST of 0.0.0.0 or :: is refused. Never prints 0.0.0.0.
trial_pick_host() {
  if [[ -n "${HOST:-}" ]]; then
    if ! trial_host_ok "$HOST"; then
      trial_die "HOST=$HOST is refused. Use this node's Tailscale IP (${SPARK_ONE_TS} or ${SPARK_TWO_TS}) or 127.0.0.1, never 0.0.0.0."
      return 1
    fi
    printf '%s\n' "$HOST"
    return 0
  fi
  local ip=""
  if command -v tailscale >/dev/null 2>&1; then
    ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  fi
  case "$ip" in
    "$SPARK_ONE_TS"|"$SPARK_TWO_TS"|100.*)
      printf '%s\n' "$ip"
      return 0
      ;;
  esac
  printf '%s\n' "127.0.0.1"
}

# Refuse a docker tag / build destination that would move the live tag.
trial_refuse_retag() {
  local dest="${1:-}"
  if [[ -z "$dest" ]]; then
    trial_die "refusing to tag an empty image name"
    return 1
  fi
  if trial_image_is_live "$dest"; then
    trial_die "refusing to retag ${LIVE_IMAGE}. The trial image must be ${TRIAL_IMAGE_PREFIX}<hash>."
    return 1
  fi
  if [[ "$dest" != "$TRIAL_IMAGE_PREFIX"* ]]; then
    trial_die "image $dest is outside the trial namespace ${TRIAL_IMAGE_PREFIX}<hash>"
    return 1
  fi
  return 0
}

trial_assert_identity() {
  local name="${CONTAINER_NAME:-$TRIAL_CONTAINER}"
  local port="${PORT:-$TRIAL_PORT}"
  local image="${IMAGE:-}"
  local host="${HOST:-}"
  if [[ "$name" == "$LIVE_CONTAINER" ]]; then
    trial_die "refusing container name $name (that is the live serve). Use $TRIAL_CONTAINER."
    return 1
  fi
  if [[ "$port" == "$LIVE_PORT" || "$port" == "$LIVE_TUNNEL_PORT" ]]; then
    trial_die "refusing port $port (live serve is $LIVE_PORT, Mac tunnel is $LIVE_TUNNEL_PORT). Use $TRIAL_PORT."
    return 1
  fi
  if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    trial_die "PORT=$port is not a port number"
    return 1
  fi
  if ! trial_host_ok "$host"; then
    trial_die "HOST='${host}' is refused. Never bind 0.0.0.0."
    return 1
  fi
  if [[ -n "$image" ]]; then
    trial_refuse_retag "$image" || return 1
  fi
  return 0
}

# Assignment lines in scripts/local.sh must not name the live serve. Comments
# may mention it. A direct recipe start.sh reads this file.
trial_scan_local() {
  local file="$1" line key val trimmed
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]] && continue
    key="${line%%=*}"
    key="${key#export }"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${line#*=}"
    val="${val%%#*}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    case "$key" in
      CONTAINER_NAME)
        if [[ "$val" == "$LIVE_CONTAINER" ]]; then
          trial_die "$file sets CONTAINER_NAME=$val (the live serve). Use $TRIAL_CONTAINER."
          return 1
        fi
        ;;
      PORT)
        if [[ "$val" == "$LIVE_PORT" || "$val" == "$LIVE_TUNNEL_PORT" ]]; then
          trial_die "$file sets PORT=$val (live serve or Mac tunnel). Use $TRIAL_PORT."
          return 1
        fi
        ;;
      HOST)
        if ! trial_host_ok "$val"; then
          trial_die "$file sets HOST=$val. Never 0.0.0.0."
          return 1
        fi
        ;;
      IMAGE)
        if trial_image_is_live "$val"; then
          trial_die "$file sets IMAGE=$val. Refusing to retag $LIVE_IMAGE."
          return 1
        fi
        ;;
    esac
  done < "$file"
  return 0
}

trial_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    trial_die "docker is not available; cannot tell whether $LIVE_CONTAINER is running"
    return 1
  fi
  command docker "$@"
}

# Prints running, stopped, absent, or unknown.
# unknown fails closed: a daemon we cannot ask is not treated as "stopped".
trial_container_state() {
  local name="$1" state
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' unknown
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    printf '%s\n' unknown
    return 0
  fi
  if ! state="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)"; then
    printf '%s\n' absent
    return 0
  fi
  case "$state" in
    true|True) printf '%s\n' running ;;
    *) printf '%s\n' stopped ;;
  esac
}

# docker stop only. There is no remove path here.
trial_stop_container() {
  local name="$1"
  if [[ "$name" == "$LIVE_CONTAINER" && "${TRIAL_STOP_IS_LIVE:-0}" != 1 ]]; then
    trial_die "internal error: trial_stop_container was asked to stop the live container without the live flag"
    return 1
  fi
  echo "trial-guard: docker stop $name (never rm)" >&2
  trial_docker stop -t "${STOP_TIMEOUT:-30}" "$name"
}

trial_stop_live() {
  local state
  TRIAL_STOP_IS_LIVE=1 trial_stop_container "$LIVE_CONTAINER" || return 1
  if [[ -n "${WORKER:-}" && "${TRIAL_LOCAL_ONLY:-0}" != 1 ]]; then
    echo "trial-guard: docker stop $LIVE_CONTAINER on $WORKER (never rm)" >&2
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$WORKER" \
      "docker stop -t ${STOP_TIMEOUT:-30} $(printf '%q' "$LIVE_CONTAINER")" || return 1
  fi
  state="$(trial_container_state "$LIVE_CONTAINER")"
  if [[ "$state" == running ]]; then
    trial_die "$LIVE_CONTAINER is still running after docker stop"
    return 1
  fi
  if [[ "$state" == unknown ]]; then
    trial_die "cannot confirm $LIVE_CONTAINER stopped"
    return 1
  fi
  return 0
}

trial_require_live_stopped() {
  local state
  state="$(trial_container_state "$LIVE_CONTAINER")"
  case "$state" in
    unknown)
      trial_die "cannot see whether $LIVE_CONTAINER is running (docker missing or inspect failed closed). Refusing to start a trial."
      return 1
      ;;
    running)
      if [[ "${STOP_LIVE:-0}" == 1 ]]; then
        if [[ "${DRY_RUN:-0}" == 1 ]]; then
          echo "trial-guard: DRY_RUN: would docker stop $LIVE_CONTAINER (never rm)" >&2
          return 0
        fi
        trial_stop_live || return 1
      else
        trial_die "$LIVE_CONTAINER is running. Only one model fits in RAM. Re-run with --stop-live to docker stop it. The container is not removed; rollback is docker start $LIVE_CONTAINER."
        return 1
      fi
      ;;
  esac
  return 0
}

trial_start_live() {
  local state
  state="$(trial_container_state "$LIVE_CONTAINER")"
  if [[ "$state" == unknown ]]; then
    trial_die "cannot see $LIVE_CONTAINER; refusing to guess at rollback"
    return 1
  fi
  if [[ "$state" == absent ]]; then
    trial_die "$LIVE_CONTAINER is not on this docker. Rollback needs the stopped container still present (it must not have been removed)."
    return 1
  fi
  echo "trial-guard: docker start $LIVE_CONTAINER" >&2
  trial_docker start "$LIVE_CONTAINER" || return 1
  if [[ -n "${WORKER:-}" && "${TRIAL_LOCAL_ONLY:-0}" != 1 ]]; then
    echo "trial-guard: docker start $LIVE_CONTAINER on $WORKER" >&2
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$WORKER" \
      "docker start $(printf '%q' "$LIVE_CONTAINER")" || return 1
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  case "${1:-}" in
    check)
      HOST="$(trial_pick_host)" || exit 1
      export HOST
      CONTAINER_NAME="${CONTAINER_NAME:-$TRIAL_CONTAINER}"
      PORT="${PORT:-$TRIAL_PORT}"
      export CONTAINER_NAME PORT
      trial_assert_identity || exit 1
      echo "trial-guard: ok host=$HOST container=$CONTAINER_NAME port=$PORT image=${IMAGE:-unset}"
      ;;
    *)
      echo "usage: scripts/trial-guard.sh check" >&2
      exit 2
      ;;
  esac
fi
