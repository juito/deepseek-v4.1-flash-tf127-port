# One command per job, same shape as Mia's recipe.
# `make check` is what CI runs; nothing here needs a GPU except the bench targets.

SHELL := /bin/bash
RECIPE := recipe-tf-fbbc971

.PHONY: help check profiles triage ttft bench compare profile plan

help:
	@echo "make check                 validate profiles, syntax, shell scripts (CI runs this)"
	@echo "make triage                re-run the 53-patch triage against TF_TAG (default v1.2.7)"
	@echo "make profile NAME=ttft     write scripts/local.sh from profiles/<name>.env"
	@echo "make plan FREE=9           spend the RAM left after the weights (KV pool budget)"
	@echo "make ttft OUT=runs/a.json  measure first token on a running server"
	@echo "make bench OUT=runs/b.json prefill+decode bench on a running server"
	@echo "make compare A=runs/a.json B=runs/b.json"
	@echo ""
	@echo "profiles: $(shell ls profiles/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env//' | tr '\n' ' ')"

check:
	@python3 -m py_compile tools/ttft.py && echo "python OK: tools/ttft.py"
	@bash -n scripts/triage.sh && echo "bash OK: scripts/triage.sh"
	@bash -n scripts/profile.sh && echo "bash OK: scripts/profile.sh"
	@bash -n scripts/check-profiles.sh && echo "bash OK: scripts/check-profiles.sh"
	@bash -n scripts/memory-plan.sh && echo "bash OK: scripts/memory-plan.sh"
	@scripts/check-profiles.sh

profiles:
	@scripts/check-profiles.sh

triage:
	@scripts/triage.sh

ttft:
	@test -n "$(OUT)" || { echo "usage: make ttft OUT=runs/a.json [SIZES=512,2048,8192]"; exit 2; }
	python3 -I tools/ttft.py --sizes $(or $(SIZES),512,2048,8192,32768) --reps $(or $(REPS),5) --out $(OUT)

bench:
	@test -n "$(OUT)" || { echo "usage: make bench OUT=runs/b.json"; exit 2; }
	python3 -I $(RECIPE)/tools/bench.py --suite prefill,decode --out $(OUT)

compare:
	@test -n "$(A)" -a -n "$(B)" || { echo "usage: make compare A=runs/a.json B=runs/b.json"; exit 2; }
	python3 -I tools/ttft.py --compare $(A) $(B)

profile:
	@test -n "$(NAME)" || { echo "usage: make profile NAME=ttft"; exit 2; }
	@scripts/profile.sh $(NAME) $(FORCE)

plan:
	@scripts/memory-plan.sh $(or $(FREE),9)
