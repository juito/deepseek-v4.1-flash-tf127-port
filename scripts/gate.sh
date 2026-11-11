#!/usr/bin/env bash
# On-hardware gate for the v1.2.7 trial. Run it on SparkOne against port 8890.
#
# Pass only when correctness matches the live exact.py record, the Nov 11
# cold TTFT refs improve, four agents all finish, their decode overlaps, and
# the aggregate is no more than 5% below 102.7 tok/s.
# Aborts before any prompt if MemAvailable is under 3.5 GiB on either node,
# or if the engine advertises fewer than 4 lanes.
#
#   scripts/gate.sh --self-check
#   scripts/gate.sh --url http://100.78.243.41:8890 --exact-old runs/exact-old.json
#
# Bit-changing profiles (tf127-pf4k, tf127-prefetch) also need
# --token-baseline runs/replay-sha.json recorded on tf127-replay.
# Live cold refs, Nov 11 ~2 PM PST: 8k 13.80 s, 131k 57.89 s. 4-stream 102.7 tok/s.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source scripts/trial-guard.sh

MEM_FLOOR_KIB=$(( 35 * 1024 * 1024 / 10 )) # 3.5 GiB
URL="${API_URL:-http://127.0.0.1:${TRIAL_PORT}}"
EXACT_OLD=""
TOKEN_BASELINE=""
OUT=""
SELF_CHECK=0
PROFILE="${PROFILE:-}"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-check) SELF_CHECK=1; shift ;;
    --url) URL="$2"; shift 2 ;;
    --exact-old) EXACT_OLD="$2"; shift 2 ;;
    --token-baseline) TOKEN_BASELINE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "gate: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

port_of() {
  local u="$1" rest="${1#*://}"
  rest="${rest#*@}"
  rest="${rest%%/*}"
  if [[ "$rest" == *:* ]]; then
    printf '%s\n' "${rest##*:}"
  else
    printf '%s\n' 80
  fi
}

refuse_live_url() {
  local port
  port="$(port_of "$1")"
  if [[ "$port" == "$LIVE_PORT" || "$port" == "$LIVE_TUNNEL_PORT" ]]; then
    echo "gate: $1 is the live serve or the Mac tunnel. The trial is port ${TRIAL_PORT}." >&2
    return 1
  fi
  return 0
}

if [[ "$SELF_CHECK" == 1 ]]; then
  refuse_live_url "http://127.0.0.1:${TRIAL_PORT}" || exit 1
  if refuse_live_url "http://127.0.0.1:${LIVE_PORT}"; then
    echo "gate: self-check failed to refuse port ${LIVE_PORT}" >&2
    exit 1
  fi
  if refuse_live_url "http://127.0.0.1:${LIVE_TUNNEL_PORT}"; then
    echo "gate: self-check failed to refuse port ${LIVE_TUNNEL_PORT}" >&2
    exit 1
  fi
  [[ "$MEM_FLOOR_KIB" -eq 3670016 ]] || { echo "gate: floor is not 3.5 GiB" >&2; exit 1; }
  echo "gate: self-check ok (MemAvailable floor ${MEM_FLOOR_KIB} KiB, cold refs 13.80 s / 57.89 s, 4-stream 102.7 tok/s)"
  exit 0
fi

refuse_live_url "$URL" || exit 1
[[ -n "$OUT" ]] || OUT="runs/gate-$(date -u +%Y%m%dT%H%M%SZ).json"
mkdir -p runs "$(dirname "$OUT")"

mem_kib() {
  awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo
}

peer_mem_kib() {
  local peer="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$peer" "awk '/^MemAvailable:/ {print \$2; exit}' /proc/meminfo"
}

