.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e \
        start stop restart status logs foreground escript ensure-deps

# mise refuses to activate an untrusted config (per-machine trust state),
# which would silently strip mix/elixir from PATH. Trust at parse time so a
# fresh clone self-heals without a manual `mise trust`; the call is
# idempotent (~10ms) and the `|| true` keeps non-mise hosts from failing.
# Trust alone isn't enough — make's parent shell already had PATH set before
# parse-time, so we route mix through `mise exec` to pick up the now-trusted
# config in every recipe.
_ := $(shell mise trust --quiet . 2>/dev/null || true)
MIX ?= mise exec -- mix

WORKFLOW ?= $(CURDIR)/WORKFLOW.md
SYMPHONY_BIN ?= $(CURDIR)/bin/symphony
RUN_DIR ?= $(CURDIR)/../run
PIDFILE ?= $(RUN_DIR)/symphony.pid
LOGFILE ?= $(RUN_DIR)/symphony.out
SYMPHONY_FLAGS ?= --i-understand-that-this-will-be-running-without-the-usual-guardrails

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"
	@echo "Daemon:  start, stop, restart, status, logs, foreground (uses $(WORKFLOW))"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

# Self-heal `make build` when deps haven't been fetched yet (e.g. fresh
# checkout). Without this, mix dumps a wall of "package … not available"
# errors and exits non-zero.
ensure-deps:
	@if [ ! -d deps ] || [ -z "$$(ls -A deps 2>/dev/null)" ]; then \
	  echo "deps not fetched; running 'mix setup' first..."; \
	  $(MIX) setup; \
	fi

build: ensure-deps
	$(MIX) build

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci

# --- daemon launcher (reads WORKFLOW.md from elixir/) -----------------------

# Always rebuild the escript before launching. Make can't see .ex source
# files as deps so a file-target rule would skip rebuilds after edits, which
# silently launches a stale binary. Mix is incremental, so the cost when
# nothing changed is negligible (~100ms).
escript:
	@$(MIX) escript.build > /dev/null

foreground: escript
	@mkdir -p $(RUN_DIR)
	$(SYMPHONY_BIN) $(SYMPHONY_FLAGS) $(WORKFLOW)

start: escript
	@mkdir -p $(RUN_DIR)
	@if [ -f $(PIDFILE) ] && kill -0 $$(cat $(PIDFILE)) 2>/dev/null; then \
	  echo "symphony already running (pid $$(cat $(PIDFILE)))"; exit 0; \
	fi
	@nohup $(SYMPHONY_BIN) $(SYMPHONY_FLAGS) $(WORKFLOW) >> $(LOGFILE) 2>&1 & echo $$! > $(PIDFILE)
	@echo "symphony started (pid $$(cat $(PIDFILE))), logs: $(LOGFILE)"

stop:
	@if [ -f $(PIDFILE) ] && kill -0 $$(cat $(PIDFILE)) 2>/dev/null; then \
	  kill $$(cat $(PIDFILE)) && rm -f $(PIDFILE) && echo "symphony stopped"; \
	else \
	  echo "symphony not running"; rm -f $(PIDFILE); \
	fi

restart: stop start

status:
	@if [ -f $(PIDFILE) ] && kill -0 $$(cat $(PIDFILE)) 2>/dev/null; then \
	  echo "symphony running (pid $$(cat $(PIDFILE)))"; \
	else \
	  echo "symphony not running"; \
	fi

logs:
	@touch $(LOGFILE) && tail -F $(LOGFILE)
