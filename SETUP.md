# Symphony Setup

Operator-facing setup that lives outside the repo.

This doc covers the host configuration needed for an unattended coding-agent
session run by Symphony to perform real local writes (e.g. `git commit` /
`git push`) instead of falling back to API-only flows. It applies to both
adapters that ship with Symphony: the Codex App-Server adapter
(`agent.kind: codex`) and the Claude Agent SDK adapter (`agent.kind: claude`).

## The problem

Symphony runs each turn unattended (`approval_policy: never` for Codex,
`permission_mode: bypassPermissions` for Claude under jai). The default
sandboxes either adapter ships with block writes that an unattended commit
flow needs:

- writing the workspace `.git` directory (objects, refs, index, reflog),
- writing tool caches (`uvx`, `pip`, `npm`, `gh`, `mise`, `uv`),
- writing the directory holding `git-credential-store`'s credentials file,
- network out for `git push` over HTTPS, `gh`, npm, PyPI, the Linear API,
  and (for Claude) `api.anthropic.com`.

Codex 0.115+ additionally enforces a hard-coded `.git` deny rule under
`workspace-write` that blocks `git commit` outright; see
<https://github.com/openai/codex/issues/15505>.

There are two approaches Symphony has been verified against. Pick one. **The
current `elixir/WORKFLOW.md` uses Approach A for both adapters.**

## Approach A — jai as an outer sandbox  *(current default)*

