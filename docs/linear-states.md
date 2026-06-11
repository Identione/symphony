# Linear states & comments — how Symphony reacts

Quick reference for how Linear issue states drive Symphony, and when comments
are read. Two layers act on different things:

- **Orchestrator** (Elixir, polling loop) — mechanical. Only cares about
  **state**, bucketed into three categories. Never reads comments to make
  decisions.
- **Agent** (the `WORKFLOW.md` prompt, once dispatched) — semantic. Reads the
  exact state name and runs a state-specific flow, fetching comments itself
  when that flow tells it to.

> **Golden rule:** State is the only thing that triggers Symphony. A comment on
> its own — Linear issue or PR — never wakes Symphony up or re-dispatches an
> agent. You must change state.

---

## Layer 1 — Orchestrator (mechanical, polling)

Reacts only to the two configured lists in `WORKFLOW.md` (names normalized to
lowercase before comparison):

```yaml
tracker:
  active_states:   [Todo, In Progress, Merging, Rework]
  terminal_states: [Canceled, Duplicate, Done]
```

Every state falls into one of three buckets:

| Bucket | While **polling** (not yet running) | While **already running** |
|---|---|---|
| In `active_states` | **Claim & dispatch** an agent (if a slot is free) | Keep running, refresh snapshot |
| In `terminal_states` | Ignored — never claimed | **Stop agent + delete workspace** |
| Neither (e.g. `Backlog`, `Human Review`) | Ignored — never claimed | **Stop agent, keep workspace** |

Key code:
- Dispatch eligibility — `orchestrator.ex:1062` (`should_dispatch_issue?`), `:1100` (`candidate_issue?`). Must be in `active_states` AND not in `terminal_states`.
- Running-issue reconciliation — `orchestrator.ex:670` (`reconcile_issue_state`): terminal→cleanup, active→keep, other→stop-without-cleanup.
- Polling query filters server-side by `active_states` — `linear/client.ex:120`.

Extra mechanical rules tied to state:
- **`Todo` + blocker**: a `Todo` issue is not dispatched if it has a `blockedBy` blocker that isn't itself terminal — `orchestrator.ex:1134`.
- **Per-state concurrency**: `agent.max_concurrent_agents_by_state` caps agents per state (keys lowercased) — `config.ex:51`; else the global `max_concurrent_agents`.
- **Startup cleanup**: on boot, terminal-state issues get their leftover workspaces removed — `orchestrator.ex:93`.
- **Deterministic-failure escalation**: after repeated structured failures, Symphony moves the issue to `deterministic_failure_escalation_state` (default `Human Review`, validated to not be in `active_states`) so the loop stops re-dispatching — `schema.ex:342`.

Why terminal vs. "neither" differ: **Done** = tear it all down (workspace
removed). **Human Review** = pause (agent stops, workspace kept) so work can
resume when a human moves it to `Merging`/`Rework`.

---

## Layer 2 — Agent (semantic, per-state flow)

The agent is **not** handed comments in its prompt — the `Issue` struct has no
`comments` field (`issue.ex`). It fetches them itself: Linear via the
`linear_graphql` tool, PR via `gh`. Whether/how depends on the state's flow in
`WORKFLOW.md` ("Status map" / "Step 0").

| State | What the agent does | Reads comments? |
|---|---|---|
| **Backlog** | Out of scope; do not touch. Waits for human to move to `Todo`. (Orchestrator never claims it.) | No |
| **Todo** (no PR) | Flip to `In Progress`, create `## Symphony Workpad` comment, start implementing. | No (starts fresh) |
| **Todo** (PR attached) | Special case: treat as feedback/rework loop → run full **PR feedback sweep**, address or push back, revalidate, return to `Human Review`. | **Yes — PR comments** |
| **In Progress** | Implementation underway; resume from the workpad scratchpad. Runs PR feedback sweep if a PR exists. | Workpad marker; PR comments if PR exists |
| **Human Review** | PR attached & validated → **wait / poll** for a human decision. Does not code or act on comments. | **No (polls only)** |
| **Merging** | Human approved → run the `land` skill flow (never `gh pr merge` directly). Handles Codex review + inline PR threads as part of land. | Yes, via `land` skill |
| **Rework** | Reviewer requested changes → full reset: re-read issue body + **all human comments**, close PR, delete old workpad, fresh branch, reimplement. | **Yes — reads everything** |
| **Done / Canceled / Duplicate** | Terminal → shut down. (Orchestrator removes workspace.) | No |

