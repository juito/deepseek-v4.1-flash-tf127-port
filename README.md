# DeepSeek-V4.1-Flash-1017: first-token work + TensorFold v1.2.7 port triage

Two things live here, and they are deliberately separate:

1. **`profiles/` + `tools/ttft.py` — usable today**, on your current pin (`bertholomus/TensorFold`
   @ `fbbc971`), 2.9 bpw EAQ v1 **unchanged**. Scheduling only: no requantization, no bit change.
2. **`docs/port-status.md` — the v1.2.7 triage.** Moving the engine to upstream v1.2.7 is a
   reimplementation, not a version bump. Not deployable.

> Nothing here has been measured on hardware by this repository. Every expected direction in
> `docs/first-token.md` is the recipe's own measurement on a pair of Sparks, cited so you can check
> it. Your numbers come from `tools/ttft.py` on your pair, not from this README.

## First token

Read [`docs/first-token.md`](docs/first-token.md). The short version:

- Prefill runs at a flat ~2.1K tok/s, so TTFT is linear in prompt length once the prefix cache misses.
- **The largest lever is not a kernel**: Engram's tables on each Spark's local disk. Over NFS the
  recipe records prefill at ~690–890 tok/s against ~2.1K locally — a 4 KiB random read measured
  942 µs over NFS and 90 µs locally.
- Then: prefix-cache resume (already on), the spill tier, short-prompt cut-in, prefill interleave,
  prompt row width, and the indexer split.

```bash
make check                                   # validate profiles + syntax (CI runs this)
make profile NAME=ttft                       # write scripts/local.sh from profiles/ttft.env
./start.sh restart
make ttft OUT=runs/ttft-after.json           # p50/p90 TTFT, cold and warm
make compare A=runs/ttft-before.json B=runs/ttft-after.json
python3 -I recipe-tf-fbbc971/tools/exact.py  # replies must not move
```

## Profiles

| Profile | For | Notable settings |
|---|---|---|
| `ttft.env` | Interactive chat, 512K window | `MAX_TOKENS=8192`, `TF_DS_PROMPT_WINDOW_ROWS=128`, `TF_FILL_CHUNKS=1` + `TF_FILL_CUT_IN=8192`, `SPILL_GIB=64`, `GRAPH_CAP=128` |
| `balanced.env` | Day-to-day at the full window | Full window, spill on, interleave 250, `GRAPH_CAP=128` |
| `long-context.env` | 1M-token work | `POOL=2097152`, `KV_SHARD=1` (context, not TTFT) |

Each profile must be measured, not trusted. `scripts/check-profiles.sh` rejects unknown keys
(a typo would otherwise be silently ignored by the launcher), off-grid `CONTEXT`/`POOL`, and
`POOL < CONTEXT`.

## Keeping 2.9 bpw

See [`docs/quantization.md`](docs/quantization.md). The default pack is
`Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw` @ `45ee5d0f` (39 shards, ~196 GiB). The
`tools/exact.py` 31-case baseline was recorded on it. EAQ v1.1 (`EAQ_V1_1=1`) stores 27
indexer/compressor linears as BF16 — **different bits**, experimental, and it invalidates that
baseline. Every profile here is scheduling, so the baseline stays valid.

## The v1.2.7 port

[`docs/port-status.md`](docs/port-status.md) has the full picture and the 53-patch triage:

| | |
|---|---|
| Pin today | `bertholomus/TensorFold` @ `fbbc97132c` (2026-10-24) |
| Fork merge base | TensorFold **1.0.2** (2026-10-07) |
| Target | upstream **v1.2.7** (`93a2e93ece`, 2026-11-11) |
| Upstream commits missing | **6,958** |
| Recipe patches | **53**, of which **1** applies |

The family was rewritten upstream (`dsv41`, 62 files → `deepseek_v41`, 243 files, zero shared
filenames) and **0 of 18** recipe switches survive. `make triage` reproduces the count.

## Layout

```
docs/first-token.md      TTFT playbook: ranked levers, mechanism, cost, measurement protocol
docs/quantization.md     2.9 bpw invariant, EAQ v1 vs v1.1, what must re-baseline
docs/port-status.md      v1.2.7 triage, why 52/53 are blocked, validation gate
profiles/*.env           layered presets, validated against config.sh/port.sh
tools/ttft.py            TTFT-only bench: cold/warm, p50/p90, --compare
scripts/profile.sh       write profiles/<name>.env into scripts/local.sh
scripts/check-profiles.sh validate keys, grid alignment, POOL >= CONTEXT
scripts/triage.sh        re-run the 53-patch triage against any tag
recipe-tf-fbbc971/       the recipe verbatim at c7f2b85 (reference + runnable engine)
triage.csv               machine-readable triage
Makefile                 one command per job
```

## Licensing

Recipe and TensorFold are Apache-2.0; see `recipe-tf-fbbc971/LICENSE`, `NOTICE` and `CREDITS.md` for
the authors of each patch. This repository adds profiles, tooling and documentation only. No
affiliation with Mia's AI Lab, BertholomusAI, or TensorFold.
