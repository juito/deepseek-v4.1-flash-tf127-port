"""Refuse to measure the live TensorFold serve by accident.

The trial listens on port 8890. The live serve is port 8888 on the Sparks,
and the Mac tunnel is local port 18004. Tools default to the trial. Passing
--allow-live is the only way to point them at 8888 or 18004, and even then
/metrics must report requests_running == 0 before any request is sent.
"""
from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request

TRIAL_PORT = 8890
LIVE_PORTS = {8888, 18004}
DEFAULT_BASE = f"http://127.0.0.1:{TRIAL_PORT}"

# tensorfold:requests_running, num_requests_running, vllm:num_requests_running, ...
_METRIC = re.compile(
    r"^(?:[A-Za-z_][\w]*:)?(?:requests_running|num_requests_running)"
    r"(?:\{[^}]*\})?\s+([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*$"
)
_PORT = re.compile(r":(\d+)(?:/|$)")


class LiveEndpoint(SystemExit):
    """A refused live port or a server that is not idle."""


def port_of(url: str) -> int | None:
    match = _PORT.search(url)
    if not match:
        return None
    return int(match.group(1))


def assert_trial_url(url: str, allow_live: bool = False) -> str:
    """Return the URL, or refuse ports 8888 and 18004."""
    url = url.rstrip("/")
    port = port_of(url)
    if port in LIVE_PORTS and not allow_live:
        raise LiveEndpoint(
            f"refusing {url}: port {port} is the live serve (8888) or the Mac "
            f"tunnel (18004). The trial port is {TRIAL_PORT}. Pass --allow-live "
            "to measure the live serve on purpose."
        )
    return url


def default_base() -> str:
    """Trial URL: API_URL, else http://127.0.0.1:$PORT, else port 8890.

    HOST=0.0.0.0 is refused here too. A loopback client must not be rewritten
    onto the wildcard address.
    """
    url = os.environ.get("API_URL")
    if url:
        return url.rstrip("/")
    host = os.environ.get("TRIAL_HOST") or "127.0.0.1"
    if host in {"0.0.0.0", "::", "[::]", "*"}:
        raise LiveEndpoint(f"HOST={host} is refused. Never measure via 0.0.0.0.")
    port = os.environ.get("PORT") or str(TRIAL_PORT)
    return f"http://{host}:{port}"


def parse_requests_running(body: str) -> float | None:
    """The requests_running gauge, or None when the scrape does not carry one.

    Prometheus text and a JSON object are both accepted. If several matching
    gauges are present and any is non-zero, that non-zero value is returned.
    """
    text = body.strip()
    if text.startswith("{") or text.startswith("["):
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            data = None
        if isinstance(data, dict):
            for key in ("requests_running", "num_requests_running"):
                if key in data:
                    return float(data[key])
            live = data.get("live")
            if isinstance(live, dict) and "requests_running" in live:
                return float(live["requests_running"])
    values: list[float] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = _METRIC.match(line)
        if match:
            values.append(float(match.group(1)))
    if not values:
        return None
    if any(value != 0 for value in values):
        return max(values)
    return 0.0


def assert_idle(base: str, timeout: float = 10.0) -> None:
    """GET /metrics and refuse unless every requests_running gauge is 0."""
    url = base.rstrip("/") + "/metrics"
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200]
        raise LiveEndpoint(f"refusing to bench: {url} returned HTTP {exc.code}: {detail}") from None
    except urllib.error.URLError as exc:
        raise LiveEndpoint(f"refusing to bench: cannot read {url} ({exc.reason})") from None
    running = parse_requests_running(body)
    if running is None:
        raise LiveEndpoint(
            f"refusing to bench: {url} has no requests_running gauge. "
            "Not sending traffic to a server whose load is unknown."
        )
    if running != 0:
        raise LiveEndpoint(
            f"refusing to bench: requests_running={running:g} at {url} (want 0)"
        )
