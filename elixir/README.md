# Symphony Elixir

The Elixir/OTP reference implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Prototype software intended for evaluation only and presented as-is.
> Implementing your own hardened version based on `SPEC.md` is recommended.

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

Symphony polls Linear for candidate work, creates a workspace per issue, and
launches a coding agent (Codex by default, Claude SDK optional) against it.
The agent keeps running until the issue reaches a terminal state. During the
session, agents get two client-side dynamic tools: `linear_graphql` for raw
Linear API access and `sync_workpad` for pushing the persistent workpad
comment (it reads the body from a local file so the multi-KB markdown never
enters the conversation context).

When the agent reports that it needs operator input — a `turn/*` input
request, an approval prompt, or an MCP elicitation — Symphony stops retrying
that issue, keeps it *claimed*, and marks it **blocked**, surfacing it in the
runtime state, JSON API (`status: "blocked"`), and dashboard. Blocked entries
are in memory only: restarting the orchestrator clears them, so a still-active
issue can become a dispatch candidate again. This input-blocked surfacing
applies to the **Codex adapter only** — the Claude SDK sidecar runs unattended
(`permission_mode: dontAsk`) and resolves permission decisions itself rather
than reporting an input-required blocker.

## Quick start

```bash
# from the repo root
mise trust elixir && mise install
make build
make init INSTANCE=my-repo ARGS="\
  --linear-project https://linear.app/<org>/project/<slug> \
  --repo-url git@github.com:<org>/<repo>.git \
  --agent codex \
  --port 3454"           # add --host 0.0.0.0 for a LAN-visible dashboard
cd instances/my-repo
make preflight           # validates Linear auth, repo access, ports, etc.
make start               # detached. `make foreground` to run attached.
make logs                # tail structured log/symphony.log
make stop                # graceful shutdown (SIGKILL after 10s)
```

Set `LINEAR_API_KEY` in `elixir/mise.local.toml` (gitignored) or your shell
before running `make preflight` / `make start`. Get a token via
Linear → Settings → Security & access → Personal API keys.

Each `make init INSTANCE=<name>` creates an isolated `instances/<name>/` with
its own `WORKFLOW.md`, `Makefile`, `run/symphony.pid`, and
`log/symphony.log`. Run multiple instances in parallel from the same
checkout. Re-running `make init` against an existing instance refuses to
overwrite unless `ARGS` contains `--force` — with `--force`, both the
workflow and the instance Makefile are regenerated together.

### Operator notes

- **One Linear project per instance.** Two instances polling the same
  `tracker.project_slug` will race to claim the same issues.
- **Workspaces nest under `workspace.root/<issue-id>`** (e.g. `IDE-1`).
  Two instances of the same repo are fine unless they might process the
  same issue identifier — then set distinct `--workspace-root` per instance.
- **Optional repo skills** (`commit`, `push`, `pull`, `land`, `linear`)
  can be copied into your repo; the `linear` skill uses Symphony's
  `linear_graphql` and `sync_workpad` app-server tools.

## Toolchain

`mise` (`mise.toml`) pins the whole toolchain, and `mise install` resolves it
from the committed lockfile `mise.lock` (per-platform checksums, so a swapped
upstream artifact fails verification instead of installing silently):

- **Erlang 28 / Elixir 1.19** — line-pinned plumbing.
- **`codex`** — the default adapter binary, tracked as `latest` (it moves fast
  and has no stable release line); reproducibility comes from `mise.lock`.
- **`uv`** — runs the Claude SDK sidecar (`priv/claude_agent`); line-pinned.

The Claude adapter's fast-moving piece is the Python `claude-agent-sdk`
package, declared `>=` in `priv/claude_agent/pyproject.toml` and pinned in
`priv/claude_agent/uv.lock` — uv's domain, not mise's.

### Upgrading the agent toolchain

```bash
make upgrade-tools     # bump codex (mise.lock) + claude-agent-sdk (uv.lock)
make all               # verify, then commit mise.lock + priv/claude_agent/uv.lock
```

