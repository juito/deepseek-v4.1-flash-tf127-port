# Port status: DeepSeek-V4.1-Flash-1017 onto TensorFold v1.2.7

**Status: not deployable.** This repository is the triage and scaffolding for moving the
2x DGX Spark recipe from BertholomusAI's fork to upstream TensorFold v1.2.7. Nothing here
builds, serves, or has been measured. Do not point `start.sh` at it.

## Verified baseline

| | |
|---|---|
| Recipe pin today | `bertholomus/TensorFold` @ `fbbc97132c` (branch `deepseek-v41-zig`, 2026-10-24) |
| Fork merge base with upstream | TensorFold **1.0.2** (`f8fe17d246`, 2026-10-07) |
| Target | upstream **v1.2.7** (`93a2e93ece`, 2026-11-11) |
| Upstream commits the pin is missing | **6,958** |
| Fork-only commits on that base | **140** |
| Recipe patch series | **53** patches in `zig/patches/` |
| Patches that apply to v1.2.7 | **1** (`0029-anthropic-budget-default`) |
| Patches blocked | **52** |

## Why the series does not rebase

This is not a version bump. The DeepSeek-V4.1 family was rewritten upstream:

| | fork `dsv41` | upstream `deepseek_v41` |
|---|---|---|
| Directory | `zig/src/families/dsv41/` | `zig/src/families/deepseek_v41/` |
| Files | 62 | 243 |
| Filenames shared | — | **0** |

Every file the patches edit by name (`model.zig`, `prompt.zig`, `engram.zig`, `lanes.zig`,
`rdma.zig`, `round.zig`, `weights.zig`, `checkpoint.zig`, `native.zig`) has no counterpart.
The upstream family is built from `block_*.zig`, `batch_*.zig` and `aot_*.zig` modules instead.

None of the recipe's DeepSeek switches survive upstream either — **0 of 18** are present:

`TF_DS_IDX_SPLIT`, `TF_DS_ENGRAM_LEAD`, `TF_FILL_CHUNKS`, `TF_FILL_CUT_IN`, `TF_DS_POOL`,
`TF_DS_WINDOW`, `TF_DS_GRAPH_CAP`, `TF_DS_KV_SHARD`, `TF_DS_SPILL*`, `TF_DS_PROMPT_WINDOW_ROWS`,
`TF_DS_PROMPT_GEMM_ROWS`, `TF_DS_T25_DRAFT_CAL`, `TF_DS_PLAIN_ROWS`, `TF_DS_LOAD_PREFETCH`,
`TF_DS_CONNECT_S`, `TF_RDMA_IDLE_S`, `TF_RDMA_NAP_US`, `TF_DS_RDMA_CPUS`.

The kit tooling the recipe shells out to is also gone from upstream: no `tf-dsv41-rank-cache`,
no `make_token_map.py`, no `make_rope.py`, no `tools/dsv41-zig/build_kit.sh`.
`prepare.sh` depends on all of them.

## Patch triage

Reproduce with `scripts/triage.sh`. Cumulative application in filename order, as `zig/Dockerfile` does.