abort_low() {
  local who="$1" kib="$2"
  if [[ -z "$kib" || ! "$kib" =~ ^[0-9]+$ || "$kib" -lt "$MEM_FLOOR_KIB" ]]; then
    echo "gate: ${who} MemAvailable ${kib:-missing} KiB is under 3.5 GiB. Aborting." >&2
    exit 3
  fi
  echo "gate: ${who} MemAvailable ${kib} KiB"
}

LOCAL_KIB="$(mem_kib || true)"
abort_low "this node" "$LOCAL_KIB"
PEER=""
case "$(trial_pick_host 2>/dev/null || true)" in
  "$SPARK_ONE_TS") PEER="$SPARK_TWO_TS" ;;
  "$SPARK_TWO_TS") PEER="$SPARK_ONE_TS" ;;
esac
if [[ -n "${WORKER:-}" ]]; then
  PEER="$WORKER"
fi
PEER_KIB=""
if [[ -n "$PEER" ]]; then
  PEER_KIB="$(peer_mem_kib "$PEER" || true)"
  abort_low "$PEER" "$PEER_KIB"
else
  echo "gate: peer Spark not identified. Set WORKER to the other node. Aborting." >&2
  exit 3
fi

# tensorfold:lanes is the engine's live slots (LaneHost.lanes = TF_DSV41_SLOTS).
# --parallel 4 with SLOTS left at 1 still prints 1 here, and four HTTP agents queue.
echo "gate: requiring tensorfold:lanes == 4"
LANES="$(curl -fsS --max-time 5 "${URL%/}/metrics" | awk '/^tensorfold:lanes / {print $2; exit}')"
if [[ "$LANES" != 4 ]]; then
  echo "gate: tensorfold:lanes is ${LANES:-missing}. Four agents need TF_DSV41_SLOTS=4 on both ranks. Aborting." >&2
  exit 4
fi
echo "gate: engine lanes $LANES"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORKDIR="runs/gate-${STAMP}"
mkdir -p "$WORKDIR"

keep() {
  echo "gate: $*"
  if ! "$@"; then
    echo "fail:$1" >>"$WORKDIR/steps.txt"
    return 0
  fi
  echo "ok:$1" >>"$WORKDIR/steps.txt"
}

keep python3 -I tools/ttft.py --url "$URL" --mode both --sizes 8192,32768,131072 --reps 3 \
  --salt gate-nov11 --out "$WORKDIR/ttft.json" --label trial
keep python3 -I tools/bench.py --url "$URL" --suite multi --streams 4 --reps 1 \
  --out "$WORKDIR/multi.json"

if [[ -n "$EXACT_OLD" ]]; then
  keep python3 -I recipe-tf-fbbc971/tools/exact.py record --url "$URL" \
    --like "$EXACT_OLD" --out "$WORKDIR/exact-trial.json" --streams 4
  if python3 -I recipe-tf-fbbc971/tools/exact.py compare "$EXACT_OLD" "$WORKDIR/exact-trial.json" \
      >"$WORKDIR/exact-compare.txt"; then
    echo ok >"$WORKDIR/exact-status"
  else
    echo fail >"$WORKDIR/exact-status"
  fi
else
  echo "gate: --exact-old is required for a pass." >&2
  echo missing >"$WORKDIR/exact-status"
fi

API_URL="$URL" keep python3 -I recipe-tf-fbbc971/tools/smoke.py --url "$URL"
API_URL="$URL" keep python3 -I recipe-tf-fbbc971/tools/prompt_reuse.py --require-counter
API_URL="$URL" keep python3 -I recipe-tf-fbbc971/tools/toolcheck.py
API_URL="$URL" keep python3 -I recipe-tf-fbbc971/tools/needle.py trial 160000