`make upgrade-tools` only moves the *eager-tracked* tools (codex,
`claude-agent-sdk`). Line-pinned tools (erlang/elixir/uv) move by editing the
pin in `mise.toml` and re-running `mise install`.

> Not to be confused with the root **`make upgrade` / `upgrade-all`**, which
> redeploys Symphony *code* (rebuild escript + restart instance daemons after a
> `git pull`) and never touches the toolchain.

## CLI reference

The Makefile-driven flow above is the supported path; what follows is the
raw CLI surface the Makefile rules call.

```bash
./bin/symphony init [...]          # generate a WORKFLOW.md (+ optional instance Makefile)
./bin/symphony preflight [path]    # validate WORKFLOW.md against the live environment
./bin/symphony start [...] [path]  # boot the orchestrator (path defaults to ./WORKFLOW.md)
./bin/symphony [...] [path]        # alias of `start`
```

### `init` flags

- `--linear-project <URL_OR_SLUG>` (required)
- `--repo-url <CLONE_URL>` (required)
- `--workspace-root <PATH>` — defaults to `~/code/symphony-workspaces/<repo>`
- `--repo-path <LOCAL_PATH>` — optional pointer to a local clone
- `--agent codex|claude` — defaults to `codex`
- `--base-branch <NAME>` — target a development branch instead of `main`.
  Omit (the default) and the workflow targets the repo's own default branch,
  byte-identical to before. Set it and agents branch from / sync with /
  merge into `<NAME>` (work isolated onto `symphony/<issue-id>` branches off
  `origin/<NAME>`, PRs target `<NAME>`), leaving `main` untouched.
  **Symphony emits no git operations itself**, so the base-aware behavior must
  be provisioned in the target repo's `.codex/skills/`: the `push`, `pull`, and
  `land` skills (incl. `land_watch.py`) must read `git config symphony.baseBranch`
  (recorded by the `after_create` hook, with a `main` fallback) to set the PR
  `--base`, merge the right branch, and refuse pushing the protected/base branch.
  Symphony never vendors them by default — without them PRs target the wrong base and
  the protected-branch guard is missing (set `workspace.skills_source` in WORKFLOW.md to
  have Symphony copy a skills directory into every workspace instead, see SPEC.md §5.3.3;
  the copy is additive and repo-wins — skills the target repo tracks itself are kept).
  Re-run with `--force` to change the base later.
- `--output <PATH>` — workflow output path
- `--port <PORT>` — enable the Phoenix dashboard. `0` = OS-assigned. Omit
  for no `server:` block at all.
- `--host <ADDR>` — IPv4 or IPv6 literal (e.g. `0.0.0.0`, `::1`). Defaults
  to `127.0.0.1`. Requires `--port`.
- `--instance-makefile <PATH>` / `--instance-name <NAME>` — render the
  per-instance Makefile alongside the workflow. The root `make init`
  target uses these under the hood.
- `--require-label <NAME>` / `--exclude-label <NAME>` — repeatable; set
  `tracker.required_labels` / `tracker.excluded_labels`. Matching is
  case-insensitive. Omit both for no label gating (the default). The same
  label in both lists is rejected — it gates every issue out, so the daemon
  would poll forever and dispatch nothing. Whichever list you leave empty is
  written as a commented example, so the other half stays discoverable.
- `--force` — overwrite existing output(s). Gates both files together.

## WORKFLOW.md

YAML front matter + a Markdown body used as the agent session prompt.
Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

### `repo.url` vs `repo.path`

`init` writes a top-level `repo:` block:

```yaml
repo:
  url: git@github.com:<org>/<repo>.git
  path: ~/code/<repo>   # optional
```

- `repo.url` is the clone URL Symphony hands to `hooks.after_create` and
  uses for an unauthenticated `git ls-remote` reachability check in
  `preflight`. The only repo input the minimal flow needs.
- `repo.path` is an optional pointer to a local clone. Symphony itself
  never touches it; it exists for skills that inspect project-local files
  outside the per-issue workspace.

### Behavior notes

