# Mia's tuning map onto TensorFold v1.2.7

Recipe pin: `MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks` @ `c7f2b85`.
Engine pin: `ashhart/TensorFold` @ `93a2e93ece` (tag v1.2.7).
`git apply` of the 53 patches still lands **1 of 53** (`0029`). That count is `triage.csv`.
This page is the disposition: what each tuning did on the fork, and what to use on 1.2.7.

Nothing here has been timed on GB10. The Nov 12 numbers in the task (8k TTFT 6.43 s vs 13.80 s, prefill ~1,200 tok/s vs ~2,300, decode 27.7/75 vs 57/95, 4-stream 70 vs 188–271) are the operator's measurement of stock 1.2.7 with Mia's settings, not of this tree.

## What this tree changes

The trial image stays `tensorfold-dsv41:tf127-trial-<hash>`. The live tag
`tensorfold-dsv41:exl3-tp2-8a98ae503d85` is not a target. Weights stay EAQ v1 @ `45ee5d0f`.

| Bug | Cause in v1.2.7 | What this tree does |
|---|---|---|
| (a) omitted temperature → HTTP 500 `Sampling` | `#1725` defaults DeepSeek requests to temperature 1.0. `TF_DSV41_SAMPLING` defaulted off, and `keyedOf` returns `error.Sampling` when the sampler is null | Sampler default is on (`sampling_gpu.zig`). `TF_DSV41_SAMPLING=0` still refuses. Profiles set `=1` |
| (b) greedy prose loops BOS | Host argmax treated a NaN in column 0 as the winner (`x > NaN` is never true). On rank 0 that column is `bos` (0). The same row then all-gathers, and a NaN value never loses | `argmaxExcept` skips NaN and, on the host greedy path, skips this rank's BOS column. `TF_DSV41_GREEDY_GPU=1` does **not** take this path. Leave it unset until that device pick is checked |
| (c) RoCE `NoKernel`, NCCL fallback | `Session.open` loads `TF_TP_KERNEL_IMAGE`. Empty bytes are `error.NoKernel` (`roce.zig`). The image was built with `-Dnvcc` / `-Ddsv41-nvcc` and not the mailbox fatbin. `--rank` / `--master` are not what `tp.Config.fromEnv` reads | The image compiles `mailbox.cu` to `/opt/tensorfold/tp_mailbox.fatbin`. `engine-trial.sh` sets `TF_COMM_BACKEND=roce`, `TF_TP_KERNEL_IMAGE`, `TF_TP_WORLD`, `TF_TP_RANK`, `TF_TP_MASTER`. `serve_engine` copies `--tp` / `--rank` / `--master` onto those names when they are unset. Large collectives stay on NCCL (upstream: RoCE is the small exchanges, slot default 256 KiB, a write above 1 MiB refuses boot) |
| (d) `dsv41 kernel refused … 528 + 107520..129024 B shared > 101376` | That range is v1 `gm_kernel` tile GM_GU3 (`1,16,4,3,4`) at **two inputs** (`xm=2`), K2 3,4,5,6,7,8,10. Static 528 B is `rows_sh[128]` plus the item word. `gmFits` is already false, and `gmTuned` does not select that tile for two inputs (it selects cfg 2). The log is `fitShared` at resolve, once per refused variant | Not a new CUDA tile. Changing NSA would change mangled symbols and the measured kernel-contract register counts, which this machine cannot remeasure. `profiles/tf127-speed.env` turns on `TF_DSV41_GM_V2=1`. Upstream's `gm2pf.zig` says v2 is the same bits as v1, and its rings are cut so the launched tiles fit in 101376 B. A host test locks that the tuner does not select the refused tile |
| (e) Engram `FileNotFound` | Serving at TP=2 opens `engram-l<layer>-r<rank>of2.bin`. `tf-dsv41-engram-pack` writes `engram-l<layer>-r0of1.bin` | `scripts/build-prepare.sh` runs the packer and hardlinks each full table to `r0of2` and `r1of2` under `~/.cache/dsv41-tensorfold/engram-1bae0e10/`. The header stores row range, not rank. Each rank's hash indexes the whole table, so both names are the same bytes |
| (f) boot floor misses by 0.03 GiB | `zig_dip_gib` default is 3.0. The comment next to it says the measured dip was 2.48 (rank 1) and 1.1 (rank 0) | Profiles and `engine-trial.sh` set `TF_DSV41_SERVE_DIP_GIB=2.5`. The engine constant stays 3.0. Memguard still kills below about 2.5 GiB; this does not lower `TENSORFOLD_MEMORY_RESERVE_GIB` |