### PR feedback sweep protocol (when a PR is attached)
Run before moving to `Human Review`. From `WORKFLOW.md`:
1. Identify PR number from issue links/attachments.
2. Gather feedback from all channels: top-level PR comments (`gh pr view --comments`), inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`), review states (`gh pr view --json reviews`).
3. Every actionable reviewer comment (human or bot) is blocking until either the code/test/docs are updated to address it, or an explicit justified pushback reply is posted on that thread.

This is agent-driven only — the orchestrator never initiates it.

---

## "I left a comment and moved it to an active state" — what happens

| You want | Do this | Why |
|---|---|---|
| It to act on PR review feedback | Move to **Rework** (full reset, reads all comments) — or **In Progress** / re-trigger `Todo` with the PR attached (runs PR feedback sweep) | These flows explicitly fetch comments |
| It to redo the approach from scratch | **Rework** | Treated as a full reset, not incremental patching |
| It to merge after human approval | **Merging** | Runs the `land` flow, reads review threads |
| Nothing yet, just leaving notes | Leave it where it is | Comments without a state change are never read |

Pitfall: **a comment left while the issue sits in `Human Review` is ignored**
until you change state — Human Review is a deliberate stop-and-wait bucket and
isn't in `active_states`, so the agent is stopped. To get feedback addressed,
move it to **Rework**.

---

## Todo vs. Rework when comments exist

Both can be used to feed back, but they behave very differently. **Todo is
incremental; Rework is a nuclear reset.** They also default to reading
**different comment sources**.

| | **Todo** (PR attached) | **Rework** |
|---|---|---|
| Mental model | Patch the existing attempt | Throw it away, start over |
| Existing PR | **Kept** — addressed in place | **Closed** (`WORKFLOW.md:351`) |
| Existing branch | **Reused** (unless PR closed/merged → fresh, `:222`) | **Fresh** from `origin/main` (`:353`) |
| `## Symphony Workpad` | **Reused** if found (`:236`) | **Deleted**, new one created (`:352`, `:356`) |
| Primary comment source | **PR comments** — full feedback sweep (`:216`, `:302`, `:333`) | **All Linear human comments** + full issue body (`:350`) |
| What it does with them | Address each, or post justified pushback, return to `Human Review` | Decide "what to do differently," then re-plan from scratch |
| End state | Back to `Human Review` | Full kickoff → execution end-to-end |

**Which comments trigger each:**
- **Todo** routes off the **PR**: review all open PR comments (`:216`), then run
  the PR feedback sweep — `gh pr view --comments`, inline review comments, review
  states (`:267–270`). No instruction to re-read all human **Linear** comments.
- **Rework** routes off the **Linear issue**: "Re-read the full issue body and
  **all human comments**" (`:350`). This is the Linear-comment read Todo skips.

**Pick by intent:**
- Specific change requests, approach is sound → **Todo** (PR attached) / let the
  In-Progress PR sweep handle it incrementally.
- "This whole approach is wrong, redo it" → **Rework** (full reset, discards
  PR/branch/workpad).

**Caveat:** because Todo's feedback read is PR-centric, comments left **only on
the Linear issue** (not the PR) may not be picked up as actionable feedback in
the Todo path — they mostly land via workpad/validation handling. If your
feedback lives in Linear comments, **Rework** is the reliable route.

---

## Comment-reading map (who reads what, when)

| Level | Component | Reads comments? | When | How |
|---|---|---|---|---|
| Orchestrator | dispatch / reconcile | No | — | state only |
| Orchestrator | deterministic-failure escalation | Yes (to find `## Symphony Workpad` marker) | on repeated agent failures | `Tracker.fetch_comments/1` → Linear GraphQL (`deterministic_failure.ex:258`) — this is **output**, posting an alert, not reacting to your comment |
| Agent | initial prompt | No | — | comments not in `Issue` struct |
| Agent | `linear_graphql` tool | Yes (on demand) | when the flow tells it to | agent builds GraphQL queries |
| Agent | PR feedback sweep | Yes (GitHub) | `Todo`+PR, `In Progress`, before `Human Review` | `gh pr view`, `gh api` |
| Agent | `Human Review` | No | polling only | — |
| Agent | `Rework` | Yes (all) | on entry | `linear_graphql` |

---

## Adding a new state — touch both layers

If you add a Linear state you must update **both**:
1. `tracker.active_states` / `terminal_states` in `WORKFLOW.md` — so the orchestrator buckets it.
2. The prompt's Status map / Step 0 flow — so the agent knows what to do once dispatched.

Miss (1) and the agent never runs for it; miss (2) and the agent runs but has no
instructions for that state.
