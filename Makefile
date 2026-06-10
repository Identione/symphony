# Launcher for the Symphony Elixir reference impl.
# Run `make` (or `make help`) for the cheat sheet.
#
# This Makefile only builds the escript and creates per-operator instance
# folders under instances/<name>/. Daemon launches happen from the generated
# instance Makefile — see `make init` then `cd instances/<name> && make help`.

SHELL := /bin/bash

ROOT          := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ELIXIR_DIR    := $(ROOT)/elixir
BIN           := $(ELIXIR_DIR)/bin/symphony
INSTANCES_DIR := $(ROOT)/instances

INSTANCE      ?=
INSTANCE_DIR  := $(INSTANCES_DIR)/$(INSTANCE)
INSTANCE_WF   := $(INSTANCE_DIR)/WORKFLOW.md
INSTANCE_MK   := $(INSTANCE_DIR)/Makefile

# Per-operator batch-init manifest read by `make init-all` (gitignored).
INSTANCES_FILE ?= $(ROOT)/instances.local

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
.PHONY: help init init-all build clean upgrade upgrade-all check-built ensure-deps ensure-trust validate-instance

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
	@printf '$(BOLD)Instance workflow:$(RESET)\n'
	@printf '  1. $(CYAN)make build$(RESET)\n'
	@printf '  2. $(CYAN)make init INSTANCE=<name> ARGS="--linear-project <URL> --repo-url <URL> [--port N] [--host ADDR]"$(RESET)\n'
	@printf '     $(DIM)or bulk: list instances in $(CYAN)instances.local$(RESET)$(DIM) then $(CYAN)make init-all$(RESET) $(DIM)(see instances.local.example)$(RESET)\n'
	@printf '  3. $(CYAN)cd instances/<name>$(RESET) and use that folder'\''s Makefile (run, stop, logs, …)\n'
	@printf '  4. after $(CYAN)git pull$(RESET): $(CYAN)make upgrade-all$(RESET) (or $(CYAN)make upgrade INSTANCE=<name>$(RESET)) to rebuild + restart running daemons\n'
	@printf '\n'
	@printf '$(BOLD)State:$(RESET)\n'
	@printf '  escript       %s\n' "$$([ -x $(BIN) ] && echo '$(GREEN)✓$(RESET) $(BIN)' || echo '$(RED)✗$(RESET) not built — run make build')"
	@printf '  instances     %s\n' "$$([ -d $(INSTANCES_DIR) ] && echo '$(GREEN)✓$(RESET) '$$(find $(INSTANCES_DIR) -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)' under $(INSTANCES_DIR)' || echo '$(DIM)none yet$(RESET) — run make init INSTANCE=<name>')"

# --- Bootstrap -------------------------------------------------------------
##@ Bootstrap
init: ensure-trust check-built validate-instance ## Generate instances/<INSTANCE>/WORKFLOW.md + Makefile. Pass INSTANCE=name ARGS="--linear-project <URL> --repo-url <URL> [--port N] [--host ADDR] [--force] ...".
	@# The directory is created by symphony init's write_output (mkdir_p on
	@# dirname) so a validation failure does not leave an empty instances/<name>/
	@# behind.
	@cd $(ELIXIR_DIR) && mise exec -- ./bin/symphony init \
		--output "$(INSTANCE_WF)" \
		--instance-makefile "$(INSTANCE_MK)" \
		--instance-name "$(INSTANCE)" \
		$(ARGS)

init-all: ensure-trust check-built ## Generate every instance in instances.local (one per line: <name> <init-args>). FORCE=1 regenerates existing.
	@if [ ! -f "$(INSTANCES_FILE)" ]; then \
		echo "$(RED)error:$(RESET) $(INSTANCES_FILE) not found."; \
		echo "$(DIM)One instance per line: <name> --linear-project <URL> --repo-url <URL> [--port N] ...$(RESET)"; \
		echo "$(DIM)Copy the template: cp instances.local.example instances.local$(RESET)"; \
		exit 1; \
	fi
	@# Outer loop reads the manifest on fd 0; redirect each recursive make from
	@# /dev/null so it can't swallow the rest of the manifest stream.
	@set -e; \
	while read -r name args || [ -n "$$name" ]; do \
		case "$$name" in ''|\#*) continue;; esac; \
		if [ -f "$(INSTANCES_DIR)/$$name/Makefile" ] && [ -z "$(FORCE)" ]; then \
			printf '$(DIM)==  %s (exists — skipping; FORCE=1 to regenerate)$(RESET)\n' "$$name"; \
			continue; \
		fi; \
		printf '$(BOLD)==> %s$(RESET)\n' "$$name"; \
		$(MAKE) --no-print-directory init INSTANCE="$$name" ARGS="$$args $(if $(FORCE),--force,)" </dev/null; \
	done < "$(INSTANCES_FILE)"

