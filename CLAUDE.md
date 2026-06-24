# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Symphony is a Linear-driven coding-agent orchestrator: it polls Linear for work, creates a per-issue workspace, and runs a coding-agent session against it. The active adapter is selected per workflow via `agent.kind` (SPEC.md §10):

- `codex` (default) — runs `codex app-server` directly via `SymphonyElixir.Codex.AppServer` (§10.7).
- `claude` — launches the Python sidecar in `elixir/priv/claude_agent/` via `SymphonyElixir.Claude.AppServer` (§10.8); the sidecar hosts `claude-agent-sdk` and is configured for unattended sandboxed operation by default (`permission_mode: dontAsk` + tight `allowed_tools` whitelist + workspace-cwd boundary).

Two layers live here:

- **Top-level**: `SPEC.md` is the source-of-truth specification; the root `Makefile` builds the escript and generates per-operator instance folders under `instances/<name>/`. Daemon launches happen from each generated instance Makefile, never from the root.
- **`elixir/`**: the reference Elixir/OTP implementation. The implementation may be a *superset* of `SPEC.md` but must not conflict with it — when behavior diverges meaningfully, update `SPEC.md` in the same change.

There is no second implementation. All code work happens in `elixir/`.

**Fork status:** this is the Identione fork of [openai/symphony](https://github.com/openai/symphony). `origin` is `Identione/symphony`; upstream is referenced for sync only and is not configured as a git remote here. All work — branches, PRs, issues, releases — lives on `origin`.

## Working in `elixir/`

Toolchain is pinned via `mise` (`elixir/mise.toml`): Erlang 28 / Elixir 1.19 (line-pinned), plus the agent runtimes on `PATH` — `codex` (the default adapter binary, tracked as `latest`) and `uv` (runs the Claude SDK sidecar, line-pinned `0.11`). Exact resolved versions + per-platform checksums are committed in `elixir/mise.lock` (`lockfile = true`), so `mise install` is reproducible. **Always prefix mix commands with `mise exec --`** when running from a fresh shell — the rest of this file omits the prefix for brevity but you should include it.

```bash
cd elixir
mise install              # one-time, installs the full toolchain from mise.lock
mix setup                 # fetch deps
make all                  # full quality gate (run before handoff)
```

Two kinds of "upgrade" — don't conflate them:

- **`make upgrade-tools`** (in `elixir/Makefile`) bumps the *eager-tracked agent toolchain* — `codex` (refreshes `mise.lock`) and `claude-agent-sdk` (refreshes `priv/claude_agent/uv.lock`). Line-pinned tools (erlang/elixir/uv) move only by editing the pin in `mise.toml`. Run `make all` and commit both lockfiles after.
- **`make upgrade` / `upgrade-all`** (root Makefile) redeploys *Symphony code* — rebuild the escript + restart instance daemons after a `git pull`. Nothing to do with the toolchain.

`make all` runs: `setup → build → fmt-check → lint → coverage → dialyzer`. **Coverage is reported but does not gate the build** (the `test_coverage` threshold in `mix.exs` is `0`, with an explicit ignore list — see `test_coverage`). Aim to keep new code covered, but low coverage no longer fails `make all`.

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

## Running the daemon (per-instance Makefiles)

The root `Makefile` does **not** launch the daemon. It only builds the escript and generates per-instance folders. All daemon control (`start`, `foreground`, `stop`, `restart`, `status`, `logs`, `preflight`) lives in each generated `instances/<name>/Makefile`:

```bash
make build                                                              # root: builds elixir/bin/symphony
make init INSTANCE=<name> ARGS="--linear-project <URL> --repo-url <URL> [--base-branch <name>] [--port N] [--host ADDR]"
cd instances/<name>
make preflight                                                          # validate against the live env
make start | stop | restart | status | logs | foreground                # instance daemon control
```

`make init` renders `instances/<name>/WORKFLOW.md` plus a self-contained `instances/<name>/Makefile` from the EEx templates at `elixir/priv/templates/`. Re-running `make init INSTANCE=<name>` against an existing instance refuses to overwrite unless `--force` is in `ARGS`; with `--force`, both files are regenerated together (one toggle, two files).

`make init-all` is the bulk form: it reads a gitignored `instances.local` manifest (template: `instances.local.example`) with one `<name> <init-args>` per line and runs `make init` for each — skipping instances that already exist, or `FORCE=1` to regenerate all.

The instance Makefile's `start`/`foreground` pass the `--i-understand-that-this-will-be-running-without-the-usual-guardrails` flag because Symphony runs Codex with `approval_policy: never` and `workspace-write` sandbox. Don't strip that flag.

`LINEAR_API_KEY` is expected to come from `elixir/mise.local.toml` (gitignored) — the instance `check-key` target queries the mise env. Each instance's `tracker.project_slug` should be unique; two instances polling the same project will race for the same issues.

> **`--port` and `--host` semantics on `make init`:** omitting `--port` produces a workflow with no `server:` block at all (dashboard off). `--port <N>` enables the dashboard at port N; `--port 0` means OS-assigned. `--host <ADDR>` (only meaningful with `--port`) sets the bind address. Strict IP-literal validation: only `:inet.parse_strict_address/1`-parseable IPv4/IPv6 addresses are accepted (e.g. `0.0.0.0`, `127.0.0.1`, `::1`, `192.168.1.10`). DNS names like `dashboard.local` are rejected — operators with that genuine need can hand-edit `WORKFLOW.md` post-generation; the runtime path (`HttpServer.parse_host/1`) still resolves them.

> **`--base-branch <name>` on `make init`:** omitting it is the default — the generated workflow targets the repo's own default branch and behaves exactly as before (no `repo.base_branch`, body says `origin/main`). Setting it (validated as a safe git branch name) makes agents branch from, sync with, and merge into `<name>` instead of `main`, leaving `main` untouched: the prompt body gains a "Work on a dedicated issue branch" section that isolates work onto a per-issue branch `symphony/<issue-id>` off `origin/<name>` and targets `<name>` for the PR, the `after_create` hook fetches `<name>` and records `git config symphony.baseBranch <name>`, and the repo-local `push`/`pull`/`land` skills read that config (with a `main` fallback) to set the PR `--base`, merge the right branch, and refuse pushing a protected/base/default branch. The base is baked into the body at generation time — to change it later, re-run `make init --force` (editing only the front-matter `repo.base_branch` won't update the baked instructions). The base-aware behavior lives in the **cloned target repo's** `.codex/skills/`, which Symphony never vendors — provision/refresh those skills in the target repo (init's output reminds you). Pair a base-branch instance with its own Linear `project_slug` so only the intended issues feed it.

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

