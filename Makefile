# One command per job, same shape as Mia's recipe.
# `make check` is what CI runs; nothing here needs a GPU except the bench targets.

SHELL := /bin/bash
RECIPE := recipe-tf-fbbc971

.PHONY: help check profiles triage ttft bench compare profile plan

help:
	@echo "make check                 validate profiles, syntax, shell scripts (CI runs this)"
	@echo "make triage                re-run the 53-patch triage against TF_TAG (default v1.2.7)"
	@echo "make profile NAME=ttft-fill write scripts/local.sh from profiles/<name>.env"
	@echo "make plan FREE=6.97        Nov 11 SparkOne MemAvailable; the trial pool stays at 1M"
	@echo "make ttft OUT=runs/a.json  TTFT on the trial (port 8890; refuses 8888/18004)"
	@echo "make bench OUT=runs/b.json prefill+decode on the trial (same refusal)"
	@echo "scripts/trial.sh restart   start the trial container, not the live serve"
	@echo "make compare A=runs/a.json B=runs/b.json"
	@echo ""
	@echo "profiles: $(shell ls profiles/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env//' | tr '\n' ' ')"

check:
	@python3 -m py_compile tools/ttft.py && echo "python OK: tools/ttft.py"
	@bash -n scripts/triage.sh && echo "bash OK: scripts/triage.sh"
	@bash -n scripts/profile.sh && echo "bash OK: scripts/profile.sh"
	@bash -n scripts/check-profiles.sh && echo "bash OK: scripts/check-profiles.sh"
	@bash -n scripts/memory-plan.sh && echo "bash OK: scripts/memory-plan.sh"
	@bash -n scripts/trial-guard.sh && echo "bash OK: scripts/trial-guard.sh"
	@bash -n scripts/trial.sh && echo "bash OK: scripts/trial.sh"
	@bash -n scripts/trial-env.sh && echo "bash OK: scripts/trial-env.sh"
	@bash -n scripts/gate.sh && echo "bash OK: scripts/gate.sh"
	@bash -n scripts/engine-trial.sh && echo "bash OK: scripts/engine-trial.sh"
	@bash -n scripts/fetch-engine.sh && echo "bash OK: scripts/fetch-engine.sh"
	@bash -n scripts/prepare-assets.sh && echo "bash OK: scripts/prepare-assets.sh"
	@bash -n scripts/build-image.sh && echo "bash OK: scripts/build-image.sh"
	@bash -n scripts/port-hash.sh && echo "bash OK: scripts/port-hash.sh"
	@scripts/gate.sh --self-check
	@python3 -m py_compile tools/endpoint_guard.py tools/bench.py scripts/gate_concurrency.py && echo "python OK: tools/endpoint_guard.py tools/bench.py scripts/gate_concurrency.py"
	@scripts/check-profiles.sh
	@python3 -I scripts/test_trial_guards.py

profiles:
	@scripts/check-profiles.sh

triage:
	@scripts/triage.sh

ttft:
	@test -n "$(OUT)" || { echo "usage: make ttft OUT=runs/a.json [SIZES=512,2048,8192]"; exit 2; }
	python3 -I tools/ttft.py --sizes $(or $(SIZES),512,2048,8192,32768) --reps $(or $(REPS),5) --out $(OUT)

bench:
	@test -n "$(OUT)" || { echo "usage: make bench OUT=runs/b.json"; exit 2; }
	python3 -I tools/bench.py --suite prefill,decode --out $(OUT)

compare:
	@test -n "$(A)" -a -n "$(B)" || { echo "usage: make compare A=runs/a.json B=runs/b.json"; exit 2; }
	python3 -I tools/ttft.py --compare $(A) $(B)

profile:
	@test -n "$(NAME)" || { echo "usage: make profile NAME=ttft-fill"; exit 2; }
	@scripts/profile.sh $(NAME) $(FORCE)

plan:
	@scripts/memory-plan.sh $(or $(FREE),6.97)
