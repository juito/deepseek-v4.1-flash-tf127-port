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

| | fork `dsv41` @ `fbbc971` | upstream `deepseek_v41` @ v1.2.7 `93a2e93ece` |
|---|---|---|
| Directory | `zig/src/families/dsv41/` | `zig/src/families/deepseek_v41/` |
| Files | 62 | **358** |
| Basenames shared | | **10** |

The shared basenames are `config.zig`, `draft.zig`, `engram.zig`, `engram_io.zig`, `lanes.zig`,
`model.zig`, `plan.zig`, `prompt.zig`, `sampling.zig`, `weights.zig`. They are rewritten files
that happen to keep the name. A shared basename is not a patch that applies: `git apply` of the
series against v1.2.7 still lands **1 of 53**. The earlier "243 files, zero shared filenames"
count was not reproduced on this tag.

`rdma.zig`, `round.zig`, `checkpoint.zig` and `native.zig` are among the fork names with no
upstream basename. Most of the upstream family is `block_*.zig`, `batch_*.zig` and `aot_*.zig`.

None of the recipe's DeepSeek switch **names** survive upstream. Grepping `zig/src` at v1.2.7
finds **0** hits for all 18:

`TF_DS_IDX_SPLIT`, `TF_DS_ENGRAM_LEAD`, `TF_FILL_CHUNKS`, `TF_FILL_CUT_IN`, `TF_DS_POOL`,
`TF_DS_WINDOW`, `TF_DS_GRAPH_CAP`, `TF_DS_KV_SHARD`, `TF_DS_SPILL`, `TF_DS_PROMPT_WINDOW_ROWS`,
`TF_DS_PROMPT_GEMM_ROWS`, `TF_DS_T25_DRAFT_CAL`, `TF_DS_PLAIN_ROWS`, `TF_DS_LOAD_PREFETCH`,
`TF_DS_CONNECT_S`, `TF_RDMA_IDLE_S`, `TF_RDMA_NAP_US`, `TF_DS_RDMA_CPUS`.

Upstream's DeepSeek variables are `TF_DSV41_*` (hundreds of them). These are the nearest
names, recorded from that tree. They are **not** renames, and nothing here has checked that
the behavior matches:

