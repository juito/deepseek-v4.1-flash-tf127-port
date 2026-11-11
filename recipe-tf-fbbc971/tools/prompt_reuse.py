#!/usr/bin/env python3
"""An agent's conversation keeps its prompt state while other conversations with the same system prompt run (a coding
agent and its sub-agents, or several chats on one system prompt): each of its next turns must resume from its kept
state, not re-read its history.

Usage: tools/prompt_reuse.py [size] [--require-counter]   (API_URL / PORT as in client.py). The conversation's history
is ~0.82 x size tokens (default 40000). Exit code 1 when a turn resumes less than 90% of its prompt. Needs a server
started with `PARALLEL` above 1 (the recipe's default is 4).

Each round: one request of another conversation with the same system prompt, then the agent's next turn.

From the GLM-5.3-Flash recipe (Mia's AI Lab, Apache-2.0), tools/prompt_reuse.py. Changed here: the served model's
name, thinking off through chat_template_kwargs (not reasoning_effort), --help, and the cached-token count read from
usage.prompt_tokens_details.cached_tokens or, failing that, a numeric field with "cached" in its name in the reply's
`tensorfold` block. When the server reports neither, the check cannot judge reuse: it prints the turn times and
exits 2 (--require-counter) or 0 with a warning. Which of the two fields the DeepSeek server fills is not yet known.
"""
import json
import os
import sys
import time
import urllib.request

sys.dont_write_bytecode = True           # no tools/__pycache__ from importing client
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))   # python3 -I does not add the script's folder
from client import URL, open_url, prose  # noqa: E402

MODEL = os.environ.get("MODEL", "DeepSeek-V4.1-Flash-1017")
SYSTEM = {"role": "system", "content": "You are a careful coding agent. Read the material, then answer briefly. "
          + prose(2000, 1)}


def chat(messages: list) -> tuple[dict, int, int | None, float]:
    body = {"model": MODEL, "messages": messages, "max_tokens": 64, "temperature": 0,
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(URL, json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.time()
    reply = json.load(open_url(req, 1800))
    usage = reply["usage"]
    cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
    if cached is None:
        cached = next((v for k, v in (reply.get("tensorfold") or {}).items()
                       if "cached" in k.lower() and isinstance(v, int) and not isinstance(v, bool)), None)
    return reply["choices"][0]["message"], usage["prompt_tokens"], cached, time.time() - t0


def main() -> None:
    if "-h" in sys.argv or "--help" in sys.argv:
        print(__doc__)
        return
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    require = "--require-counter" in sys.argv
    size = int(args[0]) if args else 40000
    agent = [SYSTEM, {"role": "user", "content": "Summarize this log in one line.\n" + prose(size, 2)}]
    msg, prompt, cached, secs = chat(agent)
    print(f"agent turn 0: {prompt} prompt tokens, {cached} cached, {secs:.1f} s (cold)")
    worst, seen = 1.0, cached is not None
    for turn in (1, 2, 3):
        chat([SYSTEM, {"role": "user", "content": f"Sub-task {turn}: name three uses of a hash map."}])
        agent += [{"role": "assistant", "content": msg.get("content") or ""},
                  {"role": "user", "content": f"Note {turn}: " + prose(200, 10 + turn)}]
        msg, prompt, cached, secs = chat(agent)
        if cached is None:
            print(f"agent turn {turn} (after another conversation): {prompt} prompt tokens, no cached count, {secs:.1f} s")
            continue
        seen = True
        worst = min(worst, cached / prompt)
        print(f"agent turn {turn} (after another conversation): {prompt} prompt tokens, {cached} cached "
              f"({cached / prompt:.0%}), {secs:.1f} s")
    if not seen:
        print("prompt_reuse: NO COUNTER: the server reported no cached tokens; compare the turn times with the cold "
              "turn 0 by hand (a resumed turn should take a small fraction of it)")
        sys.exit(2 if require else 0)
    ok = worst >= 0.9
    print("prompt_reuse:", "OK" if ok else f"FAILED: a turn resumed only {worst:.0%} of its prompt")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