- `tracker.api_key` reads `LINEAR_API_KEY` when unset or set to `$LINEAR_API_KEY`.
- `tracker.required_labels` / `tracker.excluded_labels` (default `[]`) gate
  dispatch by Linear label, case-insensitively. An issue is picked up only
  if it carries *every* `required_labels` entry and *none* of the
  `excluded_labels` entries; an excluded label always disqualifies. Leave
  both empty to disable label gating. `symphony init --require-label <name>`
  / `--exclude-label <name>` set these (repeatable; see `init` flags above).
- `~` and `$VAR` are expanded in path values (except `codex.command`,
  which is a shell command string — `$VAR` expands at exec time there).
- If `WORKFLOW.md` is missing or invalid at boot, Symphony refuses to
  start. If a later reload fails, Symphony keeps running with the last
  known good workflow.
- `agent.max_turns` caps continuation turns per agent invocation when the
  issue stays in an active state after a turn ends normally. Default: `20`.
- `agent.budget_pressure_turns` (default `2`) injects budget-pressure steering
  into the continuation prompt when the run is within this many turns of
  `agent.max_turns`: the next turn's guidance tells the agent to commit its
  working state now (via the `commit` skill) before the cap stops the run. Must
  leave ≥1 actionable turn; `0` disables.
- `agent.preserve_uncommitted_work` (default `true`) is a non-destructive
  cutoff: before any session stop (including a Backlog/non-active stop that
  keeps the workspace) or the `max_turns` cutoff, Symphony snapshots a dirty
  working tree — modified, staged, **and untracked** files — to a
  `refs/symphony/wip/<id>` commit without touching HEAD, the branch, or the
  working tree. Recover stranded work with `git log refs/symphony/wip/<ID>` (or
  `git branch --list 'symphony/wip/*'` when `agent.preserve_uncommitted_work_branch`
  is enabled). The git-shell timeout is `agent.cutoff_timeout_ms` (default `60000`).
- `agent.progress_signal_enabled` (default `true`) computes deterministic
  per-turn progress signals (IDE-211 / Layer 1): at each turn boundary a cheap
  non-mutating git probe classifies the issue as
  progressing/stuck/oscillating/repeated_error plus an independent
  `at_risk_no_commits` flag, surfaced on the dashboard and logged. This layer
  only *reports* — it never kills a session or moves state.
  `agent.progress_signal_window_k` (default `4`, `>= 2`) is the consecutive-turn
  window; `agent.progress_signal_git_timeout_ms` (default `2000`) bounds the
  probe; `agent.progress_trigger_min_turns` (default `4`) is the turn floor for
  the overseer trigger. See `docs/progress_signals.md`.
- `agent.overseer` (**on by default**, dormant without a resolved key) is the
  Layer-2 AI overseer (IDE-212 / IDE-230): the binding controller of the
  per-session turn budget. A session extends turn-by-turn up to
  `absolute_max_turns` (default `500`) under overseer approval; `agent.max_turns`
  survives only as the keyless-fallback ceiling. At each turn boundary the worker
  runs the free Layer-1 deterministic check and consults the overseer when the
  consecutive no-progress streak hits `streak_to_llm` (default `5`) or every
  `mandatory_llm_every` turns (default `40`). A **read-only** Anthropic call
  classifies the run vs. its plan and either approves (`continue` / `nudge` /
  `recommend_extend_budget`) or gives up (`escalate` / `abort`) — posting
  structured findings, running one bounded graceful wind-down turn (commit +
  workpad update), suppressing the retry (`:overseer_escalation` is
  immediate-escalation + `:no_retry`), and moving the issue to Human Review. A
  verdict below `confidence_floor` (default `0.6`) downgrades to an approval.
  Without a resolved `agent.overseer.api_key` (defaults to `$ANTHROPIC_API_KEY`),
  or when the call cap (`max_calls_per_session`, default `25`) is exhausted, the
  run caps at `agent.max_turns` and posts a "could not judge" comment (never
  silent). Every error path fails open. See SPEC.md §13.6.
