# Investigation: `sync_workpad` never reaches the live Claude agent (jai serves a stale sidecar)

- **Status:** Resolved (2026-06-27) — root cause confirmed, jai model byte-verified, fixed with `jai --dir`, proven live on IDE-258. See "The jai model", "Resolution", "Live proof".
- **Date raised:** 2026-06-24 (symptom observed across many prior sessions)
- **Area:** Claude adapter (`elixir/priv/claude_agent/`), sidecar launch (`elixir/lib/symphony_elixir/claude/app_server.ex`), the `jai` outer sandbox, `agent.claude.command`
- **Severity:** High for Claude-adapter instances.

> **One-line takeaway:** under jai's casual COW `$HOME` overlay, only the **cwd** is a live passthrough; the orchestrator repo otherwise reads from the overlay, which serves a **stale** sidecar once `uv`/`python` write into `priv/claude_agent` (overlayfs *copy-up*). Fix: grant the sidecar source as a live bind with **`jai --dir $SYMPHONY_CLAUDE_PRIV_DIR`**, while keeping the Port cwd = the per-issue **workspace** (so the agent's `workpad.md` writes stay on real disk where Symphony's non-jailed `File.read` can see them).

> **History note:** an earlier fix (2026-06-25) used a `cd $SYMPHONY_CLAUDE_PRIV_DIR &&` prefix to move jai's cwd *into* the repo. That cured the staleness but silently **introduced a second bug** (the workpad `File.read` divergence below) and exposed the repo read-write to the agent. The `--dir` fix supersedes it and fixes both. This doc is the corrected record.

---

## Problem statement

`sync_workpad` lets the agent update a Linear "workpad" comment without ever putting
the multi-KB body in the conversation: Symphony (Elixir, `Codex.DynamicTool.execute_sync_workpad`)
reads the body from a local `workpad.md`; the agent passes only
`{issue_id, file_path, comment_id}`. The Claude sidecar re-exposes Symphony's tools
as **in-process MCP servers** via `create_sdk_mcp_server` — `symphony`
(→ `linear_graphql`) and `symphony_workpad` (→ `sync_workpad`).

There were ultimately **two** related bugs, both rooted in *what jai serves live vs
from its overlay*:

1. **Bug A — `sync_workpad` never registered.** On every live Claude session the
   agent could not see `mcp__symphony_workpad__sync_workpad`; it fell back to raw
   `linear_graphql` `commentCreate/Update`, which the server-side guard then rejected
   (`status=rejected reason=workpad_must_use_sync_workpad`).
2. **Bug B — workpad `File.read` divergence.** Introduced by the first (cd-prefix)
   fix for Bug A: the agent wrote `workpad.md` into the jail overlay while Symphony's
   non-jailed `File.read` read a *different, stale* copy from real disk.

---

## Symptom of Bug A (live log, before any fix)

```
linear_graphql_call op_type=mutation root_field=commentUpdate var_keys=body,id \
  status=rejected reason=workpad_must_use_sync_workpad issue_identifier=IDE-256
```

The session transcript showed the agent trying hard and failing:
`deferred_tools_delta.addedNames` had `mcp__symphony__linear_graphql` but **not**
`mcp__symphony_workpad__sync_workpad`; five `ToolSearch` calls (incl. the exact name)
returned nothing; a direct call returned `No such tool available`; and Google Drive
(`mcp__claude_ai_Google_Drive__*`) was present despite the sidecar setting
`ENABLE_CLAUDEAI_MCP_SERVERS=0` — the tell that the sidecar's own env override **was
not reaching the live CLI**, i.e. the live sidecar was *old code*.

---

## The long red-herring trail (Bug A — documented so nobody re-chases it)

All of these were investigated and ruled out; each was an artifact of the daemon
running *stale sidecar code*:

