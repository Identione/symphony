# Launcher for the Linear API Simulator (linear_sim).
# Run `make` (or `make help`) for the cheat sheet.
#
# This is a Phoenix app: `start` launches `mix phx.server` detached (PID + stdout
# under run/), `stop`/`restart`/`status`/`logs` control it, `foreground` runs it
# attached. Always goes through `mise exec --` so the pinned toolchain is used.

SHELL := /bin/bash

ROOT     := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RUN_DIR  := $(ROOT)/run
PID_FILE := $(RUN_DIR)/linear_sim.pid
OUT_LOG  := $(RUN_DIR)/linear_sim.out

# Dashboard / GraphQL port. Override: `make start PORT=4001`.
PORT ?= 4000

# tput-driven ANSI: empty when not a terminal, so `make help | cat` stays clean.
ifneq ($(shell tput colors 2>/dev/null),)
BOLD   := $(shell tput bold)
DIM    := $(shell tput dim)
RED    := $(shell tput setaf 1)
GREEN  := $(shell tput setaf 2)
YELLOW := $(shell tput setaf 3)
CYAN   := $(shell tput setaf 6)
RESET  := $(shell tput sgr0)
endif

.DEFAULT_GOAL := help
.PHONY: help setup start foreground stop restart status logs health clean \
        test compat ensure-trust ensure-deps

help: ## Show this help.
	@printf '$(BOLD)Linear API Simulator$(RESET)  $(DIM)— linear_sim$(RESET)\n'
	@printf '\n'
	@printf '$(BOLD)Usage:$(RESET) make $(CYAN)<target>$(RESET)\n'
	@printf '\n'
	@awk 'BEGIN { \
		section = ""; \
	} \
	/^##@ / { \
		section = substr($$0, 5); \
		printf "$(BOLD)%s$(RESET)\n", section; \
		next; \
	} \
	/^[a-zA-Z_-]+:.*?## / { \
		split($$0, parts, ":.*?## "); \
		target = parts[1]; \
		desc = parts[2]; \
		printf "  $(CYAN)%-12s$(RESET) %s\n", target, desc; \
	} \
	/^# ---/ { print ""; }' $(MAKEFILE_LIST)
	@printf '\n'
	@printf '$(BOLD)State:$(RESET)\n'
	@printf '  deps          %s\n' "$$([ $$(ls -A $(ROOT)/deps 2>/dev/null | wc -l) -gt 0 ] && echo '$(GREEN)✓$(RESET) fetched' || echo '$(RED)✗$(RESET) run make setup')"
	@printf '  daemon        %s\n' "$$([ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null && echo "$(GREEN)✓$(RESET) running (pid $$(cat $(PID_FILE))) $(CYAN)http://localhost:$(PORT)/$(RESET)" || echo '$(DIM)stopped$(RESET)')"

# --- Bootstrap -------------------------------------------------------------
##@ Bootstrap
setup: ensure-trust ## Fetch deps + create/migrate/seed the DB + copy assets (mix setup).
	@cd $(ROOT) && mise exec -- mix setup

# --- Start -----------------------------------------------------------------
##@ Start
start: ensure-trust ensure-deps ## Launch the Phoenix server detached.
	@mkdir -p $(RUN_DIR)
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
	  echo "$(RED)error:$(RESET) already running (pid $$(cat $(PID_FILE)))"; exit 1; \
	fi
	@echo "starting linear_sim -> $(OUT_LOG)"
	@# setsid puts the server in its own session/process group; the leader pid
	@# (== PGID) is recorded so `stop` can signal the whole group. `mix phx.server`
	@# spawns the BEAM as a child, so tracking a single pid would orphan it.
	@cd $(ROOT) && \
	  PORT=$(PORT) setsid sh -c 'echo $$$$ > "$(PID_FILE)"; exec mise exec -- mix phx.server' \
	    > "$(OUT_LOG)" 2>&1 < /dev/null &
	@sleep 2
	@if kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
	  echo "$(GREEN)started$(RESET) (pid $$(cat $(PID_FILE))) $(CYAN)http://localhost:$(PORT)/$(RESET)"; \
	else \
	  echo "$(RED)failed to start$(RESET); tail $(OUT_LOG):"; \
	  tail -n 40 $(OUT_LOG); \
	  rm -f $(PID_FILE); \
	  exit 1; \
	fi

