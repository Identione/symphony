# Symphony Setup

Operator-facing setup that lives outside the repo.

This doc covers host configuration for Symphony's coding-agent adapters
(`agent.kind: claude` and `agent.kind: codex`) when running unattended.

## What you actually need

- **`agent.kind: claude` (Approach A in shipped `WORKFLOW.md`)** — `uv` on
  `PATH` plus a setuid `jai` binary (Linux 6.13+). The shipped active line
  is `command: jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR …`; the
  no-jai alternative is preserved as a commented `command:` line in the
  same block — uncomment it (and comment out the jai one) to drop to
  adapter-internal sandboxing on hosts without jai.
- **`agent.kind: codex` (Approach B in shipped `WORKFLOW.md`)** — `codex`
  on `PATH` plus a `~/.codex/config.toml` permissions profile that grants
  the writes an unattended `git commit` / `git push` flow needs. Codex's
  default `workspace-write` sandbox blocks them otherwise (notably the
  0.115+ hard-coded `.git` deny rule, see
  <https://github.com/openai/codex/issues/15505>). The `jai codex --config
  sandbox_mode=danger-full-access …` form is preserved as a commented
  alternative for hosts that prefer the jai outer sandbox here too.

The schema defaults (used when `WORKFLOW.md` omits `command:`) differ by
adapter:

- **Claude** ships with jai active by default
  (`jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m
  symphony_claude_agent`). Hosts without jai must override
  `agent.claude.command` to drop the `jai` prefix — the SDK's
  `permission_mode: dontAsk` + `allowed_tools` whitelist remain the inner
  boundary either way.
- **Codex** ships with the no-jai variant by default
  (`npx --yes -p @openai/codex@0.114.0 -- codex app-server …`); switch to
  the jai variant explicitly when you want outer containment.

`$SYMPHONY_CLAUDE_PRIV_DIR` is injected by `SymphonyElixir.Claude.AppServer`
at sidecar launch time and points at this app's `priv/claude_agent` —
bash expands it at exec time, so the path resolves regardless of the
per-issue workspace cwd.

## Why Codex needs help

When Codex runs with `approval_policy: never`, its `workspace-write` sandbox
blocks the writes an unattended commit flow needs:

- writing the workspace `.git` directory (objects, refs, index, reflog),
- writing the directory holding `git-credential-store`'s credentials file,
- writing tool caches (`uvx`, `pip`, `gh`, `mise`),
- network out for `git push` over HTTPS, `gh`, the Linear API, etc.

Codex 0.115+ additionally enforces a hard-coded `.git` deny rule under
`workspace-write` that blocks `git commit` outright. Pick Approach A or B
below.

## Approach A — jai as an outer sandbox

[`jai`](https://jai.scs.stanford.edu/) is a setuid Linux sandbox from Stanford
SCS. It wraps a command, gives it a copy-on-write `$HOME` overlay and a private
`/tmp`, and constrains filesystem writes to the current working directory.
Network is unrestricted in casual mode.

Either adapter can run inside jai by prefixing `agent.<kind>.command` with
`jai`. For Codex, jai also lets you turn Codex's own sandbox off
(`sandbox_mode=danger-full-access`), which sidesteps the 0.115+ `.git` deny
rule. For Claude, jai is purely outer containment — the sidecar's
`permission_mode: dontAsk` + `allowed_tools` whitelist remains the inner
boundary.

### Codex variant — `WORKFLOW.md` snippet

```yaml
codex:
  command: jai codex --config sandbox_mode=danger-full-access app-server
  approval_policy: never
  use_configured_permissions: true
  thread_sandbox: workspace-write   # ignored when use_configured_permissions: true
  turn_sandbox_policy: null         # ignored when use_configured_permissions: true
```

What each piece does:

- `jai codex …` — jai launches `codex` inside the sandbox.
- `--config sandbox_mode=danger-full-access` — Codex CLI override telling Codex
  not to apply its *own* sandbox. jai is the sandbox now.
- `use_configured_permissions: true` — makes Symphony omit `sandbox` and
  `sandboxPolicy` on `thread/start` and `turn/start` JSON-RPC calls. With Codex
  in `danger-full-access`, there is nothing useful for Symphony to supply
  anyway.
- `thread_sandbox` and `turn_sandbox_policy` are forced to `nil` by Symphony
  when `use_configured_permissions: true`
  (`elixir/lib/symphony_elixir/config/schema.ex:297` and `:316`). Keeping them
  in the YAML is harmless and documents intent for the
  `use_configured_permissions: false` mode.

### Host setup (common)

1. Linux 6.13 or newer (jai requires it).
2. Install jai per <https://jai.scs.stanford.edu/install.html>:
    - Arch: `yay -S jai`
    - Debian: `apt install ./jai-x.y-1_amd64.deb`
    - From source: `./configure && make && sudo make install && sudo systemd-sysusers`
3. `jai --init` *once, as your user.* This creates `~/.jai/` with sensible
   blacklists for sensitive dotfiles (`.ssh`, `.gnupg`, etc.).

For the **Codex variant**, also have `codex` on `PATH` (any recent version).
`~/.codex/config.toml` controls the default model and reasoning effort.

For the **Claude variant**, have `uv` on `PATH` so `bash -lc` can launch the
Python sidecar (`uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m
symphony_claude_agent`). On first invocation `uv` provisions the sidecar's
venv under `~/.cache/uv`; inside jai that lands in the COW overlay and is
rebuilt every session. Pre-warm a host-side cache to keep first-turn latency
down:

```bash
uv run --project /abs/path/to/elixir/priv/claude_agent python -m symphony_claude_agent --help
```

### Claude variant — `WORKFLOW.md` snippet

```yaml
claude:
  command: jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
  config_dir: ~/.claude-identione
  model: claude-opus-4-7
  permission_mode: dontAsk
  allowed_tools: [Read, Glob, Grep, Edit, Write, MultiEdit, Bash, BashOutput, KillBash, TodoWrite, NotebookEdit, mcp__symphony__linear_graphql]
  setting_sources: []
```

What each piece does:

- `jai uv run …` — jai launches `uv run`, which provisions the sidecar venv
  and execs `python -m symphony_claude_agent`.
- `$SYMPHONY_CLAUDE_PRIV_DIR` is injected by `SymphonyElixir.Claude.AppServer`
  at sidecar launch time (resolves to this app's `priv/claude_agent`) and
  expanded by bash at exec. Symphony launches the sidecar via `bash -lc`
  with the per-issue workspace as cwd, so a relative path here would not
  resolve to the sidecar source dir — the env-var indirection keeps the
  command portable across hosts.
- `config_dir: ~/.claude-identione` — auth scope. Symphony preflight-checks
  `<config_dir>/.credentials.json` and exports `CLAUDE_CONFIG_DIR=<config_dir>`
  to the sidecar so it uses the corresponding Claude account. Reads pass
  through jai's COW overlay; writes (token refresh, etc.) land in the
  overlay and are discarded on session end. Acceptable when refreshes are
  rare — re-login on the host if a session ends with a stale credential.
- `permission_mode: dontAsk` and the explicit `allowed_tools` list remain
  the inner boundary; jai does not relax them.

### What this gives you

- **Pro (Codex):** dodges the 0.115+ `.git` deny rule without pinning Codex
  or maintaining a `~/.codex/config.toml` permissions profile.
- **Pro (both):** jai's COW `$HOME` overlay protects `~/.ssh`, `~/.gnupg`,
  and other sensitive dotfiles against agent mishaps regardless of what the
  inner agent tries.
- **Con:** Linux-only, kernel 6.13+, setuid binary.
- **Con (Codex):** security model is now jai-only — no Codex-internal
  defence-in-depth. A jai escape would expose the writable cwd (and, in
  casual mode, the COW overlay's deltas).
- **Con (both):** because cwd is writable and `$HOME` is COW, agents can
  still write noise into the workspace and the overlay; cleanup happens via
  `jai -u`.
- **Con (Claude):** `~/.claude-identione/` writes are non-durable (overlay
  only); a session that needs to refresh credentials will discard the
  refresh on exit.

### Verification (IDE-9 acceptance signal)

Codex variant — inside the launched Codex session:

```bash
codex --version                                              # codex-cli 0.128.0
test -d .git && test -r .git && test -w .git; echo $?        # → 0
gitdir=$(git rev-parse --absolute-git-dir) \
  && touch "$gitdir/permissions_check" \
  && rm "$gitdir/permissions_check"; echo $?                 # → 0
```

The Codex banner should show the workspace `.git` as a writable root and
`network_access=true`. If the second command fails with a sandbox denial, jai
is not actually wrapping the session (e.g. `codex` is not on `PATH` inside the
sandbox, or jai is crashing on a kernel < 6.13).

Claude variant — observe sandbox containment from the host:

```bash
pgrep -af symphony_claude_agent           # locate the sidecar pid
ls /proc/<pid>/root/                       # under jai: shows the sandbox $HOME
                                           # without jai: shows the real /
```

Symphony's own preflight (`<config_dir>/.credentials.json` exists) runs
before the sidecar starts; a successful turn against a real Linear issue is
the integration acceptance signal.

## Approach B — Codex's own permissions profile  *(Codex only, alternative)*

Use this when you want `agent.kind: codex` without an outer sandbox — e.g.
when jai isn't available (non-Linux host, kernel < 6.13, no setuid
permission), or when you want Codex itself to remain the security boundary.

In this approach, Codex enforces sandboxing using a named profile in
`~/.codex/config.toml`. Symphony still sets `use_configured_permissions: true`
to step out of the way, but Codex itself stays in `workspace-write` mode and
relies on the explicit allowlist below.

### `WORKFLOW.md` snippet

```yaml
codex:
  command: codex app-server
  approval_policy: never
  use_configured_permissions: true
  thread_sandbox: workspace-write
  turn_sandbox_policy: null
```

### `~/.codex/config.toml` additions

```toml
default_permissions = "workspace-git"

[permissions.workspace-git.filesystem]
":root"           = "read"
":tmpdir"         = "write"
"/tmp"            = "write"
"~/.npm"          = "write"
"~/.config/git"   = "write"
"~/.cache"        = "write"
"~/.local/share"  = "write"

[permissions.workspace-git.filesystem.":project_roots"]
"."       = "write"
".git"    = "write"
".agents" = "read"
".codex"  = "read"

[permissions.workspace-git.network]
enabled = true
```

> Path expansion: confirm against your installed Codex schema whether `~` is
> expanded inside `[permissions...]` keys. If it is not, replace `~` with your
> absolute home directory.

### Why each line is there

**`default_permissions = "workspace-git"`** — picks the named profile below.
The name is arbitrary; just keep it aligned with the `[permissions.<name>...]`
table headers.

**`[permissions.workspace-git.filesystem]`**

- `:root = "read"` — read-only baseline outside the writable mounts. Setting
  it to `"write"` would weaken the sandbox to host-wide writes.
- `:tmpdir = "write"` and `/tmp = "write"` — scratch space.
- `~/.npm = "write"` — required if Codex is invoked via
  `npx --yes -p @openai/codex@…`.
- `~/.config/git = "write"` — a deliberate workaround. `git push` uses
  `git-credential-store`, whose credentials file lives under `~/.config/git/`.
  Granting the *file* directly does not work, because Codex layers the
  `:project_roots` overlay (`.git`, `.codex`, …) under every writable path,
  and the overlay can only be applied to directories. So we grant the parent
  directory instead. Keep secrets in that directory scoped accordingly.
- `~/.cache = "write"` — uvx, pip, gh, mise package caches.
- `~/.local/share = "write"` — uv, mise, pipx tool installs.

**`[permissions.workspace-git.filesystem.":project_roots"]`** — overlay
applied under every writable directory granted above (and under the workspace
itself).

- `. = "write"` — workspace files writable.
- `.git = "write"` — `git commit` writes objects, refs, index, and reflog.
  This works because `WORKFLOW.md`'s `after_create` is a plain
  `git clone --depth 1`, so the workspace `.git` is a real directory inside
  the project root, not a pointer file from a worktree or submodule. If you
  switch `after_create` to `git worktree add` or similar, this grant will not
  apply.
- `.agents = "read"` and `.codex = "read"` — agent skills and repo-local
  Codex policy stay read-only at runtime so a session cannot quietly modify
  the rules it is meant to follow.

**`[permissions.workspace-git.network] enabled = true`** — required for any
operation that hits a remote. If you want offline-only Codex runs in some
other workflow, define a separate profile (e.g.
`[permissions.workspace-offline.*]`) and switch via `default_permissions` or
a per-invocation override.

### Codex 0.115+ note

Codex 0.115+ enforces a hard-coded `.git` deny rule under `workspace-write`
that blocks unattended `git commit`; see
<https://github.com/openai/codex/issues/15505>.

The `:project_roots".git" = "write"` grant in the profile above overrides
that deny rule (verified through `codex-cli 0.128.0` per
[IDE-9](https://linear.app/identione/issue/IDE-9)), so the host-installed
`codex` works without pinning. If a future Codex version regresses, switch
to Approach A.

### Tradeoffs

- **Pro:** portable to any host that runs Codex (no jai requirement).
- **Pro:** explicit, reviewable allowlist of host paths.
- **Pro:** Codex remains the security boundary, with defence-in-depth between
  Codex and Symphony.
- **Con:** depends on Codex's `:project_roots` overlay continuing to honor
  the `.git = "write"` grant against the 0.115+ deny rule.
- **Con:** the path list grows as your tool ecosystem grows — a new tool that
  caches under a new directory will silently fail until added.

## No outer sandbox (Claude alternative)

`agent.kind: claude` does not require an outer sandbox to run safely. The
shipped `WORKFLOW.md` and the schema default both ship with jai active,
but the Claude block keeps the no-jai variant as a commented `command:`
alternative — uncomment it (and comment out the jai one) on hosts without
jai. The Claude Agent SDK in the Python sidecar enforces:

- `permission_mode: dontAsk` — anything not in `allowed_tools` is denied
  without prompting.
- `allowed_tools` — explicit whitelist (no `WebFetch`, `WebSearch`, no
  unsupervised sub-agents).
- `setting_sources: []` — no inheritance from `~/.claude/settings.json`.

The sidecar runs with the per-issue workspace as cwd. `~/.claude-identione/`
is read for auth and written through to the host (so token refresh
persists, unlike the jai variant). Use this mode when jai is unavailable, or
when you want the most portable Symphony setup. For Codex, an unsandboxed
direct run is **not** supported — pick Approach A or B.

## Site-specific bits not covered above

The maintainer's live `~/.codex/config.toml` also includes
`"~/code/.symphony-mirrors" = "write"`. That path is not referenced by any
Symphony source code — it is a personal mirror cache used by an
`after_create` hook variant. Don't copy it unless you have an equivalent
setup.