| Theory | Why it looked right | Why it was wrong |
|---|---|---|
| Bundled CLI surfaces only the **first** in-process MCP tool | early single-server probe | clean probe: one server, both tools surface |
| **2nd in-process MCP server** registration race | live showed `symphony_workpad` absent | every faithful probe showed it connected |
| Tool-search **deferred-pool squeeze** (alphabetical) | `sync_workpad` sorts late | more-tools probe still passed; removing Google Drive didn't change live |
| Workspace project not **trusted/onboarded** | fresh-cwd correlation | not the determinant |
| `ENABLE_TOOL_SEARCH` / `ENABLE_CLAUDEAI_MCP_SERVERS` / `permission_mode` / `setting_sources` / split-vs-single | plausible pool-shapers | each tested at parity; all passed in probe, all failed live |
| `claude-agent-sdk` too old (0.1.76) | major version behind | bumped to 0.2.110 — **still failed live** |

**Every reproduction probe passed; every live run failed — with identical config.**
That contradiction was the clue: probes launched `jai` from a cwd where the live tree
was served; the daemon launched it from a cwd where the overlay served stale code.

---

## The jai model (byte-verified — this is the ground truth)

`jai` (setuid launcher, `/usr/local/bin/jai`, BuildID `477cbc3…`) in **casual** mode:

- **Overlays only `$HOME`, copy-on-write.** `/proc/self/mountinfo` inside the jail:
  `overlay … lowerdir+=/home/hniska,upperdir=/home/hniska/.jai/default.changes`.
  Reads of a `$HOME` path pass through to **real disk** *unless that path has been
  copied-up* into the upper layer; writes go to the upper layer (contained).
- **The cwd is granted as a LIVE passthrough (read-write).** Usage text:
  *"Run `jai -D` to avoid granting the current working directory."* The cwd subtree
  bypasses the overlay entirely. `-D`/`--nocwd` disables it.
- **`-d`/`--dir DIR` grants any user-owned absolute dir LIVE (read-write), regardless
  of cwd** — a real-fs bind that overrides the overlay. Verified: a file written
  outside the jail is read live through `--dir`, and a write inside the jail to a
  `--dir` path appears on real disk. It refuses non-user-owned dirs.
- **No read-only grant in this build.** The installed binary's full flag set is
  `--command --conf --dir --init --jail --mask --mode --nocwd --setenv --storage
  --unmask --unsetenv --xdir` — there is **no `-r`/`--rdir`**. (The current upstream
  jai manual documents `--rdir` for read-only grants; it would require a host upgrade.)