`scripts/build-prepare.sh` is the one command: fetch, build the trial image, pack Engram, write the token map. It does not start the server and does not bind an address. The next command it prints is `scripts/engine-trial.sh --stop-live --profile profiles/tf127-speed.env restart`.

## The 53 patches

"Upstream" means the 1.2.7 behavior is the one to use, not that the fork patch applied.
"0001" is `engine/patches/0001-server-dsml-anthropic-and-prefill-cut-in.patch`, already on main.
"This PR" is `engine/patches/0002-sampling-bos-roce-rank.patch` plus the trial scripts. RoCE, the dip, Engram packing and `GM_V2` are launch/image work, not that patch.

| Patch | What Mia's series did | On 1.2.7 |
|---|---|---|
| `0001` indexer split | Split the prefill indexer across the two ranks from token 131072 | Not applicable. No `TF_DS_IDX_SPLIT`. Not reimplemented. Prefill speed is the open measurement |
| `0004` call gate | `tool_choice` required / named must be a DSML call | Upstream (`#1684`) |
| `0005` prefill interleave | Up to N ms of decode between prompt chunks | Partial. Pieces exist. 0001 adds `TF_DSV41_PREFILL_CUT_IN` and `TF_DSV41_PREFILL_INTERLEAVE_MS`. Fork patch does not apply. Profiles `tf127-cut-in` and `tf127-interleave` |
| `0008` pool vs window | Pool may exceed the context window | Not applicable. Use `TF_DSV41_POOL_TOKENS` and `TF_DSV41_CONTEXT`. Trial stays at pool 1048576 and context 524288 |
| `0010` RDMA idle nap | Proxy sleeps after `TF_RDMA_IDLE_S` | Not ported. No `TF_RDMA_IDLE_S`. 1.2.7's proxy is `TF_TP_ROCE_CPU` (unset here) |
| `0011` parked pages in the CUDA budget | Count free pages on the per-CPU lists | Not ported. `cuda_memory.zig` has a parked field; that is not this patch |
| `0012` base fixes | Drop a stale Engram read-ahead; nap `prctl` on Linux only | Not ported |
| `0013`–`0014`, `0016`, `0019`, `0021` spill | Disk blocks, spill tier, pictures | Not applicable. The 1.2.7 tier is `TF_DSV41_PREFILL=replay` plus `TF_DSV41_SESSION_DISK`. Not the fork spill store |
| `0015`, `0018`, `0022`, `0042` KV shard | One copy of compressed KV, then lanes, then the RDMA ring | Not ported. Nearest name is `TF_DSV41_KV_SPLIT`. Left off: bit risk, no GB10 measurement |
| `0017` kit row split | `ROUND_ROWS=32` on the Triton kit | Not applicable. v1.2.7 has no `tf-dsv41-rank-cache` and no kit. Expert GEMMs are `x3gm` |
| `0020` pair broken | Exit 75 when the other rank dies | Not ported. Upstream fail-fast is `TF_TP_FAILFAST` (default on) |
| `0023` prepare memory | Wait under a memory floor while rendering | Not ported. The 12.2 GiB reserve stays the engine default |
| `0024`–`0026` mixed pack / BF16 widen / plain rows | EAQ v1.1's 27 BF16 linears, fixed GEMM rows | Not applicable. Would change bits. Stay on EAQ v1 `45ee5d0f` |
| `0027` tool-call prose | Content keeps the text before the calls, without the two newlines | Ported in 0001 (newline opener). Empty content stays null |
| `0028` plain request text | User text cannot become a control token | Upstream-equivalent (`#2400`), not the U+FDD0 mark |
| `0029` Anthropic budget | `thinking: enabled` with no `budget_tokens` uses the server default | Applies, and 0001 includes it. `fetch-engine.sh` applies only `engine/patches/` |
| `0030`–`0031` Anthropic edits | Any `clear_thinking_*` keep; system turn anywhere | Ported in 0001 |
| `0032` stream ping | Ping during a long prefill | Upstream (`keepalive_test.zig`) |
| `0033` graph cap | Keep at most N CUDA graphs | Not the same knob. Nearest name is `TF_DSV41_GRAPHS_MAX`. Not set. `TF_DSV41_ROUND_GRAPH=1` on the speed profile is the decode-round graph, which is a different switch |
| `0034` rebase follow-ups | `fillOne` marks `passing`; refuse a 0-token picture | Not ported |
| `0035` Engram lead failures | A failed Engram read ends the pair | Not ported. No `TF_DS_ENGRAM_LEAD` |
| `0036` cached prompt metrics | `prompt_tokens_cached_total` | Upstream (`openai.zig`) |
| `0037` early rendezvous | Rank 0 listens before weights load | Not ported. No `TF_DS_CONNECT_S` |
| `0038` aligned index views | Index blocks multiple of 16 | Not ported |
| `0040` restore room | A full pool waits instead of re-prefilling | Not applicable. Replay is the resume path |
| `0041` service between pieces | Spill work between fill pieces | Not ported |
| `0043` picture resume skip | Don't re-run vision for pictures already in the kept state | Not ported |
| `0045` cut-in tail | Cut in on tokens still to compute | Partial, via `TF_DSV41_PREFILL_CUT_IN` in 0001 |
| `0046` GET/DELETE body | Discard a body on GET/DELETE | Upstream (`routes.zig`) |
| `0047` replayed reasoning | Empty `reasoning_content` falls through to `reasoning` | Ported in 0001 |
| `0048` streamed tool calls | DSML calls stream as they decode | Upstream (`#1975`, `#2201`) |
| `0049` first draft depth | First drafts use the same depth rule as later rounds | Not ported |
| `0050` draft calibration | Per-stream draft survival | Not ported. `TF_DS_T25_DRAFT_CAL` has no 1.2.7 name |
| `0051` prompt rows | Window rows 64, GEMM rows 128 | Not ported. 1.2.7 prefill segments default to 2048 rows (`block.Options.prefill_rows`) with `TF_DSV41_OWN_PREFILL` default on |
| `0056` picture scratch | One picture's scratch at a time | Not ported |
| `0057` drop reasoning history | Don't replay assistant reasoning into the template | Not ported. No `DROP_REASONING_HISTORY` |
| `0058` responses include | Accept `reasoning.encrypted_content` and ignore it | Upstream-equivalent |
| `0059` lane thread CUDA context | Bind the context on the lane thread | Not verified on the new lane host, so not claimed |
| `0064` short DSML payload | A short payload is not sliced as a call | Upstream-equivalent |
| `0065` value holds closer | A parameter value may contain the block closer | Ported in 0001 |
| `0066` load prefetch | `pread` the rank cache ahead of the loader | Not this knob. `TF_DSV41_PREFETCH_AHEAD` is Engram segment read-ahead. Left on `tf127-prefetch` only |
| `0067` orphan DSML closer | Diagnostic when the reply is only closers | Ported in 0001 |
| `0068` RDMA proxy CPU | Pin the proxy thread | Not ported. Nearest name is `TF_TP_ROCE_CPU`, left unset |

