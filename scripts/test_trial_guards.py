#!/usr/bin/env python3
"""Guards for the side-by-side trial. No GPU, no docker daemon, no Spark.

Asserts:
  - live container, image tag, and ports 8888 and 18004 are refused
  - HOST 0.0.0.0 is refused; the default host is 127.0.0.1
  - --stop-live is docker stop only (never rm, never a retag)
  - every profile has CONTEXT <= 524288
  - tools default to port 8890 and refuse to bench a busy /metrics
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from endpoint_guard import (  # noqa: E402
    DEFAULT_BASE,
    assert_idle,
    assert_trial_url,
    default_base,
    parse_requests_running,
)

LIVE_CONTAINER = "dsv41-1017-exl3-tf"
LIVE_IMAGE = "tensorfold-dsv41:exl3-tp2-8a98ae503d85"
TRIAL_CONTAINER = "dsv41-tf127-trial"
TRIAL_PORT = "8890"
MAX_CONTEXT = 524288

failures = 0


def check(cond: bool, message: str) -> None:
    global failures
    if cond:
        print(f"ok   {message}")
    else:
        failures += 1
        print(f"FAIL {message}", file=sys.stderr)


def uncommented(path: Path) -> str:
    lines = []
    for line in path.read_text(encoding="utf-8").splitlines():
        lines.append(line.split("#", 1)[0])
    return "\n".join(lines)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = self.server.body  # type: ignore[attr-defined]
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args) -> None:
        return


def serve(body: str) -> tuple[ThreadingHTTPServer, int]:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.body = body  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, server.server_address[1]


def fake_docker(bin_dir: Path) -> None:
    script = """#!/bin/sh
log="${DOCKER_LOG:?}"
state_dir="${DOCKER_STATE:?}"
printf '%s\\n' "$*" >> "$log"
cmd="$1"
if [ "$cmd" = rm ] || [ "$cmd" = rmi ] || [ "$cmd" = tag ]; then
  echo "REFUSED $*" >> "$log"
  exit 99
fi
if [ "$cmd" = info ]; then
  exit 0
fi
name=""
for a in "$@"; do name="$a"; done
if [ "$cmd" = inspect ]; then
  if [ ! -f "$state_dir/$name" ]; then
    exit 1
  fi
  cat "$state_dir/$name"
  exit 0
fi
if [ "$cmd" = stop ]; then
  printf '%s\\n' false > "$state_dir/$name"
  exit 0
fi
if [ "$cmd" = start ]; then
  printf '%s\\n' true > "$state_dir/$name"
  exit 0