# Short request while a long prefill is in flight. Recorded, not compared to Mia's 3.84 s.
# A failure here is a gate fail, and the JSON verdict is still written.
if ! python3 -I - "$URL" "$WORKDIR/cut-in.json" <<'PY'
import json, sys, threading, time, urllib.request
url, out = sys.argv[1], sys.argv[2]
def post(n, max_tokens):
    body = json.dumps({
        "model": "DeepSeek-V4.1-Flash-1017",
        "messages": [{"role": "user", "content": ("alpha " * n)}],
        "max_tokens": max_tokens,
        "temperature": 0,
    }).encode()
    req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=900) as r:
        payload = json.loads(r.read().decode())
    return time.perf_counter() - t0, payload
holder = {}
def long():
    holder["long_s"], holder["long"] = post(8000, 8)
threading.Thread(target=long, daemon=True).start()
time.sleep(1.0)
short_s, short = post(32, 8)
long_s = holder.get("long_s")
json.dump({"short_s": short_s, "long_s": long_s,
           "short_sha": ((short.get("tensorfold") or {}).get("token_sha256"))},
          open(out, "w"), indent=2)
print(f"gate: short during long prefill {short_s:.2f} s")
PY
then
  echo "fail:cut-in" >>"$WORKDIR/steps.txt"
fi

# Restart the trial container only, then send the same 8k prompt again.
if [[ "${CONTAINER_NAME:-$TRIAL_CONTAINER}" != "$TRIAL_CONTAINER" ]]; then
  echo "gate: refusing to restart ${CONTAINER_NAME}" >&2
  exit 1
fi
echo "gate: docker restart $TRIAL_CONTAINER (the live container is not touched)"
docker restart "$TRIAL_CONTAINER"
for _ in $(seq 1 120); do
  if curl -fsS --max-time 5 "${URL%/}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
curl -fsS --max-time 5 "${URL%/}/health" >/dev/null
keep python3 -I tools/ttft.py --url "$URL" --mode cold --sizes 8192 --reps 1 \
  --salt gate-nov11 --out "$WORKDIR/restore.json" --label restore

# One greedy sha for bit-changing knobs.
if ! python3 -I - "$URL" "$WORKDIR/sha.json" <<'PY'
import json, sys, urllib.request
url, out = sys.argv[1], sys.argv[2]
body = json.dumps({
    "model": "DeepSeek-V4.1-Flash-1017",
    "messages": [{"role": "user", "content": "The capital of France is"}],
    "max_tokens": 16,
    "temperature": 0,
    "return_token_ids": True,
}).encode()
req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions", data=body,
                             headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=180) as r:
    payload = json.loads(r.read().decode())
tf = payload.get("tensorfold") or {}
json.dump({"token_sha256": tf.get("token_sha256"), "token_ids": tf.get("token_ids")}, open(out, "w"))
print("gate: token_sha256", tf.get("token_sha256"))
PY
then
  echo "fail:token-sha" >>"$WORKDIR/steps.txt"
fi

python3 -I - "$WORKDIR" "$OUT" "$LOCAL_KIB" "$PEER_KIB" "$EXACT_OLD" "$TOKEN_BASELINE" "$PROFILE" <<'PY'
import json, pathlib, sys
sys.path.insert(0, "scripts")
import gate_concurrency
work, out, local_kib, peer_kib, exact_old, token_base, profile = sys.argv[1:]
root = pathlib.Path(work)
reasons = []
def load(name, default):
    path = root / name
    if not path.exists():
        reasons.append(f"{name} missing")
        return default
    return json.loads(path.read_text())
ttft = load("ttft.json", {"sizes": []})
def row(mode, tokens):
    for r in ttft["sizes"]:
        if r["mode"] == mode and r["requested_tokens"] == tokens:
            return r["ttft_ms_p50"] / 1000.0
    return None
cold8, cold32, cold131 = row("cold", 8192), row("cold", 32768), row("cold", 131072)
warm8, warm32, warm131 = row("warm", 8192), row("warm", 32768), row("warm", 131072)
refs = {"cold_8k_s": 13.80, "cold_131k_s": 57.89, "decode_4stream_tok_s": 102.7}
if cold8 is None or cold8 >= refs["cold_8k_s"]:
    reasons.append(f"8k cold TTFT {cold8} s does not beat {refs['cold_8k_s']} s")