# --- Upgrade ---------------------------------------------------------------
##@ Upgrade
upgrade: ensure-trust validate-instance ## Rebuild escript + restart instance daemon if it's running. INSTANCE=<name>.
	@if [ ! -f $(INSTANCE_MK) ]; then \
		echo "$(RED)error:$(RESET) instance $(INSTANCE) not found at $(INSTANCE_DIR)"; \
		exit 1; \
	fi
	@$(MAKE) --no-print-directory build
	@$(MAKE) -C $(INSTANCE_DIR) --no-print-directory _upgrade-restart-if-running

upgrade-all: ensure-trust ## Rebuild escript + restart every running instance daemon (serial, fail-fast).
	@# Single shell recipe: an early `exit 0` in a separate @line would not
	@# prevent later @lines from running, so the build must be gated inside
	@# the same shell as the empty-instances check.
	@dirs=$$(find $(INSTANCES_DIR) -mindepth 1 -maxdepth 1 -type d 2>/dev/null); \
	if [ -z "$$dirs" ]; then \
		echo "$(DIM)no instances to upgrade$(RESET)"; \
		exit 0; \
	fi; \
	set -e; \
	$(MAKE) --no-print-directory build; \
	for dir in $$dirs; do \
		[ -f $$dir/Makefile ] || continue; \
		printf '$(BOLD)==> %s$(RESET)\n' "$$(basename $$dir)"; \
		$(MAKE) -C $$dir --no-print-directory _upgrade-restart-if-running; \
	done

# Shared between `init` and `upgrade`: bail early on a missing/unsafe INSTANCE.
validate-instance:
	@if [ -z "$(INSTANCE)" ]; then \
		echo "$(RED)error:$(RESET) INSTANCE is required, e.g. '$(CYAN)INSTANCE=repo-a$(RESET)'"; \
		exit 1; \
	fi
	@case "$(INSTANCE)" in \
		*[!A-Za-z0-9_.-]*|.*|*..*) \
			echo "$(RED)error:$(RESET) invalid INSTANCE: $(INSTANCE) (allowed: A-Za-z0-9_.-, no leading '.', no '..')"; \
			exit 1; \
		;; \
	esac
# --- Build / clean ---------------------------------------------------------
##@ Build
build: ensure-deps ## Rebuild elixir/bin/symphony (mix build).
	@cd $(ELIXIR_DIR) && mise exec -- mix build

clean: ## Remove the instances directory entirely. WARNING: deletes all instance state.
	@rm -rf $(INSTANCES_DIR)

# --- Internal preflight ----------------------------------------------------
check-built:
	@if [ ! -x $(BIN) ]; then \
		echo "$(RED)error:$(RESET) $(BIN) not built. run '$(CYAN)make build$(RESET)' first."; \
		exit 1; \
	fi

# mise refuses to load an untrusted config (per-machine trust state), which
# silently breaks every `mise exec` downstream. Trust upfront so a fresh
# clone doesn't have to know about the `mise trust` step.
ensure-trust:
	@mise trust --quiet $(ELIXIR_DIR)

# Mix refuses to build with unfetched hex deps and dumps a wall of
# "package … not available" errors. Detect the empty deps/ dir up front and
# fetch deps so `make build` is self-healing on a fresh checkout. Call
# `mix deps.get` directly rather than the `mix setup` alias so future additions
# to that alias (ecto.create, asset pipelines, post-install hooks) cannot
# silently become part of `make build` via a `mix.exs` edit.
ensure-deps: ensure-trust
	@if [ ! -d $(ELIXIR_DIR)/deps ] || [ -z "$$(ls -A $(ELIXIR_DIR)/deps 2>/dev/null)" ]; then \
		echo "$(YELLOW)deps not fetched$(RESET); running '$(CYAN)mix deps.get$(RESET)' first..."; \
		cd $(ELIXIR_DIR) && mise exec -- mix deps.get; \
	fi