`elixir/WORKFLOW.md` is the maintainer's hand-tuned workflow file: it's used as a test fixture and as the canonical example of a complete daemon configuration. It is *not* launched by the root or `elixir/` Makefiles; copy it into an instance (or use `make init` to generate a simpler one) when actually running Symphony.

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
- The agent **front-matter adapter comments are hand-maintained in two copies** — `elixir/WORKFLOW.md` (the canonical config) and `elixir/lib/symphony_elixir/cli/init.ex` (`agent_block/1`, which generates the `claude`/`codex` blocks for `make init` instances). No test enforces front-matter parity (the byte-identical fixture in `cli_init_test.exs` covers only the prompt *body*), so when you edit one copy's adapter comments, **edit the other to match**. Generated instances are intentionally a simpler subset — keep the *style/wording* consistent, not every knob.
- Per-instance state lives under `instances/<name>/run/` (PID + raw stdout `symphony.out`) and `instances/<name>/log/symphony.log` (structured rotating disk log via `LogFile.configure/0`, 10 MB × 5 files). Both directories are gitignored. The instance `make clean` removes only `run/`; `log/` is preserved for history. `make logs` from the instance tails the structured log.
- Codex 0.115+ enforces a hard-coded `.git` deny rule under `workspace-write` regardless of `writableRoots`, breaking unattended commits — see [openai/codex#15505](https://github.com/openai/codex/issues/15505). The shipped `elixir/WORKFLOW.md` works around this via Approach B (a `~/.codex/config.toml` `default_permissions` profile that grants `:project_roots ".git" = "write"`); the `jai codex --config sandbox_mode=danger-full-access` form (Approach A) is preserved as a commented alternative. See [SETUP.md](SETUP.md) for both. Don't "downgrade" to a `npx -p @openai/codex@0.114.0` pin without first checking whether the host has either approach configured.
