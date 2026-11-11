# The 9 GiB left on each Spark: what it can and cannot buy

Short answer: **it cannot buy bits, and it cannot raise decode tok/s.** What it *can* buy is
residency — more kept conversations staying in the pool — which lowers first-token latency on
follow-ups and lets more long requests run at once.

## Why spare RAM cannot raise precision

EXL3 2.9 bpw is baked into the checkpoint. The trellis weights are stored at 2.9 bits and decoded by
fixed kernels; a rank loads exactly what the pack holds. There is no runtime path that upcasts a
trellis tensor to BF16 because there happens to be free memory — the rank cache is planned from the
checkpoint's headers at preparation time, not at boot.

The packs that exist for this model are all 2.9 bpw:

| Pack | Revision | Note |
|---|---|---|
| `Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw` | `45ee5d0f` | default, 39 shards, ~196 GiB |
| `Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1.1-2.9-bpw` | `aee640e2` | opt-in, `EAQ_V1_1=1` |
| `Mia-AiLab/DeepSeek-V4.1-Flash-EXL3-2.9bpw` | earlier | the pack whose widths EAQ matches |

There is no 3.x or 4.x bpw pack published for this model, so "raise the bit" is not a setting. See
[`quantization.md`](quantization.md).

### The one precision path, and what it actually is

EAQ v1.1 stores **27 indexer/compressor linears** as BF16 instead of trellis — 8 `attn.wq_a`,
8 `attn.indexer.wq_b`, 4 `attn.compressor.wkv`, 3 `attn.compressor.wgate`, 4 `attn.indexer.wk`. It
prints `mixed pack: 27 float linears` at load. That is a **pack swap**, not spare-RAM spending:

- It is a separate ~196 GiB download and a one-time prepared-folder rebuild (~10.5 min first boot
  at TP=2 on two GB10s, ~5 min after — TensorFold 1.2.6, #2325).
- It **changes the bits**, so the recorded `tools/exact.py` 31-case baseline is invalid until you
  record a new one.
- It is labelled experimental, and `ABLIT=1` is refused with it.
- It improves precision on those 27 small tensors only. It is not a global 3.5 bpw.

If your goal is "more precision somewhere", this is the only sanctioned way to get it, and the
spare 9 GiB is not what enables it — disk and a re-baseline are.

## What spare RAM is actually good for: the KV pool

`POOL` is the positions that streams' extents and kept prompts share. Its KV caches are host memory
in the unified pool, at roughly **0.85–1.0 GiB per rank per 1,048,576 positions** replicated, or
about **0.5 GiB** with `KV_SHARD=1` (measured at 2,101,248 positions: 1,783 MiB replicated against
1,062 MiB sharded).

More pool means:

- **more kept prompt states survive** → a follow-up resumes instead of re-prefilling → lower TTFT
  (the resume path measured 1.5–1.9 s against a cold prefill);
- **more long requests run at once** — the recipe's documented case is four concurrent
  500,601-token prompts in a 2,097,152-position pool;
- **fewer evictions** under a mix of long and short conversations.

It does **not** make decode faster. Decode rate depends on rows per round, drafts and bandwidth, not
on how much KV you keep.

### The budget for 9 GiB free

Reserve before spending:

| Item | GiB |
|---|---|
| `MEMGUARD_GIB` floor (a kill needs to stay under it for `MEMGUARD_HOLD_S`) | 2.5 |
| Slack for the head's desktop and containers | ~1.0 |
| **Spendable** | **~5.5** |

| `POOL` | Replicated | Sharded (`KV_SHARD=1`) | Headroom left | Note |
|---|---|---|---|---|
| 1,048,576 | ~1.0 | ~0.55 | ~8.0 | the window only; kept states evict early |
| **2,097,152** | **~2.0** | ~1.1 | **~7.0** | **documented for 4 concurrent 500K prompts** |
| 4,194,304 | ~4.0 | ~2.2 | ~5.0 | only if you routinely hold >4 long conversations |
| 6,291,456 | ~6.0 | ~3.3 | ~3.0 | tight; memguard territory |
| 8,388,608 | ~8.0 | ~4.4 | ~1.0 | below the memguard floor — do not |

**Recommendation: `POOL=2097152` with `KV_SHARD=0`.** It is the documented four-stream case, costs
~2 GiB a rank, keeps ~7 GiB of headroom, and avoids KV sharding's 1–4% decode penalty entirely —
with 9 GiB spare you do not need the memory sharding buys.

Go to `POOL=4194304` only if you routinely hold more than four long conversations. Beyond ~4M the
typical working set is already resident, and every extra GiB is headroom you gave away.

Use `scripts/memory-plan.sh 9` to re-run this table for whatever you actually see free.

## The rest of the 9 GiB: leave it alone

- **Engram page cache.** Free RAM is not wasted: Engram reads go through the page cache, and the
  recipe records prefill at ~690–890 tok/s over NFS against ~2.1K locally. The kernel uses free RAM
  automatically; pinning it into the pool takes that cache away.
- **`GRAPH_CAP`.** Keep 128. Decode equals uncapped graphs at 128, and each captured graph costs
  device memory plus ~1.6× as much host memory. Raising it buys nothing and spends RAM.
- **`TENSORFOLD_MEMORY_RESERVE_GIB`.** Do not lower it. The recipe's note is explicit: the engine
  then takes the reserve too, and a rank 0 with a 10 GiB reserve froze its Spark.
- **`CONTEXT`.** On a head that runs a desktop and containers, 524,288 is the practical limit. The
  recipe records a 464K-token head kill at 655,360.

## If you want speed instead of residency

Spare RAM is the wrong resource for decode speed. Decode levers are drafts and rows per round
(`DRAFTS`, `TF_DS_T25_DRAFT_CAL`, `ROUND_ROWS`), and the TTFT levers are in
[`first-token.md`](first-token.md) — Engram locality first, then resume, spill and prompt rows.