foreground: ensure-trust ensure-deps ## Launch attached (Ctrl-C to stop).
	@# +Bd disables the Erlang break handler so a single Ctrl-C terminates the VM
	@# instead of dropping into the (a)bort/(c)ontinue break menu.
	@cd $(ROOT) && ELIXIR_ERL_OPTIONS="+Bd" PORT=$(PORT) mise exec -- mix phx.server

# --- Stop ------------------------------------------------------------------
##@ Stop
stop: ## Stop the server (graceful, then SIGKILL after 10s).
	@if [ ! -f $(PID_FILE) ]; then \
	  echo "$(DIM)no pid file at $(PID_FILE)$(RESET)"; \
	  exit 0; \
	fi
	@PID=$$(cat $(PID_FILE)); \
	if kill -0 $$PID 2>/dev/null; then \
	  echo "stopping linear_sim (pid $$PID)"; \
	  kill -TERM -$$PID 2>/dev/null || kill -TERM $$PID; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do \
	    kill -0 $$PID 2>/dev/null || break; \
	    sleep 1; \
	  done; \
	  if kill -0 $$PID 2>/dev/null; then \
	    echo "$(YELLOW)didn't exit gracefully; SIGKILL$(RESET)"; \
	    kill -9 -$$PID 2>/dev/null || kill -9 $$PID; \
	  fi; \
	else \
	  echo "$(DIM)pid $$PID not running$(RESET)"; \
	fi
	@rm -f $(PID_FILE)

restart: stop start ## Stop, then start.

# --- Status / logs ---------------------------------------------------------
##@ Status
status: ## Show whether the server is running.
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
	  echo "$(GREEN)running$(RESET) (pid $$(cat $(PID_FILE))) $(CYAN)http://localhost:$(PORT)/$(RESET)"; \
	else \
	  echo "$(DIM)not running$(RESET)"; \
	  [ -f $(PID_FILE) ] && rm -f $(PID_FILE) || true; \
	fi

logs: ## Tail the server stdout capture.
	@touch $(OUT_LOG)
	@tail -n 200 -f $(OUT_LOG)

health: ## Probe the /health endpoint.
	@curl -fsS http://localhost:$(PORT)/health && echo || echo "$(RED)unreachable$(RESET)"

# --- Test / clean ----------------------------------------------------------
##@ Test
test: ensure-trust ensure-deps ## Run the test suite (mix test).
	@cd $(ROOT) && mise exec -- mix test

##@ Compatibility
# Dump the simulator schema, validate curated ops against the simulator + the
# committed Linear reference (docs/linear-sim.md §6), replay them against
# scenarios, and write the report to tmp/linear_sim/. `fetch_schema` is NOT part
# of this chain — the Linear snapshot is refreshed deliberately (§2/§12) via
# `mise exec -- mix linear.fetch_schema`.
compat: ensure-trust ensure-deps ## Validate + replay curated ops; write the compatibility report.
	@cd $(ROOT) && mise exec -- mix linear_sim.dump_schema
	@cd $(ROOT) && mise exec -- mix linear_sim.validate_operations
	@cd $(ROOT) && mise exec -- mix linear_sim.replay_operations
	@cd $(ROOT) && mise exec -- mix linear_sim.compatibility_report

##@ Clean
clean: ## Remove run/ (PID + stdout capture).
	@rm -rf $(RUN_DIR)

# --- Internal preflight ----------------------------------------------------
# mise refuses to load an untrusted config, which silently breaks every
# `mise exec` downstream. Trust upfront so a fresh clone doesn't have to.
ensure-trust:
	@mise trust --quiet $(ROOT)

# Mix refuses to run with unfetched deps. Detect the empty deps/ dir up front
# and run `mix setup` so `make start` is self-healing on a fresh checkout.
ensure-deps: ensure-trust
	@if [ ! -d $(ROOT)/deps ] || [ -z "$$(ls -A $(ROOT)/deps 2>/dev/null)" ]; then \
	  echo "$(YELLOW)deps not fetched$(RESET); running '$(CYAN)mix setup$(RESET)' first..."; \
	  cd $(ROOT) && mise exec -- mix setup; \
	fi
