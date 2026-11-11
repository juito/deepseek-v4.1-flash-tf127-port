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
make check                                   # validate profiles, guards, syntax (CI runs this)
make profile NAME=ttft-fill                 # write the trial local.sh (not the live serve)
scripts/trial.sh --stop-live restart        # separate container, image tag, and port 8890
source scripts/trial-env.sh                 # API_URL for the trial; refuses 8888 and 18004
make ttft OUT=runs/ttft-after.json          # p50/p90 TTFT, cold and warm
make compare A=runs/ttft-before.json B=runs/ttft-after.json
```

There is no `start.sh` at the repository root. The trial path is [`docs/trial-runbook.md`](docs/trial-runbook.md).
It does not replace the live container `dsv41-1017-exl3-tf`, the live tag
`tensorfold-dsv41:exl3-tp2-8a98ae503d85`, or port 8888.

## Profiles

| Profile | For | Notable settings |
|---|---|---|
| `ttft-fill.env` | Interactive chat, cut-in | `MAX_TOKENS=8192`, `TF_FILL_CHUNKS=1`, `TF_FILL_CUT_IN=8192`, `PREFILL_INTERLEAVE_MS=0` |
| `ttft-interleave.env` | Interactive chat, interleave | `PREFILL_INTERLEAVE_MS=250`, no `TF_FILL_*` (the two are mutually exclusive) |
| `balanced.env` | Day-to-day | `CONTEXT=524288`, spill on, interleave 250, `GRAPH_CAP=128` |
| `long-context.env` | More resident history | `CONTEXT=524288`, `POOL=2097152`, `KV_SHARD=1` |
| `residency.env` | Kept conversations, full decode | `CONTEXT=524288`, `POOL=2097152`, `KV_SHARD=0` |
| `tf127-baseline.env` | v1.2.7 fair baseline | `PARALLEL=4`, `TF_DSV41_SLOTS=4`, pool 1,048,576, `TF_DSV41_PREFILL=full`, resident 0.5 GiB |
| `tf127-replay.env` | v1.2.7 TTFT trial | replay, NVMe session disk, 64 GiB budget, resident cap 3 GiB on both ranks |
| `tf127-replay-2gib.env` | replay when the trough is under 4 GiB | resident cap 2 GiB |
| `tf127-pf4k.env` | optional, exactness-gated | `TF_DSV41_PF_4K=1` (+0.66 GiB), `GM_V2=1`, replay |
| `tf127-prefetch.env` | optional, exactness-gated | `TF_DSV41_PREFETCH_AHEAD=1` on the replay tier |
| `tf127-cut-in.env` | short request during a long prefill | pieces on, cut-in 8192, interleave 0 |
| `tf127-interleave.env` | fixed 250 ms decode budget | pieces on, `TF_DSV41_PREFILL_INTERLEAVE_MS=250` |

`CONTEXT` is capped at **524288** in every profile. That is the live window. A run at
655,360 killed a 464K-token turn. `TF_FILL_CHUNKS` turns the 0005 interleave off, so the
two TTFT profiles are an A/B pair, not one file that sets both.

Each profile must be measured, not trusted. `scripts/check-profiles.sh` rejects unknown keys
(a typo would otherwise be silently ignored by the launcher), off-grid `CONTEXT`/`POOL`,
`POOL < CONTEXT`, `CONTEXT` above 524288, and `TF_FILL_CHUNKS` combined with a non-zero interleave.

## The RAM left over after the weights

Read [`docs/spare-memory.md`](docs/spare-memory.md). **Nov 11 on the live Sparks:** SparkOne
`MemAvailable` 6.96–6.98 GiB, 1.23 GiB truly free, headroom about 2–3 GiB. SparkTwo 8.59 GiB.
The live prompt cache was full (512 MiB, 121 evictions, 95.2% prefix hits, average TTFT 1.77 s).
With that headroom:

- **It cannot buy bits.** EXL3 2.9 bpw is fixed in the checkpoint; no runtime path upcasts trellis
  tensors into spare RAM. The only precision path is the EAQ v1.1 pack (27 indexer/compressor
  linears as BF16) — a pack swap that changes the bits and invalidates the `exact.py` baseline.
- **It cannot raise decode tok/s.** Decode depends on rows per round, drafts and bandwidth.
- **It can buy residency.** `POOL` costs ~1 GiB a rank per 1M positions replicated (~0.55 sharded).
  More pool keeps more conversations resident, so follow-ups resume instead of re-prefilling.

```bash
make plan                 # defaults to SparkOne's 6.97 GiB MemAvailable; the trial pool stays at 1M
make profile NAME=tf127-replay
scripts/engine-trial.sh --guard-only --profile profiles/tf127-replay.env
```

`scripts/memory-plan.sh` keeps the trial at the live 1,048,576-position pool. Four engine
slots and the session store need it, and raising it to 2,097,152 spends the page cache.
The profiles cap `TF_DSV41_SESSION_RESIDENT_GIB` at 3 (fallback 2) and leave the 12.2 GiB
engine reserve alone. Engram reads use the page cache. `GRAPH_CAP=128` stays the fork bound;
the v1.2.7 profiles do not set it.

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

The family was rewritten upstream. At v1.2.7 (`93a2e93ece`) `deepseek_v41` has **358** files
against the fork's **62** under `dsv41`. **10 basenames are shared** (`model.zig`, `prompt.zig`,
`engram.zig`, `lanes.zig`, `weights.zig`, and five others) and those files are rewritten; sharing
a name is not a patch that applies. **0 of 18** fork switch names (`TF_DS_*`, `TF_FILL_*`,
`TF_RDMA_*`) occur in the v1.2.7 tree; upstream's names are `TF_DSV41_*`. `make triage`
reproduces the patch count. The old "28 family + 24 server" split double-counted four patches
and dropped five. See [`docs/port-status.md`](docs/port-status.md).

## Layout

```
docs/first-token.md      TTFT playbook: ranked levers, mechanism, cost, measurement protocol
docs/quantization.md     2.9 bpw invariant, EAQ v1 vs v1.1, what must re-baseline
docs/spare-memory.md     what the RAM left after the weights can and cannot buy
docs/port-status.md      v1.2.7 triage, why 52/53 are blocked, validation gate
docs/trial-runbook.md    side image, stop-live, matched gate, rollback
profiles/*.env           layered presets, validated against config.sh/port.sh
tools/ttft.py            TTFT on port 8890; refuses 8888 and 18004
tools/bench.py           same guard, then the recipe bench
scripts/trial.sh         start path for the current recipe pin (distinct container, tag, port, host)
scripts/engine-trial.sh  start path for the v1.2.7 image
scripts/gate.sh          on-hardware gate: TTFT, restore, 4-stream, exact.py, MemAvailable floor
scripts/profile.sh       write profiles/<name>.env into the recipe's local.sh
scripts/check-profiles.sh validate keys, grid, CONTEXT <= 524288, fill vs interleave
scripts/memory-plan.sh   KV-pool budget from the free GiB you actually see
scripts/triage.sh        re-run the 53-patch triage against any tag
recipe-tf-fbbc971/       the recipe verbatim at c7f2b85 (reference + runnable engine)
triage.csv               machine-readable triage
Makefile                 one command per job
```

## Licensing

Recipe and TensorFold are Apache-2.0; see `recipe-tf-fbbc971/LICENSE`, `NOTICE` and `CREDITS.md` for
the authors of each patch. This repository adds profiles, tooling and documentation only. No
affiliation with Mia's AI Lab, BertholomusAI, or TensorFold.