fi
exit 0
"""
    path = bin_dir / "docker"
    path.write_text(script, encoding="utf-8")
    path.chmod(0o755)


def run_trial(args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(ROOT / "scripts" / "trial.sh"), *args],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def base_env(log: Path, state: Path, bin_dir: Path) -> dict[str, str]:
    env = os.environ.copy()
    for key in (
        "HOST", "PORT", "IMAGE", "CONTAINER_NAME", "API_URL", "ALLOW_LIVE",
        "STOP_LIVE", "WORKER", "DRY_RUN", "TRIAL_LOCAL_ONLY", "TRIAL_HOST",
    ):
        env.pop(key, None)
    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    env["DOCKER_LOG"] = str(log)
    env["DOCKER_STATE"] = str(state)
    env["TRIAL_LOCAL_ONLY"] = "1"
    return env


def main() -> int:
    # --- profiles: CONTEXT cap, no wildcard bind, no live names ---
    profiles = sorted((ROOT / "profiles").glob("*.env"))
    check(profiles, "profiles/ is not empty")
    check(not (ROOT / "profiles" / "ttft.env").exists(), "combined ttft.env is gone")
    check((ROOT / "profiles" / "ttft-fill.env").exists(), "ttft-fill.env exists")
    check((ROOT / "profiles" / "ttft-interleave.env").exists(), "ttft-interleave.env exists")
    for path in profiles:
        text = path.read_text(encoding="utf-8")
        ctx = None
        assigned: dict[str, str] = {}
        for line in text.splitlines():
            code = line.split("#", 1)[0].strip()
            if not code or "=" not in code:
                continue
            key, val = code.split("=", 1)
            key = key.removeprefix("export ").strip()
            val = val.strip().strip("\"'")
            assigned[key] = val
            if key == "CONTEXT":
                ctx = int(val)
            if key == "HOST":
                check(val not in {"0.0.0.0", "::", "*"}, f"{path.name} HOST is not a wildcard")
            if key == "PORT":
                check(val not in {"8888", "18004"}, f"{path.name} PORT is not live")
            if key == "CONTAINER_NAME":
                check(val != LIVE_CONTAINER, f"{path.name} container is not live")
            if key == "IMAGE":
                check(LIVE_IMAGE not in val and "exl3-tp2-8a98ae503d85" not in val,
                      f"{path.name} does not name the live image")
        check(ctx is not None and ctx <= MAX_CONTEXT, f"{path.name} CONTEXT={ctx} <= {MAX_CONTEXT}")
        if path.name == "ttft-fill.env":
            check(assigned.get("TF_FILL_CHUNKS") == "1" and assigned.get("PREFILL_INTERLEAVE_MS") == "0",
                  "ttft-fill sets chunks and turns interleave off")
            check(assigned.get("PREFILL_INTERLEAVE_MS") != "250", "ttft-fill does not also set interleave 250")
        if path.name == "ttft-interleave.env":
            check(assigned.get("PREFILL_INTERLEAVE_MS") == "250", "ttft-interleave sets 250 ms")
            check("TF_FILL_CHUNKS" not in assigned, "ttft-interleave does not set TF_FILL_CHUNKS")

    proc = subprocess.run(["bash", str(ROOT / "scripts" / "check-profiles.sh")],
                          cwd=ROOT, text=True, capture_output=True, check=False)
    check(proc.returncode == 0, f"check-profiles.sh passes\n{proc.stdout}{proc.stderr}")

    bad = ROOT / "profiles" / "_bad_context.env"
    both = ROOT / "profiles" / "_bad_both.env"
    try:
        bad.write_text("CONTEXT=1048576\nPARALLEL=4\n", encoding="utf-8")
        proc = subprocess.run(["bash", str(ROOT / "scripts" / "check-profiles.sh")],
                              cwd=ROOT, text=True, capture_output=True, check=False)
        check(proc.returncode != 0 and "524288" in proc.stderr, "CONTEXT=1048576 is refused")
        bad.unlink()
        both.write_text(
            "CONTEXT=524288\nPREFILL_INTERLEAVE_MS=250\nTF_FILL_CHUNKS=1\n",
            encoding="utf-8",
        )
        proc = subprocess.run(["bash", str(ROOT / "scripts" / "check-profiles.sh")],
                              cwd=ROOT, text=True, capture_output=True, check=False)
        check(proc.returncode != 0 and "mutually exclusive" in proc.stderr,
              "fill chunks plus interleave are refused")
    finally:
        bad.unlink(missing_ok=True)
        both.unlink(missing_ok=True)

    for rel in ("scripts/trial.sh", "scripts/trial-guard.sh", "scripts/trial-env.sh", "scripts/profile.sh"):
        code = uncommented(ROOT / rel)
        check("docker rm" not in code, f"{rel} never calls docker rm")
        check("docker tag" not in code, f"{rel} never calls docker tag")
    # HOST default in the guard source is 127.0.0.1, and 0.0.0.0 only appears as a refusal.
    guard = (ROOT / "scripts" / "trial-guard.sh").read_text(encoding="utf-8")
    check('printf \'%s\\n\' "127.0.0.1"' in guard, "default host is 127.0.0.1")
    check("0.0.0.0" in guard and "refused" in guard, "0.0.0.0 is named only to be refused")

    # --- trial.sh against a fake docker ---
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        bin_dir = tmp_path / "bin"
        state = tmp_path / "state"
        log = tmp_path / "docker.log"
        bin_dir.mkdir()
        state.mkdir()
        fake_docker(bin_dir)
        local = ROOT / "recipe-tf-fbbc971" / "scripts" / "local.sh"
        saved = local.read_text(encoding="utf-8") if local.exists() else None

        def reset(live: str | None) -> dict[str, str]:
            log.write_text("", encoding="utf-8")
            for child in state.iterdir():
                child.unlink()
            if live is not None:
                (state / LIVE_CONTAINER).write_text(live + "\n", encoding="utf-8")
            if local.exists():
                local.unlink()
            return base_env(log, state, bin_dir)

        try:
            env = reset("false\n".strip())
            # write false without the strip confusion
            (state / LIVE_CONTAINER).write_text("false\n", encoding="utf-8")
            proc = run_trial(["--guard-only", "restart"], env)
            out = proc.stdout + proc.stderr
            check(proc.returncode == 0, f"guard-only restart with live stopped exits 0\n{out}")
            check(f"container={TRIAL_CONTAINER}" in proc.stdout, "trial container name")
            check(f"port={TRIAL_PORT}" in proc.stdout, "trial port")
            check("host=127.0.0.1" in proc.stdout, "default host 127.0.0.1")
            image = re.search(r"image=(\S+)", proc.stdout)
            check(image is not None and image.group(1).startswith("tensorfold-dsv41:tf127-trial-"),
                  "trial image namespace")
            check(image is not None and image.group(1) != LIVE_IMAGE, "resolved image is not the live tag")
            blog = log.read_text(encoding="utf-8")
            check("rm " not in blog and "\nrm" not in blog and " tag " not in blog and not blog.startswith("tag"),
                  f"docker log has no rm or tag\n{blog}")
            check("stop -t" not in blog, "does not stop a container that is already stopped")

            env = reset("true")
            (state / LIVE_CONTAINER).write_text("true\n", encoding="utf-8")
            proc = run_trial(["--guard-only", "restart"], env)
            check(proc.returncode != 0, "refuses to start while the live container is running")
            check(LIVE_CONTAINER in proc.stderr and "--stop-live" in proc.stderr, "the refusal names --stop-live")
            check("stop -t" not in log.read_text(encoding="utf-8"), "refusal does not stop anything")
            check("rm" not in log.read_text(encoding="utf-8"), "refusal does not rm")

            env = reset("true")
            (state / LIVE_CONTAINER).write_text("true\n", encoding="utf-8")
            proc = run_trial(["--stop-live", "--guard-only", "restart"], env)
            blog = log.read_text(encoding="utf-8")
            check(proc.returncode == 0, f"--stop-live then guard-only exits 0\n{proc.stderr}")
            check("stop -t" in blog and LIVE_CONTAINER in blog, "docker stop the live container")
            check("rm" not in blog and "tag " not in blog, "stop-live never rm or retag")
            check((state / LIVE_CONTAINER).read_text(encoding="utf-8").strip() == "false",
                  "live container is stopped, not removed")

            for extra, needle in (
                ({"HOST": "0.0.0.0"}, "refused"),
                ({"HOST": "::"}, "refused"),
                ({"CONTAINER_NAME": LIVE_CONTAINER}, LIVE_CONTAINER),
                ({"IMAGE": LIVE_IMAGE}, "retag"),
                ({"IMAGE": "tensorfold-dsv41:exl3-tp2-deadbeef0000"}, "trial namespace"),
                ({"PORT": "8888"}, "8888"),
                ({"PORT": "18004"}, "18004"),
            ):
                env = reset("false")
                (state / LIVE_CONTAINER).write_text("false\n", encoding="utf-8")
                env.update(extra)
                proc = run_trial(["--guard-only", "restart"], env)
                blob = proc.stdout + proc.stderr
                check(proc.returncode != 0 and needle in blob,
                      f"refuses {extra} ({needle})\n{blob}")
                check("rm" not in log.read_text(encoding="utf-8"), f"no rm while refusing {extra}")

            env = reset("false")
            (state / LIVE_CONTAINER).write_text("false\n", encoding="utf-8")
            env["HOST"] = "100.78.243.41"
            proc = run_trial(["--guard-only", "restart"], env)
            check(proc.returncode == 0 and "host=100.78.243.41" in proc.stdout,
                  "SparkOne Tailscale IP is an allowed HOST")

            env = reset("false")
            (state / LIVE_CONTAINER).write_text("false\n", encoding="utf-8")
            local.write_text(
                "CONTAINER_NAME=dsv41-1017-exl3-tf\nPORT=8888\nHOST=0.0.0.0\n"
                "IMAGE=tensorfold-dsv41:exl3-tp2-8a98ae503d85\n",
                encoding="utf-8",
            )
            proc = run_trial(["--guard-only", "restart"], env)
            check(proc.returncode != 0, f"local.sh naming the live serve is refused\n{proc.stderr}")
            local.unlink()

            env = reset(None)
            (state / TRIAL_CONTAINER).write_text("true\n", encoding="utf-8")
            proc = run_trial(["stop"], env)
            blog = log.read_text(encoding="utf-8")
            check(proc.returncode == 0 and "stop -t" in blog and TRIAL_CONTAINER in blog,
                  "stop stops the trial container")
            check(LIVE_CONTAINER not in blog, "stop does not name the live container")
            check("rm" not in blog, "stop does not rm")

            env = reset("false")
            (state / LIVE_CONTAINER).write_text("false\n", encoding="utf-8")
            proc = run_trial(["rollback"], env)
            blog = log.read_text(encoding="utf-8")
            check(proc.returncode == 0 and f"start {LIVE_CONTAINER}" in blog, "rollback docker starts the live container")
            check("rm" not in blog and "tag " not in blog, "rollback does not rm or retag")
            check("8888" in proc.stdout, "rollback tells the operator to check port 8888")

            # profile.sh instructions and the file it writes
            proc = subprocess.run(
                ["bash", str(ROOT / "scripts" / "profile.sh"), "ttft-fill", "--force"],
                cwd=ROOT, text=True, capture_output=True, check=False,
            )
            check(proc.returncode == 0, f"profile.sh ttft-fill\n{proc.stderr}")
            check("scripts/trial.sh restart" in proc.stdout, "profile.sh points at scripts/trial.sh")
            check("./start.sh" not in proc.stdout, "profile.sh does not tell anyone to run ./start.sh")
            written = local.read_text(encoding="utf-8")
            assignments = [
                line.split("#", 1)[0].strip()
                for line in written.splitlines()
                if line.split("#", 1)[0].strip()
            ]
            check("CONTAINER_NAME=dsv41-tf127-trial" in assignments, "local.sh trial container")
            check("PORT=8890" in assignments, "local.sh trial port")
            check("HOST=127.0.0.1" in assignments, "local.sh host is loopback")
            check(not any(line.startswith("HOST=0.0.0.0") or line.startswith("PORT=8888")
                          or line.startswith("PORT=18004") or LIVE_CONTAINER + "=" in line
                          or "CONTAINER_NAME=" + LIVE_CONTAINER in line
                          for line in assignments),
                  "local.sh assignments do not name the live serve or 0.0.0.0")
        finally:
            if saved is None:
                local.unlink(missing_ok=True)
            else:
                local.write_text(saved, encoding="utf-8")

    # --- endpoint defaults and the idle check ---
    held = {key: os.environ.get(key) for key in ("API_URL", "PORT", "TRIAL_HOST", "HOST")}
    try:
        for key in held:
            os.environ.pop(key, None)
        check(default_base() == DEFAULT_BASE == "http://127.0.0.1:8890",
              f"default URL is {default_base()}")
    finally:
        for key, val in held.items():
            if val is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = val

    for url in ("http://127.0.0.1:8888", "http://100.78.243.41:8888", "http://127.0.0.1:18004"):
        try:
            assert_trial_url(url, allow_live=False)
            check(False, f"{url} should be refused")
        except SystemExit as exc:
            check(True, f"refuses {url}")
            check("allow-live" in str(exc), f"refusal of {url} mentions --allow-live")
    check(assert_trial_url("http://127.0.0.1:8890") == "http://127.0.0.1:8890", "8890 is allowed")
    check(assert_trial_url("http://127.0.0.1:8888", allow_live=True).endswith(":8888"),
          "--allow-live permits 8888")

    body = "# TYPE tensorfold:requests_running gauge\ntensorfold:requests_running 0\ntensorfold:num_requests_running 0\n"
    check(parse_requests_running(body) == 0, "parses a zero requests_running scrape")
    check(parse_requests_running("tensorfold:requests_running 2\n") == 2, "parses a busy scrape")
    check(parse_requests_running("# only comments\n") is None, "missing gauge is unknown")
    check(parse_requests_running('{"requests_running": 0}') == 0, "parses JSON requests_running")

    idle, idle_port = serve("tensorfold:requests_running 0\ntensorfold:num_requests_running 0\n")
    busy, busy_port = serve("tensorfold:requests_running 1\n")
    try:
        assert_idle(f"http://127.0.0.1:{idle_port}")
        check(True, "idle /metrics is accepted")
        try:
            assert_idle(f"http://127.0.0.1:{busy_port}")
            check(False, "busy /metrics should be refused")
        except SystemExit as exc:
            check("requests_running=1" in str(exc), "busy /metrics is refused")
    finally:
        idle.shutdown()
        busy.shutdown()

    def tool(args: list[str]) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        for key in ("API_URL", "PORT", "TRIAL_HOST", "HOST"):
            env.pop(key, None)
        return subprocess.run(
            [sys.executable, "-I", *args],
            cwd=ROOT, env=env, text=True, capture_output=True, check=False,
        )

    proc = tool([str(ROOT / "tools" / "ttft.py"), "--url", "http://127.0.0.1:8888", "--sizes", "1"])
    check(proc.returncode != 0 and "8888" in (proc.stderr + proc.stdout), "ttft.py refuses 8888")
    proc = tool([str(ROOT / "tools" / "bench.py"), "--url", "http://127.0.0.1:18004", "--out", "runs/x.json"])
    check(proc.returncode != 0 and "18004" in (proc.stderr + proc.stdout), "bench.py refuses 18004")
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    bench_rule = makefile.split("bench:", 1)[1].split("\ncompare:", 1)[0]
    check("tools/bench.py" in bench_rule, "make bench uses tools/bench.py")
    check("recipe-tf-fbbc971/tools/bench.py" not in bench_rule, "make bench does not call the recipe bench directly")
    proc = tool([str(ROOT / "tools" / "ttft.py"), "--help"])
    # --help exits 0 from argparse before the guard. Just ensure it does not crash.
    check(proc.returncode == 0, "ttft.py --help works")

    env = os.environ.copy()
    for key in ("HOST", "PORT", "API_URL", "ALLOW_LIVE"):
        env.pop(key, None)
    proc = subprocess.run(["bash", str(ROOT / "scripts" / "trial-env.sh")],
                          cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    check(proc.returncode == 0, f"trial-env.sh\n{proc.stderr}")
    check("PORT=8890" in proc.stdout or "PORT='8890'" in proc.stdout, f"trial-env port 8890\n{proc.stdout}")
    check("8888" not in proc.stdout and "18004" not in proc.stdout, "trial-env does not print live ports")
    check("0.0.0.0" not in proc.stdout, "trial-env does not print 0.0.0.0")
    env["PORT"] = "8888"
    proc = subprocess.run(["bash", str(ROOT / "scripts" / "trial-env.sh")],
                          cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    check(proc.returncode != 0 and "8888" in proc.stderr, "trial-env refuses PORT=8888")

    if failures:
        print(f"\n{failures} failure(s)", file=sys.stderr)
        return 1
    print(f"\ntrial guards OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
