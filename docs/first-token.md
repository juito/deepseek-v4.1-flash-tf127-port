# First token (TTFT): the playbook

TTFT is what a user feels. On this pair it is **prefill time + queue wait + resume time**, and the
three have different fixes. Measure before changing anything; every number below is the recipe's own
measurement on a pair of Sparks (`recipe-tf-fbbc971/docs/measurements.md`), not a projection.

## Where the time actually goes

| Prompt | Prefill tok/s | TTFT |
|---|---|---|
| 4K | 2,105.9 | 2.13 s |
| 8K | 2,152.0 | 3.99 s |
| 16K | 2,154.8 | 7.78 s |
| 32K | 2,153.6 | 15.40 s |
| 64K | 2,136.2 | 30.86 s |
| 128K | 2,077.1 | 63.28 s |
| 256K | 2,065.0 | 127.13 s |

Prefill is flat at ~2.1K tok/s, so **TTFT is linear in prompt length** once the prefix cache misses.
That is why the wins below are ordered by how much of the prompt they avoid computing, not by how
fast they make a kernel.

## Ranked levers

| # | Lever | Mechanism | Expected direction | Cost / risk |
|---|---|---|---|---|
| 1 | **Engram tables on local disk on both Sparks** | Engram reads are per-chunk and per-round. Over NFS a random 4 KiB read measured **942 µs** against **90 µs** locally; the recipe records prefill falling to **~690–890 tok/s** over NFS | **2.4–3× lower TTFT** on cold prompts. This is the single largest lever | Needs ~203 GB local disk on each Spark. No bit change |
| 2 | **Prefix-cache resume** (already on) | A follow-up turn resumes the kept prompt state instead of recomputing | Turn 2+ TTFT drops from seconds to **1.5–1.9 s** (159K and 261K histories, 99–100% resumed) | None; it is the default. Verify with `tools/prompt_reuse.py` |
| 3 | **Spill tier** (`SPILL_GIB=64`) | Kept states written to each Spark's disk and restored beside decoding, also after a restart | A 237K-token conversation resumes in **1.7 s** against **118 s** recomputed | Disk quota; validate with `tools/exact.py` |
| 4 | **Short prompt cut-in** (`TF_FILL_CHUNKS=1`, `TF_FILL_CUT_IN=8192`) | A queued short prompt runs between another pass's pieces, sized by the tokens it computes past its kept state | A 1.5K-token turn of a 300K conversation **cuts in** instead of waiting for the whole pass | Needs the spill/KV path exercised; measure under load |
| 5 | **Prefill interleave** (`PREFILL_INTERLEAVE_MS=250`, the default) | Between chunks of a long pass, rank 0 decodes the other live streams and takes their cancels | A 120K cold prompt no longer freezes a chat: longest gap **1.3 s**, was 90 s; a cancel answered **0.74 s** | The long prompt's own TTFT rises ~8% (99 s vs 91 s) |
| 6 | **Prompt row width** (`TF_DS_PROMPT_WINDOW_ROWS=128`) | Chooses the MoE decode window for short prompt chunks instead of the prefill GEMM | **~40 ms off TTFT** for prompts of 64–127 tokens | Greedy replies unchanged (author's engine line) |
| 7 | **Indexer split** (on from token 131,072 by default) | Splits the prefill indexer's row blocks across the two ranks and all-gathers the selections | **+4.25% at 256K**, **+7.46% at 400K** cold prefill | Replies keep their bits |
| 8 | **`MAX_TOKENS` and `PARALLEL`** | Admission reserves `prompt + max_tokens + ROUND_ROWS + 2` per stream | Smaller reservations admit more streams, so fewer requests queue behind each other | Lower `MAX_TOKENS` truncates long thinking; clients can override per request |
| 9 | **`CONTEXT` on a busy head** | A smaller window means a smaller KV pool and less pressure on kept states | More kept states survive, so more turns resume instead of re-prefilling | Caps the longest prompt a request may use |
| 10 | **`ROUND_ROWS=32`** (a later `KIT_REF`) | A 32-row window needs a kit with `_rowmm_parts` variants above 16 | **Unproven for this model.** No DeepSeek-V4.1 measurement exists in the recipe; wider kernels are still under review (#31) | Not available on the pinned kit: `start.sh` rejects `ROUND_ROWS` above 16. Treat any claim about it as unmeasured |
| — | **`KV_SHARD=1`** | Splits the KV pool one part a Spark, halving KV memory | **Not a TTFT lever**: decode is 1–4% slower. It buys memory headroom, which indirectly protects kept states | Use it for context, not for TTFT |

## v1.2.7 trial, from the Nov 11 measurement

The fork levers above stay the comparison for `scripts/trial.sh` on the current pin. The
v1.2.7 profiles use different names, checked against tag `v1.2.7` (`93a2e93ece`):

| Profile | What it sets |
|---|---|
| `tf127-baseline.env` | `PARALLEL=4` and `TF_DSV41_SLOTS=4`, pool `1048576`, slot drafts and session slots on, `TF_DSV41_PREFILL=full`, resident cap 0.5 GiB. Fair match to the live shape: four agents, and the live prompt cache was 512 MiB, 121 evictions, 95.2% prefix hits, average TTFT 1.77 s |
| `tf127-replay.env` | `TF_DSV41_PREFILL=replay`, session disk on local NVMe, disk budget 64 GiB, resident cap **3 GiB on both ranks**. This is the TTFT trial. Upstream `#2182`: a 319K restore in 1.2–1.4 s against 155–178 s cold. That number is upstream's |
| `tf127-replay-2gib.env` | The same with the cap at 2 GiB, for a `MemAvailable` trough under 4 GiB |
| `tf127-pf4k.env` | Optional. `TF_DSV41_PF_4K=1` plus the memory acknowledgement, `TF_DSV41_GM_V2=1`, and replay. About **+0.66 GiB**. Token equality against replay before you keep it |
| `tf127-prefetch.env` | Optional. `TF_DSV41_PREFETCH_AHEAD=1` on the replay tier. Token equality against replay |
| `tf127-cut-in.env` | Replay plus `TF_DSV41_PREFILL_PIECES=1` and `TF_DSV41_PREFILL_CUT_IN=8192` (alias of `TF_DSV41_BATCH_SHORT`). Interleave 0 |
| `tf127-interleave.env` | The same pieces with `TF_DSV41_PREFILL_INTERLEAVE_MS=250` |

SparkOne's headroom is about 2–3 GiB (`MemAvailable` 6.96–6.98 GiB, 1.23 GiB truly free).
SparkTwo was 8.59 GiB. Do not lower the 12.2 GiB engine reserve. The pool stays at the
live **1,048,576** positions. Do not raise it to 2,097,152.
`CONTEXT` stays 524288. Live cold refs for the gate: 8k **13.80 s**, 131k **57.89 s**.
Four agents that day decoded at **102.7 tok/s** aggregate. A pass needs those four to
overlap, not merely to queue.

## What not to do

- **Do not requantize.** 2.9 bpw EAQ v1 is what the recorded `tools/exact.py` baseline was taken on.
  See [`quantization.md`](quantization.md).
- **Do not turn `GRAPHS` off to "simplify".** Graphs are a decode lever, and `GRAPH_CAP=128` already
  bounds them; uncapped graphs are what killed rank 0 via `memguard`.
- **Do not raise `CONTEXT` to the full 1,048,576 on a head that runs other software.** 524,288 is the
  practical limit there; the recipe records a 464K-token head kill at 655,360.
- **Do not set `CONTEXT`/`POOL` off the 4096 grid.** `start.sh` warns, and an off-grid cap gave the
  indexer a tile count the kit has no variant for (`MissingTritonVariant`, then `CudaFailed (901)`).

## Measuring it

`tools/ttft.py` is TTFT-only: it streams `max_tokens=1` requests at each prompt size and reports
p50/p90 for cold and warm prompts, plus a `--compare` table between two runs.

```bash
# cold TTFT across the ladder, 5 reps, JSON out
# default URL is http://127.0.0.1:8890; 8888 and 18004 are refused without --allow-live
source scripts/trial-env.sh
python3 -I tools/ttft.py --sizes 512,2048,8192,32768,131072 --reps 5 \
  --out runs/ttft-before.json --label before

# apply one arm, restart the trial (not the live container), measure again
scripts/profile.sh ttft-fill --force
scripts/trial.sh --stop-live restart
source scripts/trial-env.sh
python3 -I tools/ttft.py --sizes 512,2048,8192,32768,131072 --reps 5 \
  --out runs/ttft-after.json --label after

python3 -I tools/ttft.py --compare runs/ttft-before.json runs/ttft-after.json
```

The server for that measurement is the trial on port 8890. `tools/ttft.py` reads
`/metrics` and refuses to send a prompt while `requests_running` is not 0. There is no
`./start.sh` at the repository root. The procedure, including rollback of
`dsv41-1017-exl3-tf`, is [`trial-runbook.md`](trial-runbook.md).

Rules for a trustworthy number:

1. **Alternate, don't sequence.** Run before/after/after/before; a single before-then-after pair on a
   box that also runs a desktop will mislead you.
2. **Cold means cold.** `--salt` fixes the prompt set; omit it and each run gets fresh prompts so the
   prefix cache cannot answer for you. Report cold and warm separately.
3. **Fix the clocks.** Both GPUs at the same ceiling (`nvidia-smi -lgc 0,2200`); the ranks meet twice
   a layer, so the slower GPU sets the pace.
4. **Prove the replies did not move.** `tools/exact.py` must be 31/31 identical before you keep a
   setting. A TTFT win that changes tokens is not a win.
5. **Report p50 and p90.** One stream's median hides the queue.

## Presets

`profiles/` holds layered presets. They are hypotheses with a measurement attached, not
promises. `CONTEXT` is 524288 in all of them.

| Profile | For | What it sets |
|---|---|---|
| `ttft-fill.env` | Cut-in A/B arm | Local Engram, `MAX_TOKENS=8192`, prompt rows 128, `TF_FILL_CHUNKS=1`, `PREFILL_INTERLEAVE_MS=0` |
| `ttft-interleave.env` | Interleave A/B arm | The same scheduling with `PREFILL_INTERLEAVE_MS=250` and no `TF_FILL_*` |
| `balanced.env` | Day-to-day | Local Engram, `CONTEXT=524288`, spill on, interleave 250, `GRAPH_CAP=128` |
| `long-context.env` | More resident history | `POOL=2097152`, `KV_SHARD=1`, spill on, `GRAPH_CAP=128` |
| `residency.env` | Kept conversations | `POOL=2097152`, `KV_SHARD=0` |

`TF_FILL_CHUNKS` disables patch 0005, so one profile does not set both the fill knobs and a
non-zero interleave. Apply one with `scripts/profile.sh <name>`; it writes
`recipe-tf-fbbc971/scripts/local.sh` for the **trial** container, port, and host. `config.sh`
layers that file over the environment. Validate every key first with `scripts/check-profiles.sh`.
Start with `scripts/trial.sh`, not `./start.sh`.
