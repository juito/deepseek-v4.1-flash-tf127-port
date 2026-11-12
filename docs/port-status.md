# Port status: DeepSeek-V4.1-Flash-1017 onto TensorFold v1.2.7

**Status: not measured on GB10.** The tree has a v1.2.7 overlay (`engine/patches/`),
trial profiles, and a Spark build path. This VM has no GB10, so nothing here has served
a token. `scripts/trial.sh` still starts the current recipe pin. The v1.2.7 container is
`scripts/engine-trial.sh`. Do not point either at the live serve.

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
| `TF_DS_POOL` | absent | `TF_DSV41_POOL_TOKENS` (paged pool; unset means no pool, and then slots stay at 1 and sessions stay off) |
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

The Nov 11 TTFT plan is session replay on local NVMe with a resident cap, which is already
in v1.2.7 (`#2182`). It is not a requantize, and it is not a re-land of the family kernel
patches. Those stay dropped until a GB10 measurement says a specific one is worth the bit
risk. `docs/patch-map.csv` is the disposition of all 53. `triage.csv` stays the mechanical
`git apply` result (1 applies). The overlay includes the 0029 budget default, so
`scripts/fetch-engine.sh` applies only `engine/patches/` and does not also apply 0029.

## Nov 11 spare RAM (live Sparks, ~2 PM PST)

