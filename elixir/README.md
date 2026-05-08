# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches the configured **coding-agent adapter** (SPEC.md §10) inside the workspace:
   - `agent.kind: codex` (default) — runs Codex in
     [App Server mode](https://developers.openai.com/codex/app-server/) (`agent.codex.command`).
   - `agent.kind: claude` — launches the Claude Agent SDK sidecar in `priv/claude_agent/`
     (`agent.claude.command`, default `jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR
     python -m symphony_claude_agent` — the env var is injected by `Claude.AppServer`). The sidecar hosts `claude-agent-sdk` and runs under
     [`jai`](https://jai.scs.stanford.edu/) as the outer sandbox, with `permission_mode:
     bypassPermissions` so the SDK steps out of the way (Codex Approach A parity — see
     [SETUP.md](../SETUP.md)). For hosts without jai, switch to `dontAsk` plus an explicit
     `allowed_tools` whitelist; the shipped `WORKFLOW.md` carries the safe defaults in a
     commented "Alternative" block.
4. Sends the workflow prompt to the active adapter
5. Keeps the agent working on the issue until the work is done (capped by `agent.max_turns`)

During agent sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls. The contract is adapter-agnostic — Codex receives it
through the app-server tool advertisement; the Claude sidecar exposes it through the SDK's
`create_sdk_mcp_server` + `@tool` mechanism, and the actual GraphQL call still runs on the
Symphony side via a `tool_call`/`tool_result` round-trip so Linear auth never leaves Symphony.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

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

Notes:

- If a value is missing, defaults are used.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony forwards the configured map to
  Codex, but for `workspaceWrite` policies it ensures the current issue workspace stays in
  `writableRoots` at runtime. This allows adding extra writable paths without granting access to
  sibling workspaces by default. Compatibility for the remaining fields still depends on the
  targeted Codex app-server version rather than local Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox. (This bullet only applies when Symphony supplies the policy. With
  `codex.use_configured_permissions: true`, `turn_sandbox_policy` is ignored entirely and network
  access is governed by whatever wraps `codex.command` — see [SETUP.md](../SETUP.md).)
- Codex's own `workspace-write` sandbox cannot do unattended `git commit` / `git push` on its
  own (notably the 0.115+ `.git` deny rule, https://github.com/openai/codex/issues/15505). Two
  verified approaches cover both adapters — see [Sandboxing approaches](#sandboxing-approaches)
  below for full snippets, and [SETUP.md](../SETUP.md) for the rationale. The shipped
  `WORKFLOW.md` uses Approach A (jai as outer sandbox) for both Codex and Claude.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Sandboxing approaches

Symphony runs each turn unattended (`approval_policy: never` for Codex, `permission_mode:
bypassPermissions` for Claude under jai), so the host needs *some* sandbox — Codex's own
permissions, jai, or both. Two approaches are verified end-to-end; pick one and configure both
the workflow file and `~/.codex/config.toml` to match. The shipped `WORKFLOW.md` uses
Approach A. Full discussion is in [SETUP.md](../SETUP.md).

### Approach A — jai as the outer sandbox *(default)*

[`jai`](https://jai.scs.stanford.edu/) wraps the agent process with a copy-on-write `$HOME`
overlay and a writable cwd, so the adapter's own sandbox can step out of the way. Requires
Linux 6.13+; install per <https://jai.scs.stanford.edu/install.html> and run `jai --init` once.

`WORKFLOW.md` — Codex:

```yaml
codex:
  command: jai codex --config sandbox_mode=danger-full-access app-server
  approval_policy: never
  use_configured_permissions: true
  thread_sandbox: workspace-write   # ignored when use_configured_permissions: true
  turn_sandbox_policy: null         # ignored when use_configured_permissions: true
```

`WORKFLOW.md` — Claude:

```yaml
claude:
  command: jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
  config_dir: ~/.claude-identione
  model: claude-sonnet-4-6
  permission_mode: bypassPermissions
  extra_env:
    PYTHONDONTWRITEBYTECODE: "1"
  setting_sources: []
```

`~/.codex/config.toml` (Codex adapter only — alternative to passing the same `--config` flags
on the command line):

```toml
model = "gpt-5.5"
model_reasoning_effort = "xhigh"

[shell_environment_policy]
inherit = "all"
```

Other host setup:

- Run `make sidecar-deps` once *outside* jai to populate `priv/claude_agent/.venv` on the real
  filesystem — otherwise `uv run` lands on jai's COW overlay and re-installs every fresh
  session, and that work is discarded by `jai -u`.
- Have `codex` and `uv` on `PATH` (jai inherits the parent shell's `PATH`).
- For Claude: `ANTHROPIC_API_KEY` or `<config_dir>/.credentials.json` must be reachable from
  inside jai. Refresh OAuth tokens *outside* jai for Max-subscription users — refreshes write
  back to the credentials file and the writes land in the COW overlay (lost on `jai -u`).

### Approach B — adapter-internal sandbox *(no jai)*

Use this when jai is unavailable (non-Linux host, kernel < 6.13, no setuid permission). Each
adapter remains its own security boundary.

`WORKFLOW.md` — Codex (Codex enforces sandboxing via the named profile in `config.toml`):

```yaml
codex:
  command: codex app-server   # or `npx --yes -p @openai/codex@<pinned> -- codex …`
  approval_policy: never
  use_configured_permissions: true
  thread_sandbox: workspace-write
  turn_sandbox_policy: null
```

`WORKFLOW.md` — Claude (explicit allowlist via `dontAsk`):

```yaml
claude:
  command: uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
  config_dir: ~/.claude-identione
  model: claude-sonnet-4-6
  permission_mode: dontAsk
  allowed_tools:
    - Read
    - Glob
    - Grep
    - Edit
    - Write
    - MultiEdit
    - Bash
    - BashOutput
    - KillBash
    - TodoWrite
    - NotebookEdit
    - mcp__symphony__linear_graphql
  setting_sources: []
```

`~/.codex/config.toml` (Approach B *requires* this — the named profile is what grants `.git`
writes and the cache/credential paths Codex needs for `git push`):

```toml
default_permissions = "workspace-git"

[permissions.workspace-git.filesystem]
":root"          = "read"
":tmpdir"        = "write"
"/tmp"           = "write"
"~/.npm"         = "write"
"~/.config/git"  = "write"
"~/.cache"       = "write"
"~/.local/share" = "write"

[permissions.workspace-git.filesystem.":project_roots"]
"."       = "write"
".git"    = "write"
".agents" = "read"
".codex"  = "read"

[permissions.workspace-git.network]
enabled = true
```

Codex 0.115+ has a hard-coded workspace-write `.git` deny rule that can override the
`:project_roots ".git" = "write"` grant in some versions
(https://github.com/openai/codex/issues/15505). If your installed Codex regresses, pin via
`npx --yes -p @openai/codex@0.114.0 -- codex …` in `command:`. See [SETUP.md](../SETUP.md)
(Approach B) for the full rationale and verification steps.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
