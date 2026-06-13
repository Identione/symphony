.PHONY: help all setup deps build fmt fmt-check lint test coverage ci dialyzer e2e \
        escript ensure-deps upgrade-tools python-test

# mise refuses to activate an untrusted config (per-machine trust state),
# which would silently strip mix/elixir from PATH. Trust at parse time so a
# fresh clone self-heals without a manual `mise trust`; the call is
# idempotent (~10ms) and the `|| true` keeps non-mise hosts from failing.
# Trust alone isn't enough — make's parent shell already had PATH set before
# parse-time, so we route mix through `mise exec` to pick up the now-trusted
# config in every recipe.
_ := $(shell mise trust --quiet . 2>/dev/null || true)
MIX ?= mise exec -- mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, python-test, e2e, ci, build, escript, all, upgrade-tools"
	@echo
	@echo "Daemon launches happen from generated instance Makefiles under instances/<name>/."
	@echo "Run 'make init INSTANCE=<name> ARGS=\"...\"' at the repo root to create one."
	@echo
	@echo "upgrade-tools bumps the agent toolchain (codex, claude-agent-sdk). This is"
	@echo "NOT the root 'make upgrade', which redeploys Symphony code to instances."

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

# Self-heal `make build` when deps haven't been fetched yet (e.g. fresh
# checkout). Without this, mix dumps a wall of "package … not available"
# errors and exits non-zero. Call `mix deps.get` directly rather than the
# `mix setup` alias so future additions to that alias (ecto.create, asset
# pipelines, post-install hooks) cannot silently become part of `make build`
# via a `mix.exs` edit.
ensure-deps:
	@if [ ! -d deps ] || [ -z "$$(ls -A deps 2>/dev/null)" ]; then \
	  echo "deps not fetched; running 'mix deps.get' first..."; \
	  $(MIX) deps.get; \
	fi

build: ensure-deps
	$(MIX) build

# Always rebuild the escript before launching. Make can't see .ex source
# files as deps so a file-target rule would skip rebuilds after edits, which
# silently launches a stale binary. Mix is incremental, so the cost when
# nothing changed is negligible (~100ms).
escript:
	@$(MIX) escript.build > /dev/null

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint: ensure-deps
	$(MIX) lint

coverage: ensure-deps
	$(MIX) test --cover

test: ensure-deps
	$(MIX) test

dialyzer: ensure-deps
	$(MIX) dialyzer --format short

# The Python sidecar harness (priv/claude_agent) ships its own pytest suite of
# pure-Python wire/option helpers (no claude-agent-sdk required). Run it through
# uv with the frozen lockfile so the pinned dev deps are used. Part of `ci` so
# this fork's only quality signal (local `make all`) covers the harness too.
python-test:
	cd priv/claude_agent && mise exec -- uv run --frozen pytest -q

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer
	$(MAKE) python-test

all: ci

# Bump the eager-tracked agent toolchain and refresh both lockfiles in one go:
# codex (mise.lock, "latest" pin) and claude-agent-sdk (priv/claude_agent/uv.lock,
# ">=" spec). Line-pinned tools (erlang/elixir/uv) stay put — change those by
# editing mise.toml. This is distinct from the root `make upgrade`, which rebuilds
# the escript and restarts instance daemons after a `git pull`.
upgrade-tools:
	mise upgrade codex
	cd priv/claude_agent && mise exec -- uv lock --upgrade
	@echo
	@echo "Lockfiles refreshed. Run 'make all', then commit mise.lock + priv/claude_agent/uv.lock."
