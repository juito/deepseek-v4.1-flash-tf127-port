# Trial runbook

A TensorFold trial on the two Sparks is a **second container and a second image tag**. It
does not replace the live serve. Only one model fits in RAM, so the live process has to be
stopped before the trial loads. Stopping it is `docker stop`. The container, the tag, and
the weights stay where they are, and rollback is `docker start`.

Nothing in this repository builds an image or talks to a Spark. These commands are for the
operator, on SparkOne.

## Live serve (do not replace)

| | |
|---|---|
| Image | `tensorfold-dsv41:exl3-tp2-8a98ae503d85` |
| Container | `dsv41-1017-exl3-tf` (same name on both Sparks) |
| API | port **8888** |
| SparkOne | `100.78.243.41` (Tailscale) |
| SparkTwo | `100.99.140.126` (Tailscale) |
| Mac tunnel | local **18004** → 8888. Leave it pointed at the live port |
| Weights | EAQ v1 2.9 bpw @ `45ee5d0f` |
| Engram | `engram-1bae0e10` |

## Trial serve

| | |
|---|---|
| Image | `tensorfold-dsv41:tf127-trial-<hash>` |
| Container | `dsv41-tf127-trial` |
| API | port **8890** |
| Bind | this node's Tailscale IP, or `127.0.0.1`. Never `0.0.0.0` |

The current recipe tree hashes to `8a98ae503d85`, so the trial tag is
`tensorfold-dsv41:tf127-trial-8a98ae503d85`. That is a different tag from
`tensorfold-dsv41:exl3-tp2-8a98ae503d85`. `scripts/trial.sh` refuses to build, tag, or start
anything whose name is the live image or the live container, refuses ports 8888 and 18004,
and refuses `HOST=0.0.0.0`. `--stop-live` is the only path that touches the live container,
and the command it runs is `docker stop` (on the worker too, when `WORKER` is set). It never
`docker rm`s that container and never `docker tag`s that image.

There is no `start.sh` at the repository root. Do not run `recipe-tf-fbbc971/start.sh` by hand:
its defaults are the live container, port 8888, and `HOST=0.0.0.0`.

## 1. Build the side image and start the trial

Keep the live pins. The trial is an engine/scheduling trial of the same weights, so
`tools/exact.py` still has a baseline. Do not set `EAQ_V1_1` or `ABLIT`. Point
`HEAD_ENGRAM_DIR` at the existing `engram-1bae0e10` directory if it is not already the path
the recipe derives.

```bash
make profile NAME=ttft-fill          # or ttft-interleave, balanced, long-context, residency
scripts/trial.sh --stop-live restart
```

`--stop-live` is required when `dsv41-1017-exl3-tf` is running. Omit it and the script
refuses. The live container remains on disk, stopped.

What the start does, in order:

1. `docker stop` the live container on this Spark and, if `WORKER` is set, on SparkTwo.
2. If the trial tag is not built yet, the recipe's `prepare.sh` builds
   `tensorfold-dsv41:tf127-trial-<hash>`. It does not pass the live tag to `docker build -t`.
3. Start `dsv41-tf127-trial` on port 8890, bound to the Tailscale address (or `127.0.0.1`
   when this host has no Tailscale IP).

### Expected timings

| Step | Expect | Source |
|---|---|---|
| Zig compile of the current recipe image | about **6 minutes** on a Spark, image about 24.9 GB | `recipe-tf-fbbc971/docs/measurements.md` (29 Oct 2026 image); `prepare.sh` says ~6 min |
| A v1.2.7 image | **not measured** here | the port is not built by this repo |
| Upgrade prepared-folder rebuild | ~10.5 min first boot to weights loaded at TP=2 on two GB10s, ~5 min later | TensorFold 1.2.6 `#2325`. This is not the trial image build and not an EAQ pack swap |
| Weights loaded, API answers | **a few minutes** for ~98 GiB, then Engram and the caches. The script waits up to `WAIT_TIMEOUT` (2400 s) and prints the seconds | recipe `start.sh` step 4 |
| `docker stop` of the live container | seconds, then the GPU memory drains. The container is not removed | docker |

## 2. Matched validation against the current image

Only one model is loaded, so "old vs new" is sequential. Alternate: old, new, new, old. A
single before-then-after on a box that also runs a desktop will lie to you. Each switch pays
the weight-load time above.

Source the trial endpoint before any tool. `make ttft`, `make bench`, `tools/ttft.py`, and
`tools/bench.py` default to port 8890, refuse 8888 and 18004 unless you pass `--allow-live`,
and read `/metrics` before the first prompt. They refuse to send anything while
`requests_running` is missing or not 0. Recipe tools you invoke yourself (`exact.py`,
`smoke.py`, `toolcheck.py`, `needle.py`, `prompt_reuse.py`) still default to port 8888;
pass `--url` or `API_URL`.

```bash
source scripts/trial-env.sh          # HOST, PORT=8890, API_URL. Never 0.0.0.0
export API_URL                       # recipe tools that only read the environment
```

