#!/usr/bin/env python3
"""TTFT-only measurement for a TensorFold server.

Streams `max_tokens=1` requests at each prompt size and reports time to first
token (p50/p90), plus the prefill rate implied by the counted prompt tokens.
Cold prompts are built fresh per repetition so the prefix cache cannot answer;
warm prompts reuse one salt so the second and later reps resume a kept state.

Stdlib only. Endpoint: --url, else API_URL, else PORT, else scripts/local.sh,
else 8888. Model: --model, else MODEL, else the recipe's served name.

Examples:
  python3 -I tools/ttft.py --sizes 512,2048,8192,32768,131072 --reps 5 --out runs/a.json
  python3 -I tools/ttft.py --mode warm --sizes 2048,32768 --reps 5
  python3 -I tools/ttft.py --compare runs/a.json runs/b.json
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

DEFAULT_MODEL = "DeepSeek-V4.1-Flash-1017"

# A plain vocabulary: each word is about one token, and the counted prompt
# tokens are reported alongside the requested size so the ladder is honest.
WORDS = (
    "the of and to in is was that for on with as by at from his her they we "
    "you it this be are or an which have not but had were all when there can "
    "more one about out up what some could them other into than then now only "
    "its over also after first two our work new use may way even because any "
    "these give day most us between both under last many where before through "
    "back years much your know while down should each just those people how "
    "little state good very make world still own see men said get here find "
    "long part made being where great where again off old life few keep might "
    "point never next end home water room mother area money story fact month "
    "right study book eye job word business issue side kind head house service "
    "friend father power hour game line end member law car city community name "
    "team minute idea kid body information school face others level office door "
    "health person art war history party result change morning reason research "
    "girl guy moment air teacher force education".split()
)


def local_sh_port() -> str | None:
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "recipe-tf-fbbc971", "scripts", "local.sh")
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"\s*(?:export\s+)?PORT=(\d+)\s*(?:#.*)?$", line)
                if m:
                    return m.group(1)
    except OSError:
        return None
    return None


def default_base() -> str:
    url = os.environ.get("API_URL")
    if url:
        return url.rstrip("/")
    port = os.environ.get("PORT") or local_sh_port() or "8888"
    return f"http://127.0.0.1:{port}"


def parse_sizes(text: str) -> list[int]:
    out = []
    for part in text.split(","):
        part = part.strip().lower()
        if not part:
            continue
        mult = 1
        if part.endswith("k"):
            mult, part = 1000, part[:-1]
        elif part.endswith("m"):
            mult, part = 1000000, part[:-1]
        out.append(int(float(part) * mult))
    return out


def make_prompt(tokens: int, salt: str) -> str:
    rng = random.Random(f"{salt}:{tokens}")
    return " ".join(rng.choice(WORDS) for _ in range(tokens))


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    k = (len(ordered) - 1) * (pct / 100.0)
    lo, hi = int(k), min(int(k) + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def one_request(base: str, model: str, prompt: str, timeout: float) -> dict:
    """Stream one completion and time the first token."""
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 1,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
        "thinking": False,
    }).encode()

    req = urllib.request.Request(
        f"{base}/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
        method="POST",
    )

    started = time.perf_counter()
    first = None
    prompt_tokens = None
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    event = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                usage = event.get("usage")
                if isinstance(usage, dict) and usage.get("prompt_tokens"):
                    prompt_tokens = usage["prompt_tokens"]
                choices = event.get("choices") or []
                if first is None and choices:
                    delta = choices[0].get("delta") or {}
                    if any(delta.get(k) for k in ("content", "reasoning_content", "reasoning", "tool_calls")):
                        first = time.perf_counter() - started
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        raise SystemExit(f"HTTP {exc.code} from {base}: {detail}") from None
    except urllib.error.URLError as exc:
        raise SystemExit(f"cannot reach {base}: {exc.reason}") from None

    if first is None:
        raise SystemExit("stream ended without a first token; check max_tokens and thinking")
    return {"ttft_s": first, "prompt_tokens": prompt_tokens}


def run(args: argparse.Namespace) -> dict:
    base = args.url.rstrip("/")
    salt = args.salt if args.salt is not None else f"ttft-{int(time.time() * 1000)}"
    modes = ["cold", "warm"] if args.mode == "both" else [args.mode]
    result = {
        "label": args.label,
        "url": base,
        "model": args.model,
        "salt": salt,
        "reps": args.reps,
        "sizes": [],
    }

    for mode in modes:
        for size in parse_sizes(args.sizes):
            samples, counted = [], []
            for rep in range(args.reps):
                # cold: a distinct prompt every repetition, so nothing resumes
                # warm: one prompt, so rep 2+ reads the kept prefix state
                prompt_salt = f"{salt}:{size}:{mode}:{rep if mode == 'cold' else 0}"
                out = one_request(base, args.model, make_prompt(size, prompt_salt), args.timeout)
                samples.append(out["ttft_s"])
                if out["prompt_tokens"]:
                    counted.append(out["prompt_tokens"])

            p50 = percentile(samples, 50)
            row = {
                "mode": mode,
                "requested_tokens": size,
                "prompt_tokens": int(sum(counted) / len(counted)) if counted else None,
                "reps": [round(s, 4) for s in samples],
                "ttft_ms_p50": round(p50 * 1000, 1),
                "ttft_ms_p90": round(percentile(samples, 90) * 1000, 1),
                "ttft_ms_min": round(min(samples) * 1000, 1),
            }
            if row["prompt_tokens"] and p50 > 0:
                # prefill rate implied by the counted prompt, first token only
                row["prefill_tps_p50"] = round(row["prompt_tokens"] / p50, 1)
            result["sizes"].append(row)
            print(
                f"{mode:4s} {size:>7d} tok -> TTFT p50 {row['ttft_ms_p50']:>8.1f} ms  "
                f"p90 {row['ttft_ms_p90']:>8.1f} ms  "
                f"(counted {row['prompt_tokens']}, prefill {row.get('prefill_tps_p50', 'n/a')} tok/s)",
                flush=True,
            )
    return result


def compare(a_path: str, b_path: str) -> int:
    with open(a_path, encoding="utf-8") as fh:
        a = json.load(fh)
    with open(b_path, encoding="utf-8") as fh:
        b = json.load(fh)

    def index(doc):
        return {(r["mode"], r["requested_tokens"]): r for r in doc["sizes"]}

    ia, ib = index(a), index(b)
    print(f"{'mode':5s} {'tokens':>7s} {'A p50 ms':>9s} {'B p50 ms':>9s} {'delta':>8s} {'change':>8s}")
    worse = 0
    for key in sorted(ia, key=lambda k: (k[0], k[1])):
        if key not in ib:
            continue
        ra, rb = ia[key], ib[key]
        delta = rb["ttft_ms_p50"] - ra["ttft_ms_p50"]
        pct = (delta / ra["ttft_ms_p50"] * 100) if ra["ttft_ms_p50"] else 0.0
        if delta > 0:
            worse += 1
        print(
            f"{key[0]:5s} {key[1]:>7d} {ra['ttft_ms_p50']:>9.1f} {rb['ttft_ms_p50']:>9.1f} "
            f"{delta:>+8.1f} {pct:>+7.1f}%"
        )
    print(f"\n{worse} cell(s) slower in B; negative delta means B got there sooner")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="TTFT-only measurement for a TensorFold server")
    ap.add_argument("--url", default=default_base(), help="base URL, e.g. http://head:8888")
    ap.add_argument("--model", default=os.environ.get("MODEL", DEFAULT_MODEL))
    ap.add_argument("--sizes", default="512,2048,8192,32768", help="prompt tokens, comma separated (k/m suffix ok)")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--mode", choices=["cold", "warm", "both"], default="cold")
    ap.add_argument("--salt", default=None, help="fix the prompt set; default random per run")
    ap.add_argument("--timeout", type=float, default=600)
    ap.add_argument("--label", default="")
    ap.add_argument("--out", help="write the JSON here")
    ap.add_argument("--compare", nargs=2, metavar=("A.json", "B.json"), help="diff two saved runs")
    args = ap.parse_args()

    if args.compare:
        return compare(*args.compare)

    result = run(args)
    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fh:
            json.dump(result, fh, indent=2)
            fh.write("\n")
        print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
