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
     python -m symphony_claude_agent`; `$SYMPHONY_CLAUDE_PRIV_DIR` is injected by
     `SymphonyElixir.Claude.AppServer` and points at the priv dir). Hosts without jai
     must override `agent.claude.command` to drop the prefix. The sidecar hosts
     `claude-agent-sdk` and is configured for
     unattended sandboxed operation: `permission_mode: dontAsk` + tight `allowed_tools` whitelist
     + workspace-`cwd` boundary; anything not pre-approved is denied without prompting.
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
3. Bootstrap a `WORKFLOW.md` for your project:
   ```bash
   ./bin/symphony init \
     --linear-project https://linear.app/<org>/project/<slug> \
     --repo-url git@github.com:<org>/<repo>.git \
     --agent codex \
     --output ./<repo>.WORKFLOW.md
   ```
   The default Linear states (`Todo`, `In Progress`, plus terminal `Done`/`Closed`/`Canceled`/
   `Cancelled`/`Duplicate`) are sufficient — no custom states required. If you prefer the
   richer flow used by this repo (`Human Review`, `Rework`, `Merging`), copy this directory's
   `WORKFLOW.md` instead and adjust the slug, repo URL, and workspace root by hand.
4. Validate the generated workflow before starting:
   ```bash
   ./bin/symphony preflight ./<repo>.WORKFLOW.md
   ```
   `preflight` checks `LINEAR_API_KEY`, project resolution, configured states, repo clone
   access (`git ls-remote`), agent availability, workspace root writability, and dashboard
   port availability — and prints the candidate-issue count without spawning agents.
5. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
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
mise exec -- ./bin/symphony start \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

The legacy form `./bin/symphony [path]` is still accepted as an alias of `./bin/symphony start`.

## Subcommands

```bash
./bin/symphony init [...]        # generate a WORKFLOW.md for a Linear project
./bin/symphony preflight [path]  # validate WORKFLOW.md against the live environment
./bin/symphony start [...] [path]  # boot the orchestrator
./bin/symphony [...] [path]      # alias of `start`, kept for backwards compatibility
```

`init` accepts a Linear project URL or slug and a repo clone URL and writes a usable
`WORKFLOW.md` with env-backed `LINEAR_API_KEY`, default Linear states, and a sensible default
agent block. `preflight` runs the same configuration through a series of best-effort checks
(Linear auth, project resolution, state coverage, repo clone access, agent on `PATH`,
workspace root writability, dashboard port availability) and prints the candidate-issue count
*without* spawning agents.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony start \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

### `repo.url` vs `repo.path`

`init` writes a top-level `repo:` block to make the bootstrap fully declarative:

```yaml
repo:
  url: git@github.com:<org>/<repo>.git
  path: ~/code/<repo>   # optional
```

- `repo.url` is the clone URL Symphony hands to `hooks.after_create` for fresh per-issue
  workspaces. `preflight` uses it for an unauthenticated `git ls-remote` reachability check.
  This is the only repo input the minimal flow needs.
- `repo.path` is an optional pointer to a local copy of the repo. Symphony itself never reads
  or writes through it; it exists so skills that need to inspect or modify project-local
  files outside the per-issue workspace can find the repo on disk. Most users do not need it.
- Legacy workflows that hardcode the URL inside `hooks.after_create` keep working — the
  `repo:` block is optional, and `preflight` simply reports the clone-access check as
  skipped when `repo.url` is absent.

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
- For unattended `git commit` / `git push` flows under `agent.kind: codex`, the Codex
  `workspace-write` sandbox is too restrictive on its own (notably the 0.115+ `.git` deny rule,
  see https://github.com/openai/codex/issues/15505). Two approaches are documented in
  [SETUP.md](../SETUP.md):
  - **Approach A:** wrap the agent command with [`jai`](https://jai.scs.stanford.edu/) as an
    outer sandbox. For Codex, this also allows turning Codex's own sandbox off
    (`sandbox_mode=danger-full-access`) so the deny rule does not apply. Works for either
    adapter.
  - **Approach B (Codex-only):** keep Codex as the security boundary and define a
    `default_permissions` profile in `~/.codex/config.toml` with explicit filesystem mounts and
    `:project_roots` overlay. The `:project_roots".git" = "write"` grant overrides the 0.115+
    `.git` deny rule, so no version pin is required. Useful when jai is not available
    (non-Linux host, kernel < 6.13).
  - The shipped `WORKFLOW.md` runs `agent.kind: claude` by default, with no outer sandbox; the
    Claude Agent SDK sidecar's `permission_mode: dontAsk` + `allowed_tools` whitelist is the
    only boundary. Both `agent.claude:` and `agent.codex:` blocks include the jai-wrapped form
    as a commented swap-ready alternative.
- For `agent.kind: claude`:
  - `claude.config_dir` scopes Claude auth. When set, Symphony preflight-checks
    `<config_dir>/.credentials.json` before launching the sidecar and exports
    `CLAUDE_CONFIG_DIR=<config_dir>` so the SDK uses the corresponding Claude account. When
    unset (no schema default), preflight falls back to `$CLAUDE_CONFIG_DIR/.credentials.json`,
    then `~/.claude/.credentials.json`, and the sidecar inherits whatever `CLAUDE_CONFIG_DIR`
    the parent shell has (or the SDK's `~/.claude` default). Use `config_dir` to pin a daemon
    to a specific subscription (e.g. `~/.claude-identione`) instead of relying on the
    operator's shell env. `~` and `$VAR` are expanded.
  - `claude.permission_mode: dontAsk` (recommended for unattended runs) denies any tool not in
    `claude.allowed_tools` without prompting. Pair with an explicit `allowed_tools` whitelist;
    no fallback prompt is shown when the orchestrator runs unattended.
  - `claude.setting_sources: []` (recommended) keeps the sidecar from inheriting host-level
    Claude Code settings such as `~/.claude/settings.json`, so the daemon's posture stays
    deterministic across operator machines.
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