- `agent.codex.quota` / `agent.claude.quota` (both OPTIONAL, disabled by
  default) add account-quota-aware dispatch pausing: when `enabled`, Symphony
  stops dispatching *new* issues while the active provider's usage is at/above
  `dispatch_pause_percent` (default `95.0`); running agents are unaffected.
  Codex usage comes free from the app-server rate-limit stream; Claude polls
  the OAuth usage endpoint every `refresh_ms`. Quota is always tracked and
  shown on the dashboard — only the pause action is gated. See SPEC.md §5.3.5.3.
  For Claude, `agent.claude.quota.token_source: claude_cli_refresh` keeps an
  idle daemon's OAuth token alive by running a zero-inference `claude` startup
  (which refreshes the token in place) when it nears expiry — handy if you
  don't use a long-lived `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`.
- If the Markdown body is blank, Symphony uses a default prompt template
  that includes the issue identifier, title, and body.
- To wrap the agent in [jai](https://jai.scs.stanford.edu/) as an outer
  sandbox, swap the commented `#command: jai …` line with the active
  `command:` line inside `agent.codex` / `agent.claude` in
  `instances/<name>/WORKFLOW.md`. The jai-wrapped form requires Linux with
  kernel ≥ 6.13.

Reasoning effort: Codex is tuned via `--config model_reasoning_effort=…` in its
`command:`; the Claude adapter takes `agent.claude.effort`
(`low|medium|high|xhigh|max`). Both default to the agent's own default
(`high` for the Claude SDK) when unset; `xhigh` requires Opus 4.7.

Project settings (Claude adapter): `agent.claude.setting_sources` is unset by
default, so a Claude agent loads the target repo's Claude Code settings just
like an interactive `claude` run — its `.claude/settings.json` (including
`enableAllProjectMcpServers`), project `.mcp.json` MCP servers (e.g. an `lsp`
code-intelligence server), and `CLAUDE.md`. The outer `jai` sandbox contains
the inherited surface (repo hooks / permission rules); deployments without it
should set `agent.claude.setting_sources: []` for deterministic isolation. To
make a project MCP server's tools callable under `dontAsk`, add `mcp__<server>`
(e.g. `mcp__lsp`) to `agent.claude.allowed_tools`, or let the repo's loaded
`permissions.allow` cover them.

Detailed codex/claude policy knobs (`approval_policy`, `thread_sandbox`,
`turn_sandbox_policy`, `claude.config_dir`, `permission_mode`, the
Codex 0.115+ `.git` deny-rule workaround with `jai`/`default_permissions`
profiles) live in [SETUP.md](../SETUP.md).

## Web dashboard

Phoenix LiveView at `/`, JSON API at `/api/v1/state`,
`/api/v1/<issue_identifier>`, `/api/v1/refresh`. Off by default; enabled
by `server.port` in WORKFLOW.md or the `--port` CLI flag at start time.
Bandit fronts the stack.

Tracker issue identifiers in dashboard rows link to the tracker-provided URL
when it uses `http` or `https`.

## Project layout

- `lib/` — application code and Mix tasks
- `test/` — ExUnit coverage for runtime behavior
- `priv/templates/` — EEx templates that `symphony init` renders
- `WORKFLOW.md` — maintainer's example workflow + test fixture
  (Makefiles do not launch it — use `make init` to generate your own)
- `../.codex/` — repository-local Codex skills and setup helpers

## Testing

```bash
make all        # quality gate: build + fmt-check + lint + coverage + dialyzer
make e2e        # live end-to-end against real Linear + real codex
```

`make e2e` requires `LINEAR_API_KEY` and runs two scenarios (local worker,
SSH workers). With `SYMPHONY_LIVE_SSH_WORKER_HOSTS` unset, the SSH
scenario uses `docker compose` to spin up disposable workers on
localhost. The test creates a temporary Linear project and issue, drives
a real agent turn, verifies the workspace side effect, requires the
agent to comment on and close the Linear issue, then marks the project
completed in Linear.

## FAQ

### Why Elixir?

Erlang/BEAM/OTP is built for supervising long-running processes, with hot
code reloading that doesn't stop running subagents.

### How do I set this up for my own codebase?

Launch `codex` in your repo, give it the URL to this Symphony repo, and
ask it to set things up for you.

## License

[Apache License 2.0](../LICENSE).