| Fork name (fbbc971) | In v1.2.7 `zig/src`? | Nearest upstream name |
|---|---|---|
| `TF_FILL_CHUNKS`, `TF_FILL_CUT_IN`, `TF_FILL_ROUNDS`, `TF_FILL_FIRST` | absent (no `TF_FILL_` at all) | `TF_DSV41_PREFILL_PIECES` is a host piece planner; `TF_DSV41_PREFILL_CHUNK` / `TF_DSV41_PREFILL_ROWS` size a segment. Not the cut-in switch |
| `TF_DS_PREFILL_INTERLEAVE_MS` | absent | no interleave millisecond switch found |
| `TF_DS_POOL` | absent | `TF_DSV41_POOL_TOKENS` (paged pool; unset means no pool) |
| `TF_DS_WINDOW` | absent | `TF_DSV41_CONTEXT` (slot positions) |
| `TF_DS_GRAPH_CAP` | absent | `TF_DSV41_GRAPHS_MAX` |
| `TF_DS_KV_SHARD` | absent | `TF_DSV41_KV_SPLIT` |
| `TF_DS_SOLO_OVERHEAD`, `TF_DS_NO_COPIES` | absent (both are read in the fork's `lanes.zig` / `native.zig`) | no match |
| spill tier / prefix resume | different mechanism | `TF_DSV41_PREFILL=replay` (`full` or `replay`, default `full`) together with `TF_DSV41_SESSION_DISK` |

`TF_DS_SOLO_OVERHEAD` and `TF_DS_NO_COPIES` count as on for any set value other than `0` on the
fork, an empty value included. That behavior is unverified on 1.2.7 because the names are not
there. Profiles that set `TF_FILL_*` or `TF_DS_*` are scheduling for the **current** pin. Do not
copy those names onto a v1.2.7 binary and expect the same lever.

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

The old "28 family + 24 server" split double-counted `0018`–`0021` (each touches both
`zig/src/families/dsv41/` and `zig/src/server/`) and omitted `0011`, `0013`, `0041`, `0049`,
and `0059`. Recomputed from `triage.csv` by the files each patch names. 53 patches, each once:
24 + 20 + 4 + 5.

**Family-only (24).** Touch `zig/src/families/dsv41/` (or the dsv41 kit/kernels) and not
`zig/src/server/`. Rewrites against `deepseek_v41`, not rebases:

`0001-c7-indexer-split.patch`, `0005-prefill-interleave.patch`, `0008-pool-window.patch`, `0010-rdma-idle-nap.patch`, `0012-dsv41-base-fixes.patch`, `0015-dsv41-kv-shard-attn.patch`, `0016-dsv41-spill-blocks.patch`, `0017-dsv41-kit-row-split.patch`, `0022-dsv41-kv-shard-ring.patch`, `0024-mixed-pack.patch`, `0025-widen-bf16.patch`, `0026-plain-rows.patch`, `0033-graph-cap.patch`, `0035-engram-lead-failure-paths.patch`, `0037-rendezvous-ports-early.patch`, `0038-aligned-index-views.patch`, `0040-restore-room.patch`, `0042-kv-shard-pieces.patch`, `0043-picture-resume-skip.patch`, `0045-cut-in-tail.patch`, `0050-draft-calibration.patch`, `0051-prompt-rows.patch`, `0066-load-prefetch.patch`, `0068-rdma-proxy-cpus.patch`

**Server-only (20).** Touch `zig/src/server/` and not the family directory. These are the
cheapest to land and the most worth doing first, because several are correctness fixes clients
notice (`0027` tool-call prose, `0028` plain request text, `0030`/`0031` Anthropic context,
`0032` keep-alive, `0046` GET/DELETE body, `0047` replayed reasoning, `0048` streamed tool
calls, `0058` responses include, `0064`/`0065` DSML parsing):

`0004-call-gate.patch`, `0014-core-cache-tier.patch`, `0023-server-prepare-memory.patch`, `0027-tool-call-prose.patch`, `0028-plain-request-text.patch`, `0029-anthropic-budget-default.patch`, `0030-anthropic-context-management-lenient.patch`, `0031-anthropic-system-anywhere.patch`, `0032-stream-keepalive-ping.patch`, `0034-rebase-followups.patch`, `0036-metrics-cached-prompt-tokens.patch`, `0046-server-get-delete-body-discard.patch`, `0047-replayed-reasoning.patch`, `0048-stream-tool-calls.patch`, `0056-server-picture-prepare-scratch.patch`, `0057-drop-reasoning-history.patch`, `0058-responses-include-encrypted.patch`, `0064-dsml-opener-short-payload.patch`, `0065-dsml-value-holds-closer.patch`, `0067-orphan-dsml-closer-diagnostic.patch`

**Cross-cutting (4).** Touch both trees. Listed once, not in both lists above:

`0018-dsv41-kv-shard-lanes.patch`, `0019-dsv41-spill-kv-shard.patch`, `0020-dsv41-pair-broken.patch`, `0021-dsv41-spill-pictures.patch`

**Core / native (5).** Touch neither `zig/src/families/dsv41/` nor `zig/src/server/`. These
were the omitted patches:

`0011-cuda-budget-parked-pages.patch`, `0013-core-spill-store.patch`, `0041-service-between-pieces.patch`, `0049-first-draft-depth.patch`, `0059-lane-thread-binds-context.patch`

## What 1.2.7 actually gives DeepSeek-V4.1

Nothing in the 1.2.6 or 1.2.7 release notes claims a decode speedup for this model. The
headline speed numbers belong to GLM-5.3-Flash at TP=2 on two GB10s, Qwen on CUDA/HIP, and
Metal/HIP work. The DeepSeek-V4.1 entries are correctness and tooling:

- 1.2.6: prepared folders rebuild once on upgrade (~10.5 min to weights loaded on the first
  boot at TP=2 on two GB10s, ~5 min later) — `#2325`. That is the cost of an **upgrade's
  prepared-folder rebuild**, not the cost of swapping the EAQ pack. An EAQ pack swap's rebuild
  time is unmeasured here.
- 1.2.4: `TF_DSV41_PREFILL=replay` plus the NVMe session tier restores a saved conversation
  (a 319K-token one in 1.2–1.4 s instead of 155–178 s, replies byte-identical to a cold
  prefill) — `#2182`. That is upstream's replay mode. It is not the fork's in-memory prefix
  resume and it is not the fork's spill tier (`SPILL_GIB`). The fork already has both of those.
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
5. One trial start after the side image is built, watching `memguard`, then rollback to the
   untouched live container. The commands and the expected timings are
   [`trial-runbook.md`](trial-runbook.md). Do not point the recipe's `start.sh` at the live
   container name, the live tag, or port 8888.