| Patch | Status | Switches introduced | First path touched |
|---|---|---|---|
| `0001-c7-indexer-split.patch` | blocked | `TF_DS_IDX_SPLIT` | `zig/src/families/dsv41/model.zig` |
| `0004-call-gate.patch` | blocked | — | `--- /dev/null` |
| `0005-prefill-interleave.patch` | blocked | `TF_DS_PREFILL_INTERLEAVE_MS`, `TF_FILL_CHUNKS`, `TF_PREFILL_INTERLEAVE_MS` | `zig/src/core/lane_host.zig` |
| `0008-pool-window.patch` | blocked | `TF_DS_POOL`, `TF_DS_WINDOW` | `--- /dev/null` |
| `0010-rdma-idle-nap.patch` | blocked | `TF_RDMA_IDLE_S`, `TF_RDMA_NAP_US` | `zig/src/families/dsv41/rdma.zig` |
| `0011-cuda-budget-parked-pages.patch` | blocked | — | `zig/src/native/cuda_memory.zig` |
| `0012-dsv41-base-fixes.patch` | blocked | `TF_RDMA_NAP_US` | `zig/src/families/dsv41/model.zig` |
| `0013-core-spill-store.patch` | blocked | `TF_DS_KV_SHARD`, `TF_SPILL_TEST_DIR` | `--- /dev/null` |
| `0014-core-cache-tier.patch` | blocked | `TF_SPILL_`, `TF_SPILL_FLUSH_MS`, `TF_SPILL_LOAD_MS`, `TF_SPILL_LOAD_WAIT_MS` | `--- /dev/null` |
| `0015-dsv41-kv-shard-attn.patch` | blocked | `TF_DS_`, `TF_DS_IDX_SPLIT`, `TF_DS_KV_SHARD`, `TF_DS_KV_SHARD_DECODE` | `--- /dev/null` |
| `0016-dsv41-spill-blocks.patch` | blocked | `TF_DS_`, `TF_DS_ABLATION_ID`, `TF_DS_BUILD_FLAGS`, `TF_DS_ENGINE_ID` | `--- /dev/null` |
| `0017-dsv41-kit-row-split.patch` | blocked | `TF_DS_KIT`, `TF_DS_ROUND_ROWS`, `TF_DS_TRITON_PDL` | `--- /dev/null` |
| `0018-dsv41-kv-shard-lanes.patch` | blocked | `TF_DS_`, `TF_DS_KV_SHARD`, `TF_DS_KV_SHARD_CARRY`, `TF_DS_KV_SHARD_CHECK` | `--- /dev/null` |
| `0019-dsv41-spill-kv-shard.patch` | blocked | `TF_DS_`, `TF_DS_ABLATION_ID`, `TF_DS_BUILD_FLAGS`, `TF_DS_ENGINE_ID` | `zig/src/core/lanes/kv_parts.zig` |
| `0020-dsv41-pair-broken.patch` | blocked | `TF_DS_KV_SHARD`, `TF_DS_PAIR_BROKEN`, `TF_DS_SPILL_DIR`, `TF_RDMA_DEVICES` | `--- /dev/null` |
| `0021-dsv41-spill-pictures.patch` | blocked | `TF_DS_IMAGE_CACHE` | `--- /dev/null` |
| `0022-dsv41-kv-shard-ring.patch` | blocked | `TF_DS_`, `TF_DS_CLOCK_MARKS`, `TF_DS_COLLECT_THREADS`, `TF_DS_EMULATE` | `--- /dev/null` |
| `0023-server-prepare-memory.patch` | blocked | — | `--- /dev/null` |
| `0024-mixed-pack.patch` | blocked | — | `zig/src/families/dsv41/prompt.zig` |
| `0025-widen-bf16.patch` | blocked | — | `zig/src/families/dsv41/checkpoint.zig` |
| `0026-plain-rows.patch` | blocked | `TF_DS_PLAIN_ROWS`, `TF_DS_ROUND_ROWS` | `zig/src/families/dsv41/model.zig` |
| `0027-tool-call-prose.patch` | blocked | — | `zig/src/server/openai.zig` |
| `0028-plain-request-text.patch` | blocked | — | `zig/src/core/tokenizer/tokenizer.zig` |
| `0029-anthropic-budget-default.patch` | applies | — | `zig/src/server/anthropic_translate.zig` |
| `0030-anthropic-context-management-lenient.patch` | blocked | — | `zig/src/server/anthropic_translate.zig` |
| `0031-anthropic-system-anywhere.patch` | blocked | — | `zig/src/server/anthropic_translate.zig` |
| `0032-stream-keepalive-ping.patch` | blocked | — | `zig/src/server/anthropic.zig` |
| `0033-graph-cap.patch` | blocked | `TF_DS_GRAPHS`, `TF_DS_GRAPH_CAP` | `--- /dev/null` |
| `0034-rebase-followups.patch` | blocked | — | `zig/src/core/lane_host.zig` |
| `0035-engram-lead-failure-paths.patch` | blocked | `TF_DS_ENGRAM_LEAD` | `zig/src/families/dsv41/engram_aio.zig` |
| `0036-metrics-cached-prompt-tokens.patch` | blocked | — | `--- /dev/null` |
| `0037-rendezvous-ports-early.patch` | blocked | `TF_DS_CONNECT_S` | `zig/src/families/dsv41/link.zig` |
| `0038-aligned-index-views.patch` | blocked | — | `zig/src/families/dsv41/prompt.zig` |
| `0040-restore-room.patch` | blocked | `TF_FILL_CHUNKS`, `TF_FILL_CUT_IN`, `TF_SPILL_LOAD_WAIT_MS` | `zig/src/core/engine_api.zig` |
| `0041-service-between-pieces.patch` | blocked | `TF_FILL_CHUNKS` | `zig/src/core/lane_host_tier_test.zig` |
| `0042-kv-shard-pieces.patch` | blocked | `TF_DS_KV_SHARD` | `zig/src/families/dsv41/kv_lanes.zig` |
| `0043-picture-resume-skip.patch` | blocked | — | `zig/src/families/dsv41/lanes.zig` |
| `0045-cut-in-tail.patch` | blocked | — | `zig/src/core/lane_host_reuse_test.zig` |
| `0046-server-get-delete-body-discard.patch` | blocked | — | `zig/src/server/routes.zig` |
| `0047-replayed-reasoning.patch` | blocked | — | `zig/src/server/messages.zig` |
| `0048-stream-tool-calls.patch` | blocked | — | `--- /dev/null` |
| `0049-first-draft-depth.patch` | blocked | — | `zig/src/core/lanes/depth.zig` |
| `0050-draft-calibration.patch` | blocked | `TF_DS_T25_CAL_LOG`, `TF_DS_T25_DRAFT_CAL` | `--- /dev/null` |
| `0051-prompt-rows.patch` | blocked | `TF_DS_PROMPT_GEMM_ROWS`, `TF_DS_PROMPT_WINDOW_ROWS` | `--- /dev/null` |
| `0056-server-picture-prepare-scratch.patch` | blocked | — | `zig/src/server/prompt.zig` |
| `0057-drop-reasoning-history.patch` | blocked | — | `zig/src/server/cli.zig` |
| `0058-responses-include-encrypted.patch` | blocked | — | `--- /dev/null` |
| `0059-lane-thread-binds-context.patch` | blocked | — | `zig/src/core/lane_host_tier_test.zig` |
| `0064-dsml-opener-short-payload.patch` | blocked | — | `zig/src/server/dsml_stream_test.zig` |
| `0065-dsml-value-holds-closer.patch` | blocked | — | `--- /dev/null` |
| `0066-load-prefetch.patch` | blocked | `TF_DS_LOAD_PREFETCH` | `zig/src/families/dsv41/weights.zig` |
| `0067-orphan-dsml-closer-diagnostic.patch` | blocked | — | `--- /dev/null` |
| `0068-rdma-proxy-cpus.patch` | blocked | `TF_DS_RDMA_CPUS` | `zig/src/families/dsv41/model.zig` |

