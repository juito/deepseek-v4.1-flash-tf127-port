# DeepSeek-V4.1-Flash-1017 → TensorFold v1.2.7 (port workspace)

Triage and scaffolding for moving Mia's AI Lab's
[2x DGX Spark recipe](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks)
off BertholomusAI's `deepseek-v41-zig` fork and onto upstream
[TensorFold](https://github.com/ashhart/TensorFold) **v1.2.7**.

> **Not deployable.** Nothing in this repository builds, serves, or has been benchmarked.
> The patch series is 1-for-53 against v1.2.7 and the DeepSeek family was rewritten upstream.
> Read [`PORT-STATUS.md`](PORT-STATUS.md) before using anything here.

## What is here

| Path | What it is |
|---|---|
| `PORT-STATUS.md` | The finding: divergence, why the series does not rebase, full 53-patch triage, validation gate |
| `triage.csv` | Machine-readable triage: `patch,status,touched_files` |
| `scripts/triage.sh` | Reproduces the triage against any tag (`TF_TAG=v1.2.6 scripts/triage.sh`) |
| `recipe-tf-fbbc971/` | The recipe tree verbatim at `c7f2b85` (2026-11-09), including `zig/patches/` — kept as the reference for what has to be ported |
| `.github/workflows/port-check.yml` | CI: re-runs the triage on every push and reports drift |

## Baseline

| | |
|---|---|
| Recipe pin today | `bertholomus/TensorFold` @ `fbbc97132c` (`deepseek-v41-zig`, 2026-10-24) |
| Fork merge base with upstream | TensorFold **1.0.2** (`f8fe17d246`, 2026-10-07) |
| Target | upstream **v1.2.7** (`93a2e93ece`, 2026-11-11) |
| Upstream commits missing from the pin | **6,958** |
| Fork-only commits on that base | **140** |
| Recipe patches | **53** |
| Applying to v1.2.7 | **1** (`0029`) |

The fork's `zig/src/families/dsv41/` (62 files) and upstream's `zig/src/families/deepseek_v41/`
(243 files) share **zero filenames**, and **0 of 18** recipe `TF_DS_*` / `TF_FILL_*` / `TF_RDMA_*`
switches exist upstream. This is a reimplementation, not a rebase.

## Order of work

1. **Server-side patches first** (24 of them touch `zig/src/server/*`, which survives upstream with
   drift). These are client-visible correctness fixes and the cheapest to land.
2. **Family-side patches next** (28 touch fork-only files) — rewrite against `deepseek_v41`'s
   `block_*`/`batch_*` modules. Only after this can any speed claim be made.
3. **Measure, never assume.** Gate on `tools/exact.py` (31 token-hash cases), `tools/smoke.py`,
   `tools/prompt_reuse.py`, and `tools/bench.py --compare` on the pair of Sparks.

## Licensing and attribution

The recipe and TensorFold are Apache-2.0; see `recipe-tf-fbbc971/LICENSE` and `NOTICE`, and the
recipe's `CREDITS.md` for the authors of each patch. This repository adds only triage tooling and
documentation. No affiliation with Mia's AI Lab, BertholomusAI, or TensorFold.
