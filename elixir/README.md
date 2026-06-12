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
session, agents get a client-side `linear_graphql` tool for raw Linear API
access.

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
  `linear_graphql` app-server tool.

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
- `--output <PATH>` — workflow output path
- `--port <PORT>` — enable the Phoenix dashboard. `0` = OS-assigned. Omit
  for no `server:` block at all.
- `--host <ADDR>` — IPv4 or IPv6 literal (e.g. `0.0.0.0`, `::1`). Defaults
  to `127.0.0.1`. Requires `--port`.
- `--instance-makefile <PATH>` / `--instance-name <NAME>` — render the
  per-instance Makefile alongside the workflow. The root `make init`
  target uses these under the hood.
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
  both empty to disable label gating.
- `~` and `$VAR` are expanded in path values (except `codex.command`,
  which is a shell command string — `$VAR` expands at exec time there).
- If `WORKFLOW.md` is missing or invalid at boot, Symphony refuses to
  start. If a later reload fails, Symphony keeps running with the last
  known good workflow.
- `agent.max_turns` caps continuation turns per agent invocation when the
  issue stays in an active state after a turn ends normally. Default: `20`.
- `agent.codex.quota` / `agent.claude.quota` (both OPTIONAL, disabled by
  default) add account-quota-aware dispatch pausing: when `enabled`, Symphony
  stops dispatching *new* issues while the active provider's usage is at/above
  `dispatch_pause_percent` (default `95.0`); running agents are unaffected.
  Codex usage comes free from the app-server rate-limit stream; Claude polls
  the OAuth usage endpoint every `refresh_ms`. Quota is always tracked and
  shown on the dashboard — only the pause action is gated. See SPEC.md §5.3.5.3.
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

Detailed codex/claude policy knobs (`approval_policy`, `thread_sandbox`,
`turn_sandbox_policy`, `claude.config_dir`, `permission_mode`, the
Codex 0.115+ `.git` deny-rule workaround with `jai`/`default_permissions`
profiles) live in [SETUP.md](../SETUP.md).

## Web dashboard

Phoenix LiveView at `/`, JSON API at `/api/v1/state`,
`/api/v1/<issue_identifier>`, `/api/v1/refresh`. Off by default; enabled
by `server.port` in WORKFLOW.md or the `--port` CLI flag at start time.
Bandit fronts the stack.

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
