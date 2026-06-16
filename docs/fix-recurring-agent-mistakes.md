# Fix Recurring Claude Agent Mistakes (Patterns 2–9)

## Context

Analysis of 137 agent sessions across 70 symphony workspace projects revealed 10
recurring mistake patterns. This plan addresses patterns 2–9 (pattern 1 = rate-limit
loop, requires Symphony code changes; pattern 10 = push skill already exists). All fixes
are prompt/skill edits — no Elixir code changes needed. The goal is to prevent Claude
from rediscovering the same wrong patterns on every session.

All target files live in this repo (`/Users/hniska/code/identione/symphony`). The two
`WORKFLOW` files are kept byte-identical in their body by the guard test
`elixir/test/symphony_elixir/cli_init_test.exs` (it splits on the marker
`You are working on a Linear ticket`), so the two `WORKFLOW` edits below must be the
**exact same text at the exact same structural position** in both files. Note: the file
the daemon actually reads is `instances/<name>/WORKFLOW.md`, which is gitignored and
regenerated from the template by `make init`; running agents keep their old WORKFLOW.md
and only pick up these changes on re-init.

## Verification status

Every anchor and technical claim below was verified against the current files.

| Fix | Anchor | Note |
|---|---|---|
| 2 | `linear/SKILL.md:184` `### Query team workflow states for an issue` | uses `IssueTeamStates` via `issue.team.states` already |
| 3 | `linear/SKILL.md:260` `### Attach a GitHub PR to an issue`; `IssueDetails` (`:156`) returns `attachments.nodes` | guard implementable; complements existing input-object warning at `:298` |
| 6 | `land/SKILL.md:58` `## Commands` | `merged` is not a valid `gh pr view --json` field; use `state`→`MERGED` |
| 4,7,8,9 | `WORKFLOW.md` gap between `## Default posture` (`:254`) and `## Related skills` (`:256`) | template body is byte-identical at `:71`/`:91` |
| 5 | `WORKFLOW.md:311` Step 1 item 5 (environment-stamp step) | template byte-identical at `:146` |

---

## Fixes

### Fix 2 — Linear GraphQL `String!` vs `ID!` (15 errors)

**Root cause:** Claude directly uses `workflowStates(filter: { team: { id: { eq: $teamId } } })`
with `$teamId: String!`, but Linear expects `ID!`, so the query fails. The skill already
has the correct alternative (`IssueTeamStates` via `issue.team.states`) but doesn't warn
against the wrong path.

**File:** `.codex/skills/linear/SKILL.md` — add a warning in the
`### Query team workflow states for an issue` section:

```text
Do not use workflowStates(filter: ...) directly — $teamId expects ID! not
String! and the query fails. Use IssueTeamStates (via issue.team.states) instead.
```

### Fix 3 — Linear PR auto-attachment → "URL already exists" (16 errors)

**Root cause:** Linear auto-attaches a PR to an issue when the PR title contains the
issue key (e.g. `IDE-141`). Claude then calls `attachmentLinkGitHubPR` manually and gets
`INPUT_ERROR: This URL has already been used`.

**File:** `.codex/skills/linear/SKILL.md` — add a "Before attaching" guard to the
`### Attach a GitHub PR to an issue` section:

```text
Before calling attachmentLinkGitHubPR or attachmentLinkURL, check whether the URL
is already attached using IssueDetails (the attachments.nodes field). Match on the
PR number / path suffix, not exact string equality, so a trailing slash or query
param does not defeat the check. If the PR is already in the list, skip — do not
re-attach.

Also: Linear auto-attaches a PR if the PR title contains the issue identifier
(e.g. IDE-141). In that case the attachment already exists before you call anything.
```

### Fix 4 — Parallel cascade failures (25 errors)

**Root cause:** When one tool call in a parallel block fails (e.g. `rm file` for a
non-existent file → exit 1), all sibling parallel calls are cancelled. Most common with
optional delete/cleanup operations placed in parallel with edits.

**Fix:** carried by the **Shell and VCS safety rules** section (see below) — guard
optional deletions with an existence check so a missing file does not cancel sibling
parallel tool calls.

### Fix 5 — Wrong cwd assumption (15 errors)

**Root cause:** The agent sometimes assumes a subdirectory (`cd app`, `ls simulators/`)
when cwd is already the repo root, or uses a doubled path (`app/app/...`). No explicit
orientation step.

**Files:** `elixir/WORKFLOW.md` and `elixir/priv/templates/workflow.md.eex` — add as the
first bullet under **Step 1, item 5** (the environment-stamp step):