[`jai`](https://jai.scs.stanford.edu/) is a setuid Linux sandbox from Stanford
SCS. It wraps a command, gives it a copy-on-write `$HOME` overlay and a private
`/tmp`, and constrains filesystem writes to the current working directory.
Network is unrestricted in casual mode.

In this approach, jai contains the entire agent session externally. The
adapter's own sandbox is then intentionally turned off, which sidesteps the
`.git` deny rule (Codex) and the SDK permission gate (Claude) without pinning
either to a specific version.

### Codex `WORKFLOW.md` snippet

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

### Claude `WORKFLOW.md` snippet

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

What each piece does:

- `jai uv run …` — jai launches the Python sidecar (and its `uv`-managed venv)
  inside the sandbox. The sidecar speaks line-delimited JSON over stdio with
  Symphony; jai does not interfere with that framing.
- `permission_mode: bypassPermissions` — the Claude Agent SDK analog of
  Codex's `--config sandbox_mode=danger-full-access`. The SDK stops asking
  before tool calls; jai is the security boundary now. For hosts without jai
  (kernel < 6.13, non-Linux), switch to `dontAsk` plus an explicit
  `allowed_tools` whitelist (the commented "Alternative" block in the
  shipped `WORKFLOW.md` shows the safe defaults).
- `PYTHONDONTWRITEBYTECODE=1` keeps `.pyc` files from churning jai's COW
  overlay when modules under `priv/claude_agent/` are imported.
- `setting_sources: []` prevents the SDK from inheriting `~/.claude/`
  settings — keep the sidecar's posture deterministic across hosts.

### Host setup

1. Linux 6.13 or newer (jai requires it).
2. Install jai per <https://jai.scs.stanford.edu/install.html>:
    - Arch: `yay -S jai`
    - Debian: `apt install ./jai-x.y-1_amd64.deb`
    - From source: `./configure && make && sudo make install && sudo systemd-sysusers`
3. `jai --init` *once, as your user.* This creates `~/.jai/` with sensible
   blacklists for sensitive dotfiles (`.ssh`, `.gnupg`, etc.).
4. Have `codex` on `PATH` (any recent version). The previous WORKFLOW.md
   pinned Codex via `npx --yes -p @openai/codex@0.114.0`; that's no longer
   needed under Approach A. `~/.codex/config.toml` controls the default model
   and reasoning effort.
5. **For the Claude adapter only:** have `uv` on `PATH` inside the sandbox
   (jai inherits the parent shell's PATH; if you launch via `mise exec`,
   `uv` from `mise.toml` is carried through). Run `make sidecar-deps` once
   *outside* jai to populate `priv/claude_agent/.venv` on the real
   filesystem — otherwise `uv run` inside jai re-installs into the COW
   overlay on every fresh session and that work is discarded by `jai -u`.
   `ANTHROPIC_API_KEY` (or, for Max-subscription users, the contents of
   `<config_dir>/.credentials.json`) must be reachable from inside jai;
   the env var is inherited automatically and the credentials file is
   read-through via the COW overlay. **Caveat for Max users:** OAuth
   token refreshes write back to that file, and those writes land in the
   COW overlay (lost on `jai -u`). Refresh tokens outside jai when
   needed.

### What this gives you

- **Pro:** dodges the Codex 0.115+ `.git` deny rule without pinning to an old
  Codex.
- **Pro:** jai's COW `$HOME` overlay protects `~/.ssh`, `~/.gnupg`, and other
  sensitive dotfiles against agent mishaps regardless of what Codex tries.
- **Pro:** no `~/.codex/config.toml` permissions profile to maintain.
- **Con:** Linux-only, kernel 6.13+, setuid binary.
- **Con:** security model is now jai-only — no Codex-internal defence-in-depth.
  A jai escape would expose the writable cwd (and, in casual mode, the COW
  overlay's deltas).
- **Con:** because cwd is writable and `$HOME` is COW, agents can still write
  noise into the workspace and the overlay; cleanup happens via `jai -u`.

### Verification (IDE-9 acceptance signal)

Inside the launched Codex session:

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

For the **Claude adapter**, ask the model to run a `Bash` tool call with the
same checks plus an Anthropic-API reachability probe:

```bash
test -d .git && test -w .git; echo $?                        # → 0
gitdir=$(git rev-parse --absolute-git-dir) \
  && touch "$gitdir/permissions_check" \
  && rm "$gitdir/permissions_check"; echo $?                 # → 0
curl -fsS -o /dev/null https://api.anthropic.com/; echo $?   # → 0
```

If the `curl` fails, jai is wrapping the sidecar but the sandbox lost
network — confirm jai is in casual mode (the default `jai --init` config).
If the `git` writes fail with a sandbox denial, the sidecar is running
*outside* jai (the `command:` in `WORKFLOW.md` did not start with `jai `).

## Approach B — Codex's own permissions profile  *(alternative)*

This was the path verified by Linear issue
[IDE-9](https://linear.app/identione/issue/IDE-9) before the WORKFLOW.md
switch to jai. Use this when you cannot run jai (non-Linux host, kernel <
6.13, no setuid permission, or you want Codex to remain the security
boundary).

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

### Codex version pin caveat

Codex 0.115+ enforces a hard-coded `.git` deny rule under `workspace-write`
that blocks unattended `git commit`; see
<https://github.com/openai/codex/issues/15505>.

In practice, recent Codex versions (verified at `codex-cli 0.128.0` per
IDE-9) have honored the `:project_roots".git" = "write"` grant and let the
commit through. If your Codex version regresses, either pin Codex to a
version known to work (`npx --yes -p @openai/codex@0.114.0 -- codex …`) or
switch to Approach A.

### Tradeoffs

- **Pro:** portable to any host that runs Codex (no jai requirement).
- **Pro:** explicit, reviewable allowlist of host paths.
- **Pro:** Codex remains the security boundary, with defence-in-depth between
  Codex and Symphony.
- **Con:** depends on Codex version cooperation (the 0.115+ `.git` deny-rule
  history).
- **Con:** the path list grows as your tool ecosystem grows — a new tool that
  caches under a new directory will silently fail until added.

## Site-specific bits not covered above

The maintainer's live `~/.codex/config.toml` also includes
`"~/code/.symphony-mirrors" = "write"`. That path is not referenced by any
Symphony source code — it is a personal mirror cache used by an
`after_create` hook variant. Don't copy it unless you have an equivalent
setup.