On SparkOne the URL is `http://100.78.243.41:8890` when Tailscale is up. Loopback will not
answer a process bound to the Tailscale address. `source scripts/trial-env.sh` picks the same
address the trial bound.

Gate, in order. Record the old image first (live container, port 8888, `--allow-live` only
for that pass), then the trial, then the old image again.

1. **`exact.py` 31/31.** Record on the old image, record on the trial with `--like` that
   file, compare. Replies must be identical. Prompts go through 100k tokens; a cold 128k
   prefill is **63.28 s** at ~2,077 tok/s (`docs/first-token.md`), so the long cases dominate.

   ```bash
   python3 -I recipe-tf-fbbc971/tools/exact.py record --url "$API_URL" \
     --like runs/exact-old.json --out runs/exact-trial.json --streams 4
   python3 -I recipe-tf-fbbc971/tools/exact.py compare runs/exact-old.json runs/exact-trial.json
   ```

   `--streams 4` is the four-concurrent set the recipe calls 31 prompts
   (`docs/measurements.md`). Record the live image with the same flag before the trial,
   and compare that file. A newer `exact.py` default of 8 streams is a different set.

2. **Smoke, prompt reuse, tool check, needle.**

   ```bash
   python3 -I recipe-tf-fbbc971/tools/smoke.py --url "$API_URL"
   API_URL="$API_URL" python3 -I recipe-tf-fbbc971/tools/prompt_reuse.py --require-counter
   API_URL="$API_URL" python3 -I recipe-tf-fbbc971/tools/toolcheck.py
   API_URL="$API_URL" python3 -I recipe-tf-fbbc971/tools/needle.py trial 160000
   ```

   `needle.py` sizes the haystack at about 0.8× its argument, so `160000` is about 128k
   tokens, inside the 524288 cap. The recipe's longer needle (479,012 tokens, three depths,
   `tools/bench.py --suite needle`) took about **280 s** of prefill at ~1,710 tok/s and left
   the head 0.17 GiB above memguard (`docs/measurements.md`). Do not repeat that length on a
   head that is not the one it was measured on. Compare the same size on old and new.

3. **Prefill, decode, and 4-stream bench.**

   ```bash
   python3 -I tools/bench.py --suite prefill,decode,multi --streams 4 \
     --out runs/bench-trial.json
   python3 -I recipe-tf-fbbc971/tools/bench.py --compare runs/bench-old.json runs/bench-trial.json
   ```

   Cold prefill is ~2.1k tok/s, so a 32k prompt is about **15 s** and a 128k prompt about
   **63 s** (`docs/first-token.md`). A cold prompt pays that cost. A resident prompt does not.

4. **Cold and warm TTFT, including ~131k.**

   ```bash
   python3 -I tools/ttft.py --mode both --sizes 512,2048,8192,32768,131072 --reps 5 \
     --out runs/ttft-trial.json --label trial
   python3 -I tools/ttft.py --compare runs/ttft-old.json runs/ttft-trial.json
   ```

   The 128k cold row in the recipe is **63.28 s**. Warm resume of a kept prefix is
   **1.5–1.9 s** (159k and 261k histories). A spill resume of a 237k conversation was
   **1.7 s** against **118 s** recomputed.

5. **Short quality and tool-call set.** `smoke.py` already checks a tool call, stop
   strings, and a greedy pair. `toolcheck.py` checks one array-argument call. Together they
   are the short set: a handful of requests, seconds each once the server is up, not another
   long prefill. A failure here is a stop, not a number to average.

6. **Alternate.** After the trial pass, roll back (below), repeat the same commands against
   port 8888 with `--allow-live` on `ttft.py` / `bench.py` and `API_URL=http://100.78.243.41:8888`
   for the recipe tools, then start the trial again and repeat once more. Keep clocks fixed
   (`nvidia-smi -lgc`) the way `docs/first-token.md` says.

## 3. Rollback

```bash
scripts/trial.sh stop          # docker stop dsv41-tf127-trial only
scripts/trial.sh rollback      # docker start dsv41-1017-exl3-tf (both Sparks when WORKER is set)
curl -fsS --max-time 5 http://100.78.243.41:8888/health
curl -fsS --max-time 5 http://127.0.0.1:8888/health
```

Rollback does not rebuild, does not retag `exl3-tp2-8a98ae503d85`, and does not `docker rm`
the live container. If that container is gone, the script stops and says so — there is then
nothing to `docker start`.

The API is not back in one second. `docker start` runs the same entrypoint, which loads
~98 GiB again: the same **few minutes** as a normal start, bounded by `WAIT_TIMEOUT` (2400 s).
What you skip is the image build (~6 min) and any prepared-folder rebuild. The Mac tunnel on
18004 still forwards to 8888; do not retarget it at 8890.

Confirm `/health` on **8888** answers, and `/metrics` on 8888 shows `requests_running 0`
before anyone depends on it. The trial container should be stopped so both models are not
resident.
