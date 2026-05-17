# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Symphony is a Linear-driven coding-agent orchestrator: it polls Linear for work, creates a per-issue workspace, and runs a coding-agent session against it. The active adapter is selected per workflow via `agent.kind` (SPEC.md §10):

- `codex` (default) — runs `codex app-server` directly via `SymphonyElixir.Codex.AppServer` (§10.7).
- `claude` — launches the Python sidecar in `elixir/priv/claude_agent/` via `SymphonyElixir.Claude.AppServer` (§10.8); the sidecar hosts `claude-agent-sdk` and is configured for unattended sandboxed operation by default (`permission_mode: dontAsk` + tight `allowed_tools` whitelist + workspace-cwd boundary).

Two layers live here:

- **Top-level**: `SPEC.md` is the source-of-truth specification; the root `Makefile` launches the daemon against `elixir/WORKFLOW.md`.
- **`elixir/`**: the reference Elixir/OTP implementation. The implementation may be a *superset* of `SPEC.md` but must not conflict with it — when behavior diverges meaningfully, update `SPEC.md` in the same change.

There is no second implementation. All code work happens in `elixir/`.

**Fork status:** this is the Identione fork of [openai/symphony](https://github.com/openai/symphony). `origin` is `Identione/symphony`; upstream is referenced for sync only and is not configured as a git remote here. All work — branches, PRs, issues, releases — lives on `origin`.

## Working in `elixir/`

Toolchain is pinned via `mise` (`elixir/mise.toml`: Erlang 28 / Elixir 1.19). **Always prefix mix commands with `mise exec --`** when running from a fresh shell — the rest of this file omits the prefix for brevity but you should include it.

```bash
cd elixir
mise install              # one-time, installs Erlang/Elixir
mix setup                 # fetch deps
make all                  # full quality gate (run before handoff)
```

`make all` runs: `setup → build → fmt-check → lint → coverage → dialyzer`. **Coverage threshold is 100%** (with an explicit ignore list in `mix.exs` — see `test_coverage`). New modules default to being covered; add to the ignore list only with justification.

Targeted iteration:

```bash
mix test test/symphony_elixir/orchestrator_status_test.exs        # single file
mix test test/symphony_elixir/cli_test.exs:42                     # single test by line
mix format && mix lint                                            # lint = specs.check + credo --strict
mix specs.check                                                   # @spec enforcement only
```

`mix lint` runs `specs.check` then `credo --strict`. **Every public `def` in `lib/` must have an adjacent `@spec`** — `defp` and `@impl` callbacks are exempt. `mix specs.check` is what enforces this.

End-to-end tests are gated and create real Linear resources / launch a real Codex session — do not run accidentally:

```bash
export LINEAR_API_KEY=...
make e2e        # sets SYMPHONY_RUN_LIVE_E2E=1
```

## Running the daemon (root Makefile)

The root `Makefile` is a thin launcher around `elixir/bin/symphony` that manages a PID file in `run/` and reads `elixir/WORKFLOW.md`:

```bash
make build              # builds elixir/bin/symphony (escript)
make foreground         # attached, for first launch / debugging
make start | stop | restart | status | logs
```

The launcher passes the `--i-understand-that-this-will-be-running-without-the-usual-guardrails` flag because Symphony runs Codex with `approval_policy: never` and `workspace-write` sandbox. Don't strip that flag in scripts.

`LINEAR_API_KEY` is expected to come from `elixir/mise.local.toml` (gitignored) — `make` checks for it via `mise exec`.

> **Note for in-workspace daemon launches:** the host running this repo already has Symphony bound to the default dashboard port (`server.port: 3453` in `elixir/WORKFLOW.md`, also the `DASHBOARD_URL` in the root `Makefile`). When you launch a second instance from inside an issue workspace (`make foreground` / `make start`), set a different TCP port — pass `--port <free-port>` to `bin/symphony` or override `server.port` in your local `WORKFLOW.md` — otherwise Bandit will fail to bind because 3453 is already in use. (`mix test` / `make all` are unaffected: `config/config.exs` pins `:server_port_override` to `0` in `:test` so the test boot picks an OS-assigned ephemeral port.)

## Architecture (big picture)

OTP supervision tree (see `lib/symphony_elixir.ex`):

```
SymphonyElixir.Application (one_for_one)
├── Phoenix.PubSub (SymphonyElixir.PubSub)
├── Task.Supervisor (SymphonyElixir.TaskSupervisor)
├── WorkflowStore       — owns the parsed WORKFLOW.md, hot-reloadable
├── Orchestrator        — polling loop; stateful claim/run/retry table
├── HttpServer          — Bandit + Phoenix endpoint (optional, gated on server.port)
└── StatusDashboard     — terminal status renderer
```

Request/work flow:

1. `Orchestrator` polls the `Tracker` (Linear or in-memory test adapter).
2. For each unclaimed candidate issue, it creates a `Workspace` under `workspace.root` and runs `hooks.after_create`.
3. `AgentRunner` launches `Codex.AppServer` against that workspace and feeds it the workflow prompt rendered via `PromptBuilder` (Solid/Liquid templates).
4. `Codex.DynamicTool` exposes a client-side `linear_graphql` tool to the Codex session for raw Linear ops.
5. When the issue moves to a terminal state, the orchestrator stops the agent and `before_remove` hook runs.
6. `max_turns` caps continuation turns when the issue is still active after a turn ends normally.

Where to look for what:

- **Workflow / config**: `lib/symphony_elixir/workflow.ex`, `workflow_store.ex`, `config.ex`, `config/schema.ex`. Always read config via `SymphonyElixir.Config` rather than `System.get_env`.
- **Orchestrator state machine**: `lib/symphony_elixir/orchestrator.ex` — concurrency-sensitive; preserve retry/reconciliation/cleanup semantics when changing it.
- **Linear integration**: `lib/symphony_elixir/linear/` (adapter/client/issue) and `lib/symphony_elixir/tracker.ex` (behaviour). Tests use `tracker/memory.ex`.
- **Codex session**: `lib/symphony_elixir/codex/app_server.ex` (lifecycle) and `dynamic_tool.ex` (the injected `linear_graphql` tool).
- **Workspace safety**: `lib/symphony_elixir/workspace.ex` and `path_safety.ex`. **The Codex turn cwd must never be the source repo** and workspaces must stay under the configured `workspace.root` — these invariants are enforced here, don't relax them.
- **Web/dashboard**: `lib/symphony_elixir_web/` (Phoenix LiveView at `/`, JSON at `/api/v1/*`). Default off; enabled by `server.port` in WORKFLOW.md or `--port` CLI flag.

## WORKFLOW.md is the runtime contract

WORKFLOW.md is YAML front matter + a Markdown body used as the Codex prompt template (Liquid syntax via `solid`). Key invariants:

- Missing front matter or invalid YAML at startup → Symphony refuses to boot.
- Reload failure at runtime → Symphony keeps running with last-known-good and logs the error.
- Defaults are intentionally safe: omit `approval_policy` and you get reject-everything; omit `thread_sandbox` and you get `workspace-write`.
- `tracker.api_key` reads `LINEAR_API_KEY` when unset or set to `$LINEAR_API_KEY`.
- Path values support `~` and `$VAR` expansion (except `codex.command`, which is a shell string and expands at exec time).

`elixir/WORKFLOW.md` is the single workflow file: `make start` runs against it, tests use it as a fixture, and it doubles as the canonical example to copy when adopting Symphony in another repo.

## Logging conventions

Per `elixir/docs/logging.md`, issue-scoped logs **must** include both `issue_id` (Linear UUID) and `issue_identifier` (e.g. `MT-620`). Codex-lifecycle logs must include `session_id`. Use `key=value` pairs in messages, deterministic wording for recurring events, and never log large payloads. New log sites should follow this or dashboards/alerts break.

## PR requirements

PRs target `origin` (`Identione/symphony`) — **never** the upstream `openai/symphony`. `gh pr create` without `--repo` is correct here; if you ever see `gh` prompting to push to `openai/symphony`, stop and re-check the remote.

PR body must conform to `.github/pull_request_template.md` exactly. GitHub Actions is disabled on this fork (the upstream `make-all.yml` and `pr-description-lint.yml` workflow files were dropped), so the only quality signal is local. Run before pushing:

```bash
cd elixir && make all && mix pr_body.check --file /path/to/pr_body.md
```

When behavior or config changes, update docs in the same PR: root `README.md` (concept), `elixir/README.md` (run instructions), root `SPEC.md` (when implementation drifts), and `WORKFLOW.md` (workflow contract).

## Conventions worth knowing

- Keep changes narrowly scoped; avoid unrelated refactors in a feature/bugfix PR.
- Prefer adding config knobs through `SymphonyElixir.Config` over ad-hoc `System.get_env` reads.
- `.codex/skills/` contains repo-local Codex skills (`commit`, `push`, `pull`, `land`, `linear`, `debug`) — these are referenced by WORKFLOW.md prompts, not Elixir code.
- `run/symphony.pid` and `run/symphony.out` are daemon state; `elixir/log/` is structured per-issue logs. `make clean` only touches `run/`.
- Codex 0.115+ enforces a hard-coded `.git` deny rule under `workspace-write` regardless of `writableRoots`, breaking unattended commits — see [openai/codex#15505](https://github.com/openai/codex/issues/15505). The shipped `elixir/WORKFLOW.md` works around this via Approach B (a `~/.codex/config.toml` `default_permissions` profile that grants `:project_roots ".git" = "write"`); the `jai codex --config sandbox_mode=danger-full-access` form (Approach A) is preserved as a commented alternative. See [SETUP.md](SETUP.md) for both. Don't "downgrade" to a `npx -p @openai/codex@0.114.0` pin without first checking whether the host has either approach configured.
