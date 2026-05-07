# Launcher for the Symphony Elixir reference impl.
# Run `make` (or `make help`) for the cheat sheet.

SHELL := /bin/bash

ROOT          := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ELIXIR_DIR    := $(ROOT)/elixir
WORKFLOW      := $(ELIXIR_DIR)/WORKFLOW.md
BIN           := $(ELIXIR_DIR)/bin/symphony
RUN_DIR       := $(ROOT)/run
PID_FILE      := $(RUN_DIR)/symphony.pid
OUT_LOG       := $(RUN_DIR)/symphony.out
DASHBOARD_URL := http://localhost:3453

# Symphony refuses to launch without this acknowledgement; it runs Codex with
# `approval_policy: never` and `workspace-write` sandbox, so any agent in any
# workspace can read/write that workspace freely.
GUARDRAIL_ACK := --i-understand-that-this-will-be-running-without-the-usual-guardrails

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
.PHONY: help start stop restart status logs foreground build clean check-key check-built check-workflow

help: ## Show this help.
	@printf '$(BOLD)Symphony$(RESET)  $(DIM)— Linear-driven Codex orchestrator$(RESET)\n'
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
	@printf '  workflow      %s\n' "$$([ -f $(WORKFLOW) ] && echo '$(GREEN)✓$(RESET) $(WORKFLOW)' || echo '$(RED)✗$(RESET) $(WORKFLOW) (missing)')"
	@printf '  escript       %s\n' "$$([ -x $(BIN) ] && echo '$(GREEN)✓$(RESET) $(BIN)' || echo '$(RED)✗$(RESET) not built — run make build')"
	@printf '  LINEAR_API_KEY  %s\n' "$$( cd $(ELIXIR_DIR) && [ -n "$$(mise exec -- bash -c 'echo -n $$LINEAR_API_KEY' 2>/dev/null)" ] && echo '$(GREEN)✓$(RESET) loaded from mise env' || echo '$(RED)✗$(RESET) not set (see elixir/mise.local.toml)')"
	@printf '  daemon        %s\n' "$$([ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null && echo "$(GREEN)✓$(RESET) running (pid $$(cat $(PID_FILE))) — $(DASHBOARD_URL)" || echo '$(DIM)stopped$(RESET)')"
	@printf '\n'
	@printf '$(BOLD)Files:$(RESET)\n'
	@printf '  $(DIM)WORKFLOW.md$(RESET)            workflow config (YAML front matter + Codex prompt)\n'
	@printf '  $(DIM)elixir/mise.local.toml$(RESET) per-developer secrets, e.g. LINEAR_API_KEY\n'
	@printf '  $(DIM)run/symphony.pid$(RESET)       daemon PID\n'
	@printf '  $(DIM)run/symphony.out$(RESET)       stdout/stderr — see $(CYAN)make logs$(RESET)\n'
	@printf '  $(DIM)elixir/log/$(RESET)            structured per-issue logs (Symphony native)\n'

# --- Run -------------------------------------------------------------------
##@ Run
start: check-key check-built check-workflow ## Launch in background; writes PID file. Idempotent — bails if already running.
	@mkdir -p $(RUN_DIR)
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "$(YELLOW)symphony already running$(RESET) (pid $$(cat $(PID_FILE)))"; \
		exit 1; \
	fi
	@echo "starting symphony -> $(OUT_LOG)"
	@cd $(ELIXIR_DIR) && \
		nohup mise exec -- ./bin/symphony $(GUARDRAIL_ACK) $(WORKFLOW) > $(OUT_LOG) 2>&1 & \
		echo $$! > $(PID_FILE)
	@sleep 1
	@if kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "$(GREEN)started$(RESET) (pid $$(cat $(PID_FILE))) — dashboard: $(DASHBOARD_URL)"; \
	else \
		echo "$(RED)failed to start$(RESET); tail $(OUT_LOG):"; \
		tail -n 40 $(OUT_LOG); \
		rm -f $(PID_FILE); \
		exit 1; \
	fi

foreground: check-key check-built check-workflow ## Run attached (Ctrl-C to stop). Use for the first launch / debugging.
	@cd $(ELIXIR_DIR) && mise exec -- ./bin/symphony $(GUARDRAIL_ACK) $(WORKFLOW)

stop: ## Stop the running daemon (graceful, then SIGKILL after 10s).
	@if [ ! -f $(PID_FILE) ]; then \
		echo "$(DIM)no pid file at $(PID_FILE)$(RESET)"; \
		exit 0; \
	fi
	@PID=$$(cat $(PID_FILE)); \
	if kill -0 $$PID 2>/dev/null; then \
		echo "stopping symphony (pid $$PID)"; \
		kill $$PID; \
		for i in 1 2 3 4 5 6 7 8 9 10; do \
			kill -0 $$PID 2>/dev/null || break; \
			sleep 1; \
		done; \
		if kill -0 $$PID 2>/dev/null; then \
			echo "$(YELLOW)didn't exit gracefully; SIGKILL$(RESET)"; \
			kill -9 $$PID; \
		fi; \
	else \
		echo "$(DIM)pid $$PID not running$(RESET)"; \
	fi
	@rm -f $(PID_FILE)

restart: stop start ## Stop, then start.

# --- Inspect ---------------------------------------------------------------
##@ Inspect
status: ## Print daemon pid + dashboard URL (or "not running").
	@if [ -f $(PID_FILE) ] && kill -0 $$(cat $(PID_FILE)) 2>/dev/null; then \
		echo "$(GREEN)running$(RESET) (pid $$(cat $(PID_FILE)))"; \
		echo "dashboard: $(DASHBOARD_URL)"; \
	else \
		echo "$(DIM)not running$(RESET)"; \
		[ -f $(PID_FILE) ] && rm -f $(PID_FILE) || true; \
	fi

logs: ## Tail run/symphony.out (Ctrl-C to stop).
	@touch $(OUT_LOG)
	@tail -n 100 -f $(OUT_LOG)

# --- Build / clean ---------------------------------------------------------
##@ Build
build: ## Rebuild elixir/bin/symphony (mix build).
	@cd $(ELIXIR_DIR) && mise exec -- mix build

clean: ## Remove run/ (PID + stdout log). Does not touch elixir/log/.
	@rm -rf $(RUN_DIR)

# --- Internal preflight ----------------------------------------------------
check-key:
	@cd $(ELIXIR_DIR) && \
	if [ -z "$$(mise exec -- bash -c 'echo -n $$LINEAR_API_KEY')" ]; then \
		echo "$(RED)error:$(RESET) LINEAR_API_KEY is not set in the mise env"; \
		echo "  add it to $(CYAN)elixir/mise.local.toml$(RESET) under [env], or"; \
		echo "  export LINEAR_API_KEY in your shell before running make"; \
		exit 1; \
	fi

check-built:
	@if [ ! -x $(BIN) ]; then \
		echo "$(RED)error:$(RESET) $(BIN) not built. run '$(CYAN)make build$(RESET)' first."; \
		exit 1; \
	fi

check-workflow:
	@if [ ! -f $(WORKFLOW) ]; then \
		echo "$(RED)error:$(RESET) $(WORKFLOW) not found"; \
		exit 1; \
	fi
