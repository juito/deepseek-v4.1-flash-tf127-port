# Quantization: keep 2.9 bpw, change nothing about the bits

Every speed lever in [`first-token.md`](first-token.md) is **scheduling** — chunk sizes, where a
read comes from, which kernel a shape takes. None of them touch the weights. That is deliberate: the
whole point of keeping 2.9 bpw is that the recorded reply baseline stays valid.

## The invariant

| | |
|---|---|
| Default pack | `Mia-AiLab/DeepSeek-V4.1-Flash-1017-EXL3-EAQ-v1-2.9-bpw` @ `45ee5d0f` |
| Shards | 39, ~196 GiB |
| Format | EXL3, 2.9 bits per weight, EAQ v1 |
| Reply baseline | `tools/exact.py`'s 31 recorded token-hash cases were taken on **EAQ v1** |

`zig/patches/0024`–`0026` (mixed-pack loader, BF16 widen, plain rows) exist for EAQ **v1.1** and are
inert on v1: an EXL3-only pack plans no plain entries and runs exactly as before. That is why the
same image can serve both.

## EAQ v1.1 is not "the same bits"

| | EAQ v1 (default) | EAQ v1.1 (opt-in, `EAQ_V1_1=1`) |
|---|---|---|
| Revision | `45ee5d0f` | `aee640e2` |
| Widths | EXL3 2.9 bpw | same widths |
| Difference | — | **27 indexer/compressor linears stored as BF16** (8 `attn.wq_a`, 8 `attn.indexer.wq_b`, 4 `attn.compressor.wkv`, 3 `attn.compressor.wgate`, 4 `attn.indexer.wk`) |
| Bits | — | **different**; the load prints `mixed pack: 27 float linears` |
| `tools/exact.py` | 31/31 baseline valid | **baseline invalid** — record a new one before comparing |
| `ABLIT=1` | works | refused |

v1.1 is labelled experimental in the recipe and is a *precision* change, not a speed change. If you
want "2.9 or greater" in the sense of more precision, v1.1 is the only sanctioned option — but it
costs you the reply baseline and it is not a TTFT lever. How long the prepared folder takes to
rebuild for that pack swap is **unmeasured**. TensorFold 1.2.6 `#2325` (~10.5 min, then ~5 min)
is a prepared-folder rebuild on an engine upgrade, not this swap.

## What a speed change must prove

1. `tools/exact.py` — 31 cases, token hashes identical to the recorded baseline. This is the only
   proof that the bits did not move.
2. `tools/smoke.py` — health, stop strings, streaming, a tool call and its result.
3. `tools/bench.py --compare before.json after.json` — prefill, decode, multi-stream, needle.

A setting that improves TTFT and fails `exact.py` is a regression, not an optimization.

## Where bits legitimately change

One place only: **a different pack** — EAQ v1.1, a new bpw, or `ABLIT=1`'s overlay. All of them must
be re-baselined before any comparison. The overlay's graft also had to give four MTP tensors their
stock F16 bytes back (`scripts/ablit_stock_dtypes.py`); with the F32 copy the confidence head
computed garbage and ABLIT drafted 0.2–0.8 tokens a round.

A kernel change is the other theoretical risk, but the only wider-row path (`ROUND_ROWS=32`) is not
reachable on the pinned kit: no `_rowmm_parts` specialization above 16 exists, `start.sh` rejects the
value, and the recipe records no DeepSeek-V4.1 measurement for it (wider kernels are under review in
#31). Do not assume a number here.
