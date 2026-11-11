#!/usr/bin/env bash
# Export the trial endpoint for tools that read API_URL / PORT / HOST.
#
#   source scripts/trial-env.sh
#   python3 -I tools/ttft.py ...
#
# The server listens on this node's Tailscale IP when it has one, else
# 127.0.0.1, always on port 8890. Ports 8888 and 18004 are refused unless
# ALLOW_LIVE=1. HOST is never 0.0.0.0.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/trial-guard.sh"

_trial_env_apply() {
  local picked url
  if [[ "${ALLOW_LIVE:-0}" == 1 ]]; then
    echo "trial-env: ALLOW_LIVE=1; not overriding a live endpoint" >&2
    return 0
  fi
  if [[ -n "${PORT:-}" && ( "$PORT" == "$LIVE_PORT" || "$PORT" == "$LIVE_TUNNEL_PORT" ) ]]; then
    trial_die "PORT=$PORT is the live serve or the Mac tunnel. Unset it or pass ALLOW_LIVE=1."
    return 1
  fi
  if [[ -n "${API_URL:-}" ]]; then
    case "$API_URL" in
      *":${LIVE_PORT}"|*":${LIVE_PORT}/"*|*":${LIVE_TUNNEL_PORT}"|*":${LIVE_TUNNEL_PORT}/"*)
        trial_die "API_URL=$API_URL points at the live serve or the Mac tunnel. Unset it or pass ALLOW_LIVE=1."
        return 1
        ;;
    esac
  fi
  if [[ -n "${HOST:-}" ]] && ! trial_host_ok "$HOST"; then
    trial_die "HOST=$HOST is refused."
    return 1
  fi
  picked="$(trial_pick_host)"
  HOST="$picked"
  PORT="$TRIAL_PORT"
  url="http://${HOST}:${PORT}"
  export HOST PORT API_URL="$url"
  printf 'export HOST=%q\nexport PORT=%q\nexport API_URL=%q\n' "$HOST" "$PORT" "$API_URL"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  _trial_env_apply
else
  # shellcheck disable=SC2154
  eval "$(_trial_env_apply)"
fi