| | SparkOne | SparkTwo |
|---|---|---|
| `MemAvailable` | 6.96–6.98 GiB | 8.59 GiB |
| Truly free | 1.23 GiB | (the rest of SparkOne's available figure is Engram page cache and margin) |
| Headroom | about 2–3 GiB | higher than SparkOne; the pair is limited by SparkOne |

Memguard still kills at 2.5 GiB for 4 s, hard floor 1 GiB. `TENSORFOLD_MEMORY_RESERVE_GIB`
stays at the engine's own reserve. On unified memory that default is `max(4 GiB, total/10)`,
about 12.8 GiB on a 128 GiB Spark. A profile that sets the variable below 12.2 is refused.
Setting it to 12.2 would lower the default, so the profiles omit it.

`CONTEXT` stays 524288 in every profile. A 464K-token turn was killed at 655360. Never
1048576. The v1.2.7 slot default is 4096, so the profiles also set `TF_DSV41_CONTEXT=524288`.

The live prompt cache was full: 512 MiB, 121 evictions, 95.2% prefix hit rate, average TTFT
1.77 s. `tf127-baseline.env` uses prefill `full` and a 0.5 GiB resident cap so the comparison
matches that shape. The main trial is `tf127-replay.env`: `TF_DSV41_PREFILL=replay`,
`TF_DSV41_SESSION_DISK` on local NVMe, `TF_DSV41_SESSION_DISK_GIB=64`,
`TF_DSV41_SESSION_RESIDENT_GIB=3` on both ranks. Unset residency is unlimited
(`sessions_gpu.zig`). A mismatch refuses both ranks (`session_budget.zig`). If the
`MemAvailable` trough is under 4 GiB, use `tf127-replay-2gib.env`.

Four agents is a separate requirement from TTFT. `--parallel 4` is only the HTTP cap.
`cuda_model.Options` has no `lanes` field, and `LaneHost` is opened with
`lanes = TF_DSV41_SLOTS` (default 1). A second request then hits `TooManySlots` or waits.
Every v1.2.7 profile therefore sets `TF_DSV41_SLOTS=4`, `TF_DSV41_SLOT_DRAFTS=1` (DSpark
on every slot), and `TF_DSV41_SESSION_SLOTS=1` (the store turns off above one slot without
it; upstream notes that path has not been checked on hardware). Slots above 1 need the
paged pool (`RowsNeedPool` / `SlotsNeedPool`). The profiles set `TF_DSV41_POOL_TOKENS=1048576`,
the live 1M pool already inside the Nov 11 `MemAvailable` reading. They do not raise it to
2,097,152. `scripts/gate.sh` aborts unless `tensorfold:lanes` is 4, and a pass needs all
four decode streams to finish with the aggregate above the fastest stream and within 5% of
102.7 tok/s.

Weights stay EAQ v1 @ `45ee5d0f` (KL 0.0137, top-1 96.6%). v1.2.7 has no mixed-pack loader.
`EAQ_V1_1` and `ABLIT` are refused by `scripts/check-profiles.sh`.

`TF_DSV41_PF_4K=1` needs `TF_DSV41_PF_4K_MEMORY_OK=1`, `TF_DSV41_GM_V2=1` (or `split`), and
`TF_DSV41_PREFILL=replay`. Upstream's own warning is about 0.66 GiB more worker memory.
`TF_DSV41_PREFETCH_AHEAD=1` is the other optional knob. Both are separate profiles and need
token equality against replay. `#2182` reports a 319K restore in 1.2–1.4 s against 155–178 s,
replies byte-identical. That is upstream's measurement.

## What was checked here

Env names were read from the v1.2.7 tree at `93a2e93ece` before they were written into
profiles: `TF_DSV41_PREFILL`, `TF_DSV41_SESSION_DISK`, `TF_DSV41_SESSION_DISK_GIB`,
`TF_DSV41_SESSION_RESIDENT_GIB`, `TF_DSV41_PF_4K`, `TF_DSV41_PF_4K_MEMORY_OK`,
`TF_DSV41_GM_V2` (`0`, `1`, `split`), `TF_DSV41_PREFETCH_AHEAD`, `TF_DSV41_PREFILL_PIECES`,
`TF_DSV41_OWN_PREFILL`, `TF_DSV41_PROMPT_TAIL`, `TF_DSV41_BATCH_SHORT`,
`TF_DSV41_CONTEXT`, `TENSORFOLD_MEMORY_RESERVE_GIB`. `TF_DSV41_PREFILL_CUT_IN` and
`TF_DSV41_PREFILL_INTERLEAVE_MS` are new names in the overlay (`kv/sched.zig`); they are
not upstream 1.2.7 names.

The overlay is `engine/patches/0001-server-dsml-anthropic-and-prefill-cut-in.patch`
and `engine/patches/0002-sampling-bos-roce-rank.patch`. The map of all 53 fork
tunings, and what 0002 changes, is [`MIA-TUNING-MAP.md`](MIA-TUNING-MAP.md).

`git apply --check` accepts `0001` on a clean v1.2.7 tree at `93a2e93ece`, and `0002`
after it. `0001` ports the
newline DSML opener, a value that contains its block closer, the orphan-closer diagnostic,
empty `reasoning_content` falling through to a non-empty `reasoning` (an empty string with
no alternate is still stored, so the template goldens keep `<think></think>`), Anthropic
`clear_thinking_*` edits, a system turn anywhere in `messages`, and the thinking budget
default.

Host tests on this x86_64 VM, Zig 0.17.0, against the patched tree (not a GB10 binary):

| step | result |
| --- | --- |
| `zig build test-tool-parse-host` | 56/56 pass, including the newline hide and a closer inside a parameter value |
| `zig build test-dsv41-serve-host` | 15 pass, 5 skip; template goldens match, including the empty-`reasoning_content` fallthrough |
| `zig build test-dsv41-kv` | 31/31 pass, including short-prompt cut-in and `TF_DSV41_PREFILL_INTERLEAVE_MS` |
| `zig build test-dsv41-device-host` (this change) | 221/221 pass, including the sampler default of on |
| server module, filter `output diagnostic` plus the thinking-tail filter | 37/37 pass |

The Anthropic budget and `clear_thinking_*` edits typecheck because that server module
compiles `chat_generation.zig`, which imports `anthropic_translate.zig`. This run did not
execute a dedicated test of those two branches. `make check` passes: profile rules, trial
guards, and `scripts/gate.sh --self-check`. No image was built here (no aarch64, no nvcc,
no GB10). Serving speed is not measured.

## Validation gate

`scripts/gate.sh` is what the owner runs on SparkOne. It aborts if `MemAvailable` is under
3.5 GiB on either node, or if `tensorfold:lanes` is not 4. A pass needs `exact.py` 31/31
against the live record, cold TTFT under the Nov 11 refs (8k 13.80 s, 131k 57.89 s), warm
below cold at 8k/32k/131k, a restart-then-restore of the 8k prompt faster than that cold
number, a recorded short request during a long prefill, and four agents whose decode
overlaps (aggregate above the fastest stream) at least at 95% of 102.7 tok/s.
`tf127-pf4k` and `tf127-prefetch` also need `--token-baseline` from a replay run.
Commands and rollback are in [`trial-runbook.md`](trial-runbook.md).