- **`/tmp` and `/var/tmp` are a private tmpfs** (`jai-tmp`), not the host's. Host
  content there is invisible to the jail and vice-versa. (So "stage the sidecar under
  `/tmp`" does **not** work — the jail can't see it.)
- The overlay mounts are **persistent** (`/run/jai/$USER/default.home`), so modifying
  a lowerdir file *after* the overlay exists is overlayfs-"undefined" (can read stale)
  until `jai -u` — another reason to bypass the overlay with `--dir` rather than rely
  on lowerdir passthrough.

---

## Root cause

`Claude.AppServer.open_port/2` spawns the sidecar Port with `{:cd, workspace}`
(`app_server.ex` ~L229) — the per-issue workspace clone. So the agent's working dir is
the workspace (also set independently via the SDK init envelope, `write_init` →
`ClaudeAgentOptions(cwd: workspace)`), and jai's **live cwd grant lands on the
workspace, not the orchestrator repo**.

The sidecar source (`priv/claude_agent`, under `$HOME`) is therefore read through the
**COW overlay**. `uv`/`python` write `.venv` and `__pycache__` *into* `priv/claude_agent`
at launch; those writes trigger overlayfs **copy-up** of the directory, and the
copied-up (frozen) copy then **shadows the live source**. Result: the live agent ran a
months-old `sidecar.py` (single MCP server, no `ENABLE_CLAUDEAI_MCP_SERVERS=0`) →
`sync_workpad` never registered (Bug A) — regardless of edits, SDK bumps, or restarts.

Byte proof on the running host (2026-06-27): grepping the live `sidecar.py` (which
contains a helper added that day) **through the overlay** returns `0`; through
`jai --dir` (overlay bypass) returns `3`.

---

## Why the first (cd-prefix) fix was wrong

The 2026-06-25 fix prefixed the command with `cd $SYMPHONY_CLAUDE_PRIV_DIR &&`, moving
jai's cwd *into* the repo so the repo became the live cwd grant. That cured Bug A but:

- **Bug B (divergence):** with cwd on `priv`, the **workspace** fell into the overlay.
  The agent's `workpad.md` writes went to the overlay upper layer, while Symphony's
  `read_workpad_file` (`File.read`, non-jailed, real disk) read a *different* file.
  Artifact from IDE-256: real-disk `workpad.md` = **1923 B** (an earlier write), overlay
  copy = **666 B** (the agent's actual latest write); the "live proof" log line
  `body_bytes=1923` had read the **stale real-disk file**, not what the agent wrote.
- **Sandbox:** jai's cwd grant is **read-write**, so cwd=priv handed the unattended
  agent live RW access to the orchestrator's own source.

So the cd-prefix traded one bug for another and weakened the sandbox.

---

## Resolution (the fix)

Keep the Port cwd = the **workspace** (unchanged — so the workspace stays a live
passthrough and `File.read` sees the agent's writes), and grant the sidecar source as
a **live bind that bypasses the overlay** with `jai --dir`:

```
jai --dir $SYMPHONY_CLAUDE_PRIV_DIR uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
```

- `--dir` reads the **live** source (no overlay, no copy-up, no stale-lowerdir caveat),
  re-evaluated per launch. `uv` writes `.venv` to the live-bound dir (no copy-up).
- cwd=workspace fixes Bug B: agent `workpad.md` writes land on real disk == what
  `File.read` reads == what is posted to Linear.
- The non-jai variant (`uv run …`) has no overlay and needs no `--dir`.

Applied in four places:

| File | Change |
|---|---|
| `elixir/lib/symphony_elixir/config/schema.ex` | `@default_command` → `jai --dir …` + comment |
| `elixir/WORKFLOW.md` | the (A) jai command + comment |
| `elixir/lib/symphony_elixir/cli/init.ex` | `agent_block("claude")` commented (A) variant + comment |
| `instances/symphony/WORKFLOW.md` | the running instance's command (generated/gitignored) |

Also updated: `SPEC.md` (§5.3.5.2/§10.8/§11) and `SETUP.md` to the `--dir` form.
Regression guard: `claude_adapter_config_test.exs` asserts the default **starts with**
`jai --dir $SYMPHONY_CLAUDE_PRIV_DIR `.

### Sandbox note

The installed jai has no read-only grant, so `--dir` is read-write: the agent has RW to
`priv/claude_agent` (the same exposure the cd-prefix fix already had — no regression).
Two strictly-safer variants were considered and deferred (see Alternatives): they cost
either a staging subsystem or a host jai upgrade for marginal hardening over the inner
SDK boundary (`permission_mode: dontAsk` + `allowed_tools` + workspace cwd).

### Alternatives considered

- **Port `{:cd, workspace}` → `{:cd, priv_dir}` (drop the prefix).** Equivalent to the
  cd-prefix fix — re-introduces Bug B (workspace in overlay) and the RW exposure.
  Rejected.
- **Stage the sidecar under `/tmp` (non-`$HOME`) and run from there.** Fails: jai's
  `/tmp`/`/var/tmp` are a private tmpfs, invisible to the jail. (This was a tempting
  "non-`$HOME` is always live" idea that the byte-probe disproved.)
- **Stage a throwaway copy under `$HOME` + `--dir <staged>`.** Sandbox-safe (canonical
  source stays overlay-protected; agent can only touch the disposable copy), but adds a
  hash-gated staging subsystem. Deferred as heavier than the chosen fix warrants.
- **Upgrade jai + `--rdir` (read-only) on the repo.** Cleanest sandbox posture (live but
  read-only source), no staging, but needs a host jai upgrade and a relocated venv
  (`UV_PROJECT_ENVIRONMENT`, since RO). Deferred; revisit if jai is upgraded.
- **Relocate `uv`/`python` writes out of the repo so copy-up never happens.** Prevents
  *future* copy-up but still relies on overlay lowerdir passthrough being fresh, which
  is overlayfs-"undefined" for a persistent mount after the source changes. Not robust.

---

## Live proof (IDE-258, on the running daemon)

Created a read-only test issue (Todo, assigned to the operator) after restarting the
instance with the `--dir` command:

```
08:32:56 Claude session started … IDE-258
08:33:29 claude_tool_visibility: [tool_use mcp__symphony_workpad__sync_workpad(…)]   ← tool REGISTERED + called
08:33:33 sync_workpad_call action=create body_bytes=1742 has_marker=true … IDE-258
08:33:41 sync_workpad_call action=update body_bytes=1895 has_marker=true … IDE-258
         Issue moved → Human Review
```

- **Bug A fixed:** the agent discovered and called `sync_workpad` (no
  `workpad_must_use` rejection anywhere); the live sidecar even reported the current
  toolchain pins, confirming current code ran.
- **Bug B fixed:** at the latest sync, Symphony's `File.read` = **1895 B**, real-disk
  `workpad.md` = **1895 B**, posted Linear comment = **1895 B** — all identical — and
  the divergent overlay copy (`~/.jai/default.changes/.../IDE-258/workpad.md`) is
  **absent**. The agent's write and Symphony's read are the same real-disk file.

---

## The guard (kept — safety net + the reason Bug A was diagnosable)

`Codex.DynamicTool.execute_linear_graphql` rejects a `commentCreate`/`commentUpdate`
whose body contains `Workpad.marker()` ("## Symphony Workpad") with a `success=false`
payload (`use_tool: sync_workpad`) and logs
`status=rejected reason=workpad_must_use_sync_workpad`; `execute_sync_workpad` passes
`allow_workpad_write: true` to bypass it. Single chokepoint for both adapters. Keep it.
(SPEC.md §10.4 and `.codex/skills/linear/SKILL.md` document it; tests in
`dynamic_tool_test.exs`.)

---

## SDK bump (done, not the fix)

`claude-agent-sdk` 0.1.76 → 0.2.110 (bundled CLI 2.1.132 → 2.1.191). Sidecar imports
clean; pytest green. Did not fix the live failure (that was stale code), but staying
current is fine.

---

## How to detect a recurrence

If `sync_workpad` "vanishes" or the workpad body looks stale/wrong, **check what jai
serves live vs from the overlay first** — do not re-investigate the CLI tool pool:

```bash
PRIV=…/elixir/priv/claude_agent
WS=<any per-issue workspace clone>
MARKER=<a symbol only in the current sidecar.py>
# live source via --dir (overlay bypass) — expect >0:
cd "$WS" && jai --dir "$PRIV" bash -c "grep -c $MARKER $PRIV/symphony_claude_agent/sidecar.py"
# through the overlay (no --dir) — if this is 0 while the above is >0, copy-up shadowing:
cd "$WS" && jai            bash -c "grep -c $MARKER $PRIV/symphony_claude_agent/sidecar.py"
```

For Bug B, compare a `sync_workpad_call body_bytes=N` log line against the real-disk
`workpad.md` size and the posted Linear comment; a divergent
`~/.jai/default.changes/.../workpad.md` copy means the workspace fell into the overlay
(cwd is not the workspace). To clear stale overlay state: `jai -u` (or prune
`~/.jai/default.changes`).

Diagnostic harness used during this investigation lives under
`experiments/claude_mcp_probe/` (untracked).