Mia's serving defaults that are not a patch, and the 1.2.7 equivalent:

| Fork setting | Fork value | 1.2.7 |
|---|---|---|
| `CONTEXT` / pool | live window 524288, pool 1048576 in the measured run (recipe default context is 1048576) | `TF_DSV41_CONTEXT=524288`, `TF_DSV41_POOL_TOKENS=1048576`. Do not raise either |
| `PARALLEL` | 4 | `--parallel 4` is only the HTTP cap. `TF_DSV41_SLOTS=4` is the engine. Both are set |
| `DRAFTS` | 1 | `TF_DSV41_SLOT_DRAFTS=1` and `TF_DSV41_SESSION_SLOTS=1` |
| `TEMPERATURE` / `TOP_P` / `TOP_K` | 1.0 / 0.95 / 20, a request overrides | Family default is temperature 1.0, top_p 1.0, no top_k (`family_sampling.zig`, the model card). That is **not** Mia's 0.95 / 20. This PR does not change the card defaults. Pass `top_p` and `top_k` on the request when the comparison must match Mia's sampler |
| `RDMA` | 1, RoCE, nap 2 s / 500 µs | `TF_COMM_BACKEND=roce` plus the fatbin. Nap and CPU pin are not ported |
| `GRAPHS` / `GRAPH_CAP` | on, cap 128 | Speed profile sets `TF_DSV41_ROUND_GRAPH=1`. That is not `GRAPH_CAP`. `TF_DSV41_GRAPHS_MAX` is unset |
| `ENGRAM_AIO` | 1, tables on local disk | Pack script plus `TF_DSV41_ENGRAM_DIR`. Speed profile sets `TF_DSV41_ENGRAM_AIO=1`. Default reader is io_uring, then AIO |
| `PREFILL_INTERLEAVE_MS` | 250 | Off on the speed profile (full prefill, no pieces). Use `tf127-interleave` to try 250 ms |
| `ROUND_ROWS` | empty or 16 | No kit. Do not set `ROUND_ROWS` and expect a kernel |

