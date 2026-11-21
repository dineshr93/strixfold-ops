# StrixFold TP2 serve lifecycle — DeepSeek-V4.1 port on the two Strix Halo boxes.
#
# stop/status wrap TensorFold's first_light.sh; start uses scripts/start-serve.sh:
# staggered boot (rank 1 loads first) with stall detection + retry — the weight
# load intermittently wedges (HSA signal spin + kernel SVM-restore livelock).
# Both ranks read ONE config: ~/tfp/run/conf/my.conf, which must exist at the same
# path under each box's $HOME (edit it here, then: make sync-conf).
#
# Current serving settings (my.conf): CONTEXT=1048576 (1M; the ds-kit RoPE tables
# were extended to the creator kit's full 1,114,112 verified rows — hard cap is
# rows - 49; originals backed up in ~/tfp/run/ds-kit-65536-backup on both boxes),
# SERVE_HOST=0.0.0.0, SERVE_PORT=8888, SERVE_NAME=local-model (the name
# /v1/models and chat requests use), MODALITIES=text for 'make start'.
# 'make startv' brings the same pair up with the model's vision tower on: it installs
# my-vision.conf (my.conf + the image keys — the sidecar, the gate bias and the kit's
# vision object are staged on both boxes) and starts with that conf. Make stop first
# to switch between the two.
#
# Memory: a rank starts only with MemAvailable >= PEAK_GIB + 8 (107 + 8 GiB) and
# no other engine on its box — stop halogen (make halogen-stop) and any docker
# GPU stacks before start.

SHELL  := /bin/bash
TOOLS  := $(HOME)/tfp/deploy/current/tools/dsv41-hip
CONF   := $(HOME)/tfp/run/conf/my.conf
CONFV  := $(HOME)/tfp/run/conf/my-vision.conf
RUN    := $(HOME)/tfp/run/serve/latest
FL     = TF_SERVE_CONF=$(CONF) $(TOOLS)/first_light.sh
R0     := node0
# source, don't grep: CONF may be an overlay that sources my.conf (my-vision.conf),
# whose SERVE_PORT/SERVE_NAME lines are not literal in the overlay file itself
PORT   := $(shell bash -c '. "$$1" >/dev/null 2>&1; printf "%s" "$${SERVE_PORT:-}"' bash $(CONF))
API    ?= http://10.40.0.1:$(PORT)
MODEL  ?= $(shell bash -c '. "$$1" >/dev/null 2>&1; printf "%s" "$${SERVE_NAME:-}"' bash $(CONF))

.DEFAULT_GOAL := help
.PHONY: help start startv _gate stop restart status sync-conf conf health models probe logs logs0 bench show halogen-stop halogen-up setup preflight $(addprefix setup-,$(notdir $(wildcard scripts/setup/[0-9]*.sh)))

help: ## Show this help
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

setup: ## From-scratch setup: read AGENTS.md, then run the phases in order
	@echo "Read AGENTS.md first. Then: make preflight, and work the phases:"
	@ls scripts/setup/[0-9]*.sh | sed 's|scripts/setup/|  bash scripts/setup/|'

preflight: ## Audit both boxes (read-only), print the gap list
	bash scripts/setup/00-preflight.sh

setup-%: ## Run one setup phase, e.g. make setup-04-rocm
	bash scripts/setup/$*.sh

start: _gate ## Bring the pair up, staggered, text only (rank 1 loads first; probe; minutes)
	bash scripts/start-serve.sh

startv: _gate ## Bring the pair up with the vision tower too (MODALITIES=text_image)
	@bash scripts/vision-conf.sh
	CONF=$(CONFV) bash scripts/start-serve.sh

# the precondition both starts share: no other engine on node0 (the memory gate)
_gate:
	@ssh $(R0) 'podman ps --format "{{.Names}}"' | grep -q '^halogen-flash-server$$' && \
		{ echo "halogen-flash-server is running on node0 — 'make halogen-stop' first (memory gate)"; exit 1; } || true

stop: ## Stop both ranks cleanly (SIGTERM rank 0, rank 1 follows, locks released)
	$(FL) down

restart: ## down, then the staggered start
	$(FL) down
	bash scripts/start-serve.sh

status: ## Both ranks' state and GPU-lock holders
	$(FL) status

sync-conf: ## Copy my.conf to node0 (both boxes must read the same file)
	scp $(CONF) $(R0):tfp/run/conf/my.conf

conf: ## Show the serving knobs in my.conf
	@grep -E '^(CONTEXT|POOL|STREAMS|PARALLEL|SERVE_HOST|SERVE_PORT|SERVE_NAME|MODALITIES|PEAK_GIB|MEMORY_LIMIT_GB|MAX_TOKENS|BENCH)=' $(CONF)

health: ## rank 0's /health
	@curl -fsS $(API)/health && echo

models: ## /v1/models — the served alias and max_model_len
	@curl -fsS $(API)/v1/models | python3 -m json.tool

probe: ## One chat completion against the served model
	@curl -fsS $(API)/v1/chat/completions -H 'Content-Type: application/json' \
		-d '{"model":"$(MODEL)","messages":[{"role":"user","content":"Answer in one sentence: what is the capital of France?"}],"max_tokens":64,"temperature":0}' \
		| python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["choices"][0]["message"]["content"])'

logs: ## Follow rank 1's log (this box)
	tail -n 50 -f $(RUN)/rank1.log

logs0: ## Follow rank 0's log (node0)
	ssh $(R0) 'tail -n 50 -f $$HOME/tfp/run/serve/latest/rank0.log'

bench: ## The last run's bench numbers
	@cat $(RUN)/bench.json | python3 -m json.tool

show: ## Artifacts on BOTH boxes: engines, kits, weights, configs, paths
	@echo '===== node1 (this box, rank 1) ====='
	@bash scripts/show-artifacts.sh
	@echo; echo '===== node0 (rank 0) ====='
	@ssh $(R0) 'bash -s' < scripts/show-artifacts.sh

halogen-stop: ## Stop the agent's podman LLM backend on node0 (frees ~71 GB)
	ssh $(R0) podman stop halogen-flash-server

halogen-up: ## Restore the agent's podman LLM backend on node0 (after stop!)
	ssh $(R0) ~/bin/halogen-up
