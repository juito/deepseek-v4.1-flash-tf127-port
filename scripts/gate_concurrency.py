"""Pass rules for four agents decoding at once.

A row is one `tools/bench.py` multi rep. Four agents count only when every
stream finished and the aggregate rate is above the fastest single stream,
which is what overlapping decode looks like in that tool. A serial queue
makes the aggregate about as fast as one stream.
"""

from __future__ import annotations

REF_AGG_TOK_S = 102.7


def reasons(row: dict | None, ref: float = REF_AGG_TOK_S) -> list[str]:
    if not row:
        return ["4-agent decode was not recorded"]
    out: list[str] = []
    errs = row.get("errors") or []
    rates = [
        x
        for x in (row.get("per_stream_decode_tok_s") or [])
        if isinstance(x, (int, float))
    ]
    if errs or len(rates) != 4:
        out.append(
            f"4 agents did not all finish (errors {len(errs)}, rates {len(rates)})"
        )
    agg = row.get("aggregate_tok_s")
    if not isinstance(agg, (int, float)) or agg < ref * 0.95:
        out.append(
            f"4-stream decode {agg} tok/s is more than 5% under {ref}"
        )
    if len(rates) == 4 and isinstance(agg, (int, float)) and not (agg > max(rates)):
        out.append(
            f"4 agents did not overlap: aggregate {agg} tok/s is not above "
            f"the fastest stream {max(rates)} tok/s"
        )
    return out


def stats(row: dict | None) -> dict:
    rates = []
    if row:
        rates = [
            x
            for x in (row.get("per_stream_decode_tok_s") or [])
            if isinstance(x, (int, float))
        ]
    agg = row.get("aggregate_tok_s") if row else None
    return {
        "agents": 4,
        "finished": len(rates),
        "aggregate_tok_s": agg if isinstance(agg, (int, float)) else None,
        "per_stream_tok_s": {
            "min": min(rates) if rates else None,
            "mean": (sum(rates) / len(rates)) if rates else None,
            "max": max(rates) if rates else None,
        },
        "overlapped": bool(
            rates and isinstance(agg, (int, float)) and agg > max(rates)
        ),
    }
