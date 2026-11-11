# Accuracy and hallucination: what a serving config can and cannot do

**There is no setting that fixes hallucination.** A model inventing a plausible fact is a property of
the weights, not of the launcher. What you can do is (a) stop the deployment from *adding* failures
of its own, (b) pick sampling that suits the task, and (c) put grounding and verification in the
client. This page is ordered by how much each layer actually buys.

## Layer 1: the deployment's own bugs (real, fixable)

These look like hallucination but are the harness losing information between turns. All six are in
the recipe's patch series and were **Unreleased** in the changelog as of `c7f2b85` — if your image
predates them, you are seeing avoidable degradation.

| Patch | What it fixes | Measured effect |
|---|---|---|
| `0047-replayed-reasoning` | LiteLLM's `hosted_vllm` provider strips `reasoning_content` and keeps `reasoning`; the engine read only the former, so every history turn rendered as an empty think block | A 22-turn tool session: the next reply thought at **22 of 22** points with the reasoning in history, **6 of 22** without (0 of 9 above 100K tokens) |
| `0027-tool-call-prose` | A non-streamed reply with tool calls returned `content: null`, so the client never saw the text — in one case a **3,671-character plan** — and sent the turn back without it | Replies keep their bits; only the response's `content` changes |
| `0028-plain-request-text` | A control token's spelling in request text came back as the token: a tool result holding `<｜User｜>` gave the model a role marker, a DSML call or `</think>` | 30–34 control ids before, 28 after (the template's own); clean prompts identical |
| `0057-drop-reasoning-history` | A client replaying every turn's reasoning in a tool loop shows the model its own earlier thinking at every step; long runs drifted into flat, then repeating reasoning | 3 of 6 replies looped to `max_tokens` with the field, **0 of 6** without |
| `0064` / `0065` DSML parsing | A short or closer-holding payload became a corrupt call instead of text | Malformed calls stay as text; well-formed ones read as before |

Check your running image against the recipe's `CHANGELOG.md` before blaming the model.

## Layer 2: sampling and thinking

The recipe's default is the family's measured sampling: **temperature 1.0, top_p 0.95, top_k 20**.
That is a *creative* setting, not a factual one.

| Setting | Default | For factual work |
|---|---|---|
| `TEMPERATURE` | 1.0 | **0** (greedy) — removes sampling variance entirely |
| `TOP_P` | 0.95 | 1 |
| `TOP_K` | 20 | 20 (the sampler needs one; the engine refuses above 56 with `TooManyCandidates`) |
| `THINKING` | 1 | keep 1 |
| `REASONING_EFFORT` | empty (template default) | `high` or `xhigh` on hard tasks |
| `THINKING_BUDGET` | empty (no cap) | **set it** — with no cap a turn can spend its whole `MAX_TOKENS` thinking and return no text at all (`finish_reason: length`), which reads as a failure |

`profiles/factual.env` sets exactly this. Note that greedy decoding is not "more correct" in
general — it removes variance, so it will confidently repeat the same wrong answer every time.

For long agent loops, `DROP_REASONING_HISTORY=1` is the documented mitigation for reasoning drift.
It costs a re-prefill of the previous reply each turn, so measure the TTFT hit.

## Layer 3: quantization (small, and only in one direction)

2.9 bpw EXL3 discards precision; a 3.5 bpw pack would be better but **none exists for this model**.
The only sanctioned precision improvement is EAQ v1.1, which restores **27 indexer/compressor
linears** to BF16. That is a narrow, experimental change that invalidates the `exact.py` baseline —
see [`quantization.md`](quantization.md). It is not a hallucination fix and should not be sold as one.

Speculative decoding (`DRAFTS=1`) is **not** a risk: drafted replies are verified and equal plain
ones, and `tools/exact.py` is the proof.

## Layer 4: the client (the biggest lever, and the only real one)

Nothing above teaches the model a fact it does not have. These do:

1. **Ground it.** Put the source in the prompt (retrieved passages, the actual file, the row from the
   database) and require a citation per claim. Refuse to answer when the retrieval is empty rather
   than letting the model fill the gap.
2. **Make it call a tool, then check.** For anything with a ground truth — a price, a date, a record —
   have it call the tool, then verify the result before the turn ends. A verified call beats any
   sampling setting.
3. **Constrain the shape.** JSON schema / grammar-constrained output turns "plausible prose" into
   "valid or refused".
4. **Sample and compare.** For high-stakes answers, ask k times and keep only what agrees; disagreement
   is the signal to escalate.
5. **Keep the context tight.** The needle test passes at 479,012 tokens, but quality degrades well
   before the window does. A short, relevant prompt beats a long one.
6. **Ask for uncertainty.** "If the sources do not say, say so" is cheap and measurably reduces
   invented detail.

## What cannot be fixed by configuration

- A confident wrong fact from parametric memory.
- A wrong premise in the prompt (the model will usually reason from it).
- A tool that returns wrong data (the model will faithfully relay it).
- Reasoning that is internally consistent and externally wrong — thinking on makes this *more*
  convincing, not less.

If you need a hard guarantee, the answer is not a launcher setting: it is retrieval plus verification
plus a refusal path.