## What has to be reimplemented

**Family-side (28 patches).** These edit fork-only files, so they are rewrites against the
new `deepseek_v41` modules, not rebases:

`0001-c7-indexer-split.patch`, `0005-prefill-interleave.patch`, `0008-pool-window.patch`, `0010-rdma-idle-nap.patch`, `0012-dsv41-base-fixes.patch`, `0015-dsv41-kv-shard-attn.patch`, `0016-dsv41-spill-blocks.patch`, `0017-dsv41-kit-row-split.patch`, `0018-dsv41-kv-shard-lanes.patch`, `0019-dsv41-spill-kv-shard.patch`, `0020-dsv41-pair-broken.patch`, `0021-dsv41-spill-pictures.patch`, `0022-dsv41-kv-shard-ring.patch`, `0024-mixed-pack.patch`, `0025-widen-bf16.patch`, `0026-plain-rows.patch`, `0033-graph-cap.patch`, `0035-engram-lead-failure-paths.patch`, `0037-rendezvous-ports-early.patch`, `0038-aligned-index-views.patch`, `0040-restore-room.patch`, `0042-kv-shard-pieces.patch`, `0043-picture-resume-skip.patch`, `0045-cut-in-tail.patch`, `0050-draft-calibration.patch`, `0051-prompt-rows.patch`, `0066-load-prefetch.patch`, `0068-rdma-proxy-cpus.patch`