if cold131 is None or cold131 >= refs["cold_131k_s"]:
    reasons.append(f"131k cold TTFT {cold131} s does not beat {refs['cold_131k_s']} s")
for label, warm, cold in (("8k", warm8, cold8), ("32k", warm32, cold32), ("131k", warm131, cold131)):
    if warm is None or cold is None or not (warm < cold):
        reasons.append(f"{label} warm TTFT {warm} is not below cold {cold}")
multi = load("multi.json", {})
four = [r for r in (multi.get("runs") or []) if r.get("suite") == "multi" and r.get("streams") == 4]
row = four[-1] if four else None
reasons.extend(gate_concurrency.reasons(row, refs["decode_4stream_tok_s"]))
agents = gate_concurrency.stats(row)
decode = agents["aggregate_tok_s"]
exact_status = (root / "exact-status").read_text().strip() if (root / "exact-status").exists() else "missing"
exact_ok = exact_status == "ok"
if exact_status == "missing":
    reasons.append("exact.py was not compared to a live record (--exact-old)")
elif not exact_ok:
    reasons.append("exact.py compare did not match")
steps = (root / "steps.txt").read_text() if (root / "steps.txt").exists() else ""
for line in steps.splitlines():
    if line.startswith("fail:"):
        reasons.append(line[5:] + " failed")
restore = load("restore.json", {"sizes": []})
restore_s = None
for r in restore["sizes"]:
    if r["mode"] == "cold" and r["requested_tokens"] == 8192:
        restore_s = r["ttft_ms_p50"] / 1000.0
if restore_s is None or cold8 is None or not (restore_s < cold8):
    reasons.append(f"restart-then-restore 8k TTFT {restore_s} s is not below the cold 8k {cold8} s")
cut = load("cut-in.json", {})
if "short_s" not in cut:
    reasons.append("short request during long prefill was not recorded")
sha = load("sha.json", {})
bit_changing = False
if profile:
    envp = pathlib.Path(profile if profile.endswith(".env") else f"profiles/{profile}.env")
    if not envp.exists():
        envp = pathlib.Path("profiles") / (profile if profile.endswith(".env") else profile + ".env")
    body = envp.read_text() if envp.exists() else ""
    bit_changing = "TF_DSV41_PF_4K=1" in body or "TF_DSV41_PREFETCH_AHEAD=1" in body
if bit_changing:
    if not token_base:
        reasons.append("bit-changing profile needs --token-baseline recorded on tf127-replay")
    else:
        base = json.loads(pathlib.Path(token_base).read_text())
        if base.get("token_sha256") != sha.get("token_sha256"):
            reasons.append("token_sha256 differs from the replay baseline")
verdict = "pass" if not reasons else "fail"
doc = {
    "verdict": verdict,
    "reasons": reasons,
    "mem_available_kib": {"local": int(local_kib), "peer": int(peer_kib)},
    "mem_floor_kib": 3670016,
    "refs": refs,
    "cold_s": {"8192": cold8, "32768": cold32, "131072": cold131},
    "warm_s": {"8192": warm8, "32768": warm32, "131072": warm131},
    "restore_8k_s": restore_s,
    "cut_in_short_s": cut.get("short_s"),
    "decode_4stream_tok_s": decode,
    "agents": agents,
    "exact_match": exact_ok,
    "token_sha256": sha.get("token_sha256"),
    "prompt_cache_live": {
        "bytes": 512 * 1024 * 1024,
        "evictions": 121,
        "prefix_hit_rate": 0.952,
        "avg_ttft_s": 1.77,
    },
}
pathlib.Path(out).write_text(json.dumps(doc, indent=2) + "\n")
print(json.dumps(doc, indent=2))
sys.exit(0 if verdict == "pass" else 1)
PY