## What to measure on the Sparks

Build on one Spark (aarch64), then start both ranks. `scripts/build-prepare.sh` refuses the live image tag.

```bash
MODEL=/path/to/eaq-v1-45ee5d0f \
ENGRAM_RELEASE=/path/to/release-snapshot-1bae0e10 \
TF_DSV41_ASSETS=/nvme/dsv41-assets \
scripts/build-prepare.sh
```

`rope.bin` and `aot/` still come from the external Triton reference tools. The script says so when they are missing. Then, on SparkOne:

```bash
MODEL=... TF_DSV41_ASSETS=... TF_DSV41_ENGRAM_DIR=$HOME/.cache/dsv41-tensorfold/engram-1bae0e10 \
  scripts/engine-trial.sh --stop-live --profile profiles/tf127-speed.env restart
```

On SparkTwo, the same profile with `RANK_OVERRIDE=1`. Both ranks must use the same `TF_DSV41_SESSION_RESIDENT_GIB`.

Record, in order, and keep the raw logs:

1. Boot line on both ranks. It must not say `RoCE unavailable (NoKernel)`. It should name `roce`. If it says `VerbsFailed`, the auto HCA pick chose the wrong ports (a third Spark on the other cable). Set `TF_TP_ROCE_HCA` to the two devices on the pair's own cable, and `NCCL_IB_HCA` to those names without `:gid`. This tree does not guess device names.
2. Count of `dsv41 kernel refused` lines. GM_GU3 at two inputs can still be refused at resolve. That is expected. A refusal of a tile `gmTuned` actually launches is not.
3. A request with **no** `temperature` field. It must not be HTTP 500 `Sampling`.
4. Greedy prose (`temperature` 0, thinking off): the reply must not be a run of `<｜begin▁of▁sentence｜>`. Then the same prompt with `TF_DSV41_GREEDY_GPU=1` and without it. Only the host path is patched.
5. `exact.py` 31/31 against the live record, greedy, same as the runbook. `GM_V2` and the round graph are supposed to keep bits. If they do not, the speed profile is wrong and the baseline profile is the one to keep.
6. The Nov 12 suite, cold, temp 0 for the speed table and the omitted-temperature case separately: 8k TTFT, prefill tok/s at 8k and 131k, 131k cold TTFT, one-stream prose and code decode, 4-stream aggregate. Compare with Mia c7f2b85 (prefill ~2,300 tok/s, decode 57 / 95, 4-stream 188–271) and with stock 1.2.7 from Nov 12.
7. `MemAvailable` while serving. The guard kills below about 2.5 GiB. Dip 2.5 is what made boot pass; it is not a measurement that the trough stays there under 4 streams at 131k.
8. Sampler on adds device scratch. If boot now fails for memory, the log's dip and growth lines are the evidence. Do not lower the 12.2 GiB reserve to compensate.

## Uncertainties

- How much of the decode and 4-stream gap is RoCE. A third-party pair saw about +11% decode from NCCL to RoCE. The gap here is larger (27.7 vs 57 prose, 70 vs 188–271 aggregate), so RoCE alone may not close it.
- Whether `TF_DSV41_GM_V2=1` moves prefill from ~1,200 toward ~2,300. It is the fitting kernel path. It is not Mia's Triton kit, and the indexer split (`0001`) and prompt-row widths (`0051`) are not ported.
- Whether BOS loops were a NaN in column 0, a real BOS logit, or the unpatched GPU argmax. The host path now skips both NaN and the BOS column. If greedy prose still loops BOS, the logits themselves are wrong and this mask is only hiding token 0.
- Mia's sampler is top_p 0.95 and top_k 20. v1.2.7's family default is top_p 1.0 and no top_k. Greedy comparisons are unaffected. Sampled comparisons are not the same distribution until the request sets those two fields.
- `TF_DSV41_ROUND_GRAPH=1` turns on both `split` and `gate`. That is what the parser does for `1`. It has not been timed here.
- HCA auto-pick is upstream's `/24` match. A two-cable pair should find the peer. A triangle will not. Device names are not hardcoded.
- The Engram hardlink assumes a rank reads any row of the full table. That matches `engram_io.zig` (`x - header.lo` with `lo = 0`). A future packer that stored only a row slice would make the hardlink wrong.
