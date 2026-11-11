#!/usr/bin/env python3
"""Bench the trial server, not the live one.

Defaults to http://127.0.0.1:8890. Ports 8888 and 18004 are refused unless
--allow-live is passed. Before any measured request, /metrics must report
requests_running == 0. --compare only reads saved JSON and skips both checks.

The measurement itself is the recipe's tools/bench.py.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from endpoint_guard import assert_idle, assert_trial_url, default_base  # noqa: E402

RECIPE_BENCH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "recipe-tf-fbbc971",
    "tools",
    "bench.py",
)


def _url_from(argv: list[str]) -> tuple[str | None, list[str]]:
    out: list[str] = []
    url = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--url" and i + 1 < len(argv):
            url = argv[i + 1]
            i += 2
            continue
        if arg.startswith("--url="):
            url = arg.split("=", 1)[1]
            i += 1
            continue
        out.append(arg)
        i += 1
    return url, out


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if any(arg in ("-h", "--help") for arg in argv):
        os.execv(sys.executable, [sys.executable, "-I", RECIPE_BENCH, "--help"])
    if "--compare" in argv:
        os.execv(sys.executable, [sys.executable, "-I", RECIPE_BENCH, *argv])
    allow_live = "--allow-live" in argv
    argv = [arg for arg in argv if arg != "--allow-live"]
    url, rest = _url_from(argv)
    if url is None:
        url = default_base()
    url = assert_trial_url(url, allow_live)
    assert_idle(url)
    os.execv(sys.executable, [sys.executable, "-I", RECIPE_BENCH, "--url", url, *rest])
    return 0


if __name__ == "__main__":
    main()