**Server-side (24 patches).** These touch `zig/src/server/*`, which exists upstream and has
merely drifted. They are the cheapest to land and the most worth doing first, because they are
correctness fixes clients notice (`0027` tool-call prose, `0028` plain request text, `0030`/`0031`
Anthropic context, `0032` keep-alive, `0046` GET/DELETE body, `0047` replayed reasoning,
`0048` streamed tool calls, `0058` responses include, `0064`/`0065` DSML parsing):

`0004-call-gate.patch`, `0014-core-cache-tier.patch`, `0018-dsv41-kv-shard-lanes.patch`, `0019-dsv41-spill-kv-shard.patch`, `0020-dsv41-pair-broken.patch`, `0021-dsv41-spill-pictures.patch`, `0023-server-prepare-memory.patch`, `0027-tool-call-prose.patch`, `0028-plain-request-text.patch`, `0029-anthropic-budget-default.patch`, `0030-anthropic-context-management-lenient.patch`, `0031-anthropic-system-anywhere.patch`, `0032-stream-keepalive-ping.patch`, `0034-rebase-followups.patch`, `0036-metrics-cached-prompt-tokens.patch`, `0046-server-get-delete-body-discard.patch`, `0047-replayed-reasoning.patch`, `0048-stream-tool-calls.patch`, `0056-server-picture-prepare-scratch.patch`, `0057-drop-reasoning-history.patch`, `0058-responses-include-encrypted.patch`, `0064-dsml-opener-short-payload.patch`, `0065-dsml-value-holds-closer.patch`, `0067-orphan-dsml-closer-diagnostic.patch`

## What 1.2.7 actually gives DeepSeek-V4.1

Nothing in the 1.2.6 or 1.2.7 release notes claims a decode speedup for this model. The
headline speed numbers belong to GLM-5.3-Flash at TP=2 on two GB10s, Qwen on CUDA/HIP, and
Metal/HIP work. The DeepSeek-V4.1 entries are correctness and tooling:

- 1.2.6: prepared folders rebuild once on upgrade (~10.5 min first boot at TP=2 on two GB10s,
  ~5 min later) — `#2325`
- 1.2.6: Engram shards on disks needing more than 512-byte direct reads are read through the
  page cache instead of failing — `#2610`
- 1.2.7: `tp.device` runs TP ranks as threads and checks DeepSeek-V4.1 exchanges bit-for-bit at
  worlds 1–4; serving still refuses 3 ranks — `#2491`

So the port buys maintainability and a correctness fix, not tokens per second. Any decode gain
has to come from re-landing the family-side patches (`0033` graph cap, `0050` draft
calibration, `0051` prompt rows, `0017` 32-row kit split, `0066` load prefetch) on the new
engine — and each of those has to be measured, not assumed.

## Validation gate

A port is only acceptable when all of these pass on the pair:

1. `zig build dsv41-test` and the engine host tests (no GPU needed).
2. `tools/exact.py` — 31 recorded token-hash cases identical to the current image.
3. `tools/smoke.py`, `tools/prompt_reuse.py`, `tools/toolcheck.py`, `tools/needle.py`.
4. `tools/bench.py` with `--compare old.json new.json` for prefill, decode, multi-stream.
5. One `./start.sh restart` after the prepared-folder rebuild, watching `memguard`.