- Before writing the environment stamp, run pwd and ls to confirm the working
directory. Record the confirmed path as the cwd in all subsequent relative path
constructions. Never assume a subdirectory; navigate from the confirmed root.

### Fix 6 — `gh pr view --json merged` invalid field (8 errors)

**Root cause:** `merged` is not a valid `gh pr view` JSON field. The correct field is
`state` (value `"MERGED"`) or `mergeStateStatus`.

**File:** `.codex/skills/land/SKILL.md` — add a callout in the `## Commands` section:

```text
Common --json fields for gh pr view (use these, not guesses):
  state            → "OPEN" | "CLOSED" | "MERGED"
  mergeable        → "MERGEABLE" | "CONFLICTING" | "UNKNOWN"
  mergeStateStatus → merge gate status
  number, title, body, url, headRefName, reviews, checks

❌ --json merged — this field does NOT exist; use --json state and check for "MERGED".
```

### Fix 7 — `git add` on non-existent paths → exit 128 (30 errors)

**Root cause:** Claude constructs explicit `git add` paths that don't exist (wrong cwd,
typos, double-prefix). When the add fails the commit is silently skipped.

**Fix:** carried by the **Shell and VCS safety rules** section (see below) — verify the
path exists before `git add`, prefer `git add -u` for already-tracked changes, and scope
with `git status --short` in a dirty worktree.

### Fix 8 — `sleep N && cmd` blocked (5 errors)

**Root cause:** The jai hook blocks `sleep N && <cmd>` chains. Claude wastes a round-trip
switching to `until` loops. (The `until` pattern already appears in `land/SKILL.md:81`.)

**Fix:** carried by the **Shell and VCS safety rules** section (see below) — for polling
use an `until`/`while` loop; for a genuine one-shot delay, run the delay and command as
separate steps rather than chaining.

### Fix 9 — TodoWrite invalid status values (8 errors)

**Root cause:** Claude used status values other than the three valid ones.

**Fix:** carried by the **Shell and VCS safety rules** section (see below) — the only
valid TodoWrite status values are `pending`, `in_progress`, `completed`.

---

## New "Shell and VCS safety rules" section (canonical text, Fixes 4 / 7 / 8 / 9)

Insert the following block **verbatim and byte-identical** between `## Default posture`
and `## Related skills` in **both** `elixir/WORKFLOW.md` and
`elixir/priv/templates/workflow.md.eex`. This is the single source of truth for Fixes
4/7/8/9 — do not reword per file (the `cli_init_test.exs` byte-identity guard will fail
otherwise):

```markdown
## Shell and VCS safety rules

- Guard optional deletions and cleanup so a missing file does not cancel sibling
  parallel tool calls. Prefer an existence check; reserve `|| true` for explicitly
  benign misses. Do not blanket-suppress cleanup errors that should stay visible:
  `[ ! -e path/to/file ] || rm path/to/file`
- Before `git add <path>`, verify the path exists with `git status` or `ls`. Prefer
  `git add -u` (stage modified tracked files) over explicit paths when staging
  already-tracked changes; in a dirty worktree, scope first with `git status --short`.
  Use `git add -A` only when intentionally staging new untracked files too.
- `sleep N && <cmd>` chains are blocked by the sandbox hook. For polling, use an
  `until`/`while` loop (`until <condition>; do sleep 5; done`). For a genuine one-shot
  delay, run the delay and the command as separate steps rather than chaining.
- Valid TodoWrite status values are `pending`, `in_progress`, `completed`. No other
  values are accepted.
```

## Files changed

| File | Patterns fixed |
|---|---|
| `.codex/skills/linear/SKILL.md` | 2, 3 |
| `.codex/skills/land/SKILL.md` | 6 |
| `elixir/WORKFLOW.md` | 4, 5, 7, 8, 9 |
| `elixir/priv/templates/workflow.md.eex` | 4, 5, 7, 8, 9 |

The two `WORKFLOW` files receive identical body edits so active instances (after
re-init) and future generated instances stay in sync.

## Verification

1. **Byte-identity guard:** from `elixir/`, run
   `mix test test/symphony_elixir/cli_init_test.exs` — must pass.
2. **Markdown sanity:** confirm `## Shell and VCS safety rules` renders between Default
   posture and Related skills in both files; confirm linear/land code fences are
   well-formed.
3. **Smoke check (optional):** `make init` a throwaway instance and diff the generated
   `instances/<name>/WORKFLOW.md` to confirm the new section appears.
