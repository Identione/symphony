---
tracker:
  kind: linear
  project_slug: "symphony-2e32f5d86d8c"
  assignee: "me"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Canceled
    - Duplicate
    - Done
polling:
  # Below the 30s default exhausts Linear's hourly budget and arms a 1-hour
  # rate-limit back-off that stalls the daemon. SPEC.md §5.3.2.
  interval_ms: 30000
workspace:
  root: ~/code/workspaces
# Declarative repo metadata (SPEC.md §5.3.6). `repo.url` feeds
# `hooks.after_create` + `symphony preflight`; `repo.path` is optional and
# operator-facing only (Symphony never reads/writes through it).
# Optional `repo.base_branch` (set via `symphony init --base-branch <name>`)
# points agents at a development branch instead of the repo default. It is NOT
# self-contained: the cloned target repo must carry base-aware push/pull/land
# skills (incl. land_watch.py) that read `git config symphony.baseBranch` (set
# by the after_create hook, `main` fallback) to set the PR `--base`, merge the
# right branch, and refuse pushing the protected/base branch. Symphony never
# vendors them — without them PRs target the wrong base and the protected-branch
# guard is absent. See SPEC.md §5.3.6 + elixir/README.md.
repo:
  url: https://github.com/Identione/symphony.git
hooks:
  after_create: |
    git clone --depth 1 https://github.com/Identione/symphony.git .
agent:
  # Defaults + full per-knob rationale live in config/schema.ex; the commented
  # knobs below are safe to leave off. SPEC.md §6.4 is the cheat sheet.
  max_concurrent_agents: 10
  max_turns: 20
  # Per-failure-code retry overrides; built-in defaults are safe.
  # Codes / fields / built-in defaults: SPEC.md §8.4 + config/schema.ex.
  # retry_policy:
  #   rate_limited: { strategy: backoff, base_ms: 60000, max_ms: 900000, honor_retry_after: true }
  #   unknown: { strategy: no_retry }
  # Deterministic-failure escalation: after N same-code failures Symphony alerts
  # in the workpad; after M it moves the issue to the escalation state. Transient
  # codes reset the streak. SPEC.md §14.1 + config/schema.ex.
  # deterministic_failure_alert_threshold: 3
  # deterministic_failure_escalation_threshold: 5
  # deterministic_failure_escalation_state: "Human Review"
  # Episode-scoped ceiling on agent sessions per issue (backstop for the streak;
  # persists under run/, resets when the issue leaves the active set). schema.ex.
  # max_sessions_per_issue: 8
  # Budget-pressure steering + non-destructive cutoff (adapter-agnostic, global
  # agent.*). Behavior + defaults: SPEC.md §6.4 / §9.4 + config/schema.ex.
  # budget_pressure_turns: 2          # commit-now directive near max_turns (0 disables)
  # preserve_uncommitted_work: true   # snapshot dirty tree to refs/symphony/wip/<id>
  # preserve_uncommitted_work_branch: false
  # cutoff_timeout_ms: 60000
  # Per-turn progress signals: report/log/dashboard only, never enforced.
  # docs/progress_signals.md + SPEC.md §13.5. Defaults shown:
  # progress_signal_enabled: true
  # progress_signal_window_k: 4
  # progress_signal_git_timeout_ms: 2000
  # progress_trigger_min_turns: 4
  # AI overseer (SPEC.md §13.6): gated Anthropic call that approves continued
  # extension (to absolute_max_turns) or gives up → Human Review. On by default
  # but dormant without a usable credential for its engine. Full keys/defaults in config/schema.ex.
  # overseer:
  #   enabled: true                  # on by default; needs a usable credential to act
  #   engine: api                    # "api" = direct x-api-key Messages call (needs api_key);
  #                                   # "sidecar" = one read-only turn via the Claude SDK sidecar,
  #                                   #   reusing the Claude adapter's subscription OAuth (no api_key)
  #   model: claude-sonnet-4-6
  #   api_key: $ANTHROPIC_API_KEY    # api engine only; resolved like tracker.api_key/$LINEAR_API_KEY.
  #                                   # Ignored by engine: sidecar (auth comes from the Claude OAuth).
  #   streak_to_llm: 5               # consult after 5 consecutive deterministic no-progress turns
  #   mandatory_llm_every: 40        # also consult every N turns regardless (0 disables)
  #   absolute_max_turns: 500        # hard per-session ceiling (max_turns is the keyless fallback)
  #   winddown_timeout_ms: 120000    # bounded final commit + workpad-update turn before Human Review
  #   min_turns_between: 3           # cooldown between calls
  #   max_calls_per_session: 25      # per-run call cap (hitting it stops extension, never silent)
  #   transcript_window: 40          # bounded transcript evidence window
  #   confidence_floor: 0.6          # below this, downgrade to a (continue) approval
  #   allow_abort: false             # when false, an abort verdict is treated as escalate
  # Claude Agent SDK adapter (SPEC.md §10.8 / §5.3.5.2). Switch `kind: codex`
  # to use the Codex adapter; the nested agent.codex block below is kept so the
  # swap is one line.
  kind: claude
  claude:
    # command: pick ONE. $SYMPHONY_CLAUDE_PRIV_DIR (injected by Claude.AppServer,
    # bash-expanded at exec time) points at priv/claude_agent. `jai` is an
    # optional outer sandbox (../SETUP.md, Approach A — Claude variant).
    # (A) jai outer sandbox. The `--dir $SYMPHONY_CLAUDE_PRIV_DIR` is required:
    # jai casual mode overlays $HOME copy-on-write and only the cwd (the per-issue
    # workspace) is a live passthrough; the orchestrator repo otherwise reads from
    # the COW overlay, which serves a STALE sidecar once uv/python write into
    # priv/claude_agent (copy-up) — and `sync_workpad` disappears. `--dir` grants
    # the priv dir as a live bind that bypasses the overlay, so the jail reads
    # current source. cwd stays the workspace (set via the SDK init envelope) so
    # the agent's workpad.md writes land on real disk where Symphony's File.read
    # sees them. The (B) non-jai variant has no overlay and needs no `--dir`.
    # `--dir $HOME/.cargo` + `--dir $HOME/.rustup` take the Rust toolchain out of
    # the overlay too: overlayfs readdir returns empty on lower-layer registry
    # dirs, so lalrpop finds no grammar sources and the NIF build fails (bulk
    # cargo/tar extractions also silently write 0 files). The agent gains RW to
    # the host cargo cache — same trust level as the priv dir.
    command: jai --dir $SYMPHONY_CLAUDE_PRIV_DIR --dir $HOME/.cargo --dir $HOME/.rustup uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
    # (B) no outer sandbox (Claude SDK is the only boundary):
    #command: uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
    # Scopes Claude auth to this CLAUDE_CONFIG_DIR (identione Max subscription);
    # preflight checks <config_dir>/.credentials.json. SPEC.md §5.3.5.2.
    config_dir: ~/.claude
    # model unpinned → CLI/Max default. effort: low|medium|high|xhigh|max
    # (xhigh is Opus > 4.7 -only). Both default via the SDK when unset.
    # model: claude-opus-4-8
    # effort: xhigh
    # Per-issue-state overrides, keyed by Linear state name (case-insensitive; an
    # entry wins over the top-level model/effort). Mechanical Merging/land runs
    # don't need the flagship at effort high — most of their output tokens are
    # invisible thinking (docs/investigations/claude-session-token-optimization.md).
    # model_by_state:
    #   Merging: claude-sonnet-5
    # effort_by_state:
    #   Merging: low
    #   Rework: medium
    # Within-continuation SDK turn cap (Level 1); distinct from agent.max_turns. Default 100.
    # max_turns: 100
    # Per-call cap (bytes) on native-tool output, shrunk by a PostToolUse hook so
    # it isn't re-paid as cache_read; 0 disables. Default 16384.
    # tool_output_limit: 16384
    # permission_mode: bypassPermissions (active) = allow-all under the jai +
    # workspace-cwd boundary; dontAsk = deny anything not in allowed_tools (an
    # empty/absent allowed_tools is then rejected at boot). SPEC.md §5.3.5.2.
    permission_mode: bypassPermissions
    # allowed_tools (ignored under bypassPermissions; the dontAsk whitelist —
    # full filesystem + shell, no WebFetch/WebSearch). Note that `Task`/`Agent`
    # is NOT gated by this list — subagent calls are permitted under `dontAsk`
    # whether or not it appears here, so do not add it expecting a behavior
    # change, and do not remove anything expecting to disable delegation.
    # Subagents are kept inside the turn by the sidecar's forced
    # CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1, not by permissions):
    #allowed_tools:
    #  - Read
    #  - Glob
    #  - Grep
    #  - Edit
    #  - Write
    #  - MultiEdit
    #  - Bash
    #  - BashOutput
    #  - KillBash
    #  - TodoWrite
    #  - NotebookEdit
    #  - mcp__symphony__linear_graphql        # in-process Linear tool (auth stays in Symphony)
    #  - mcp__symphony_workpad__sync_workpad  # in-process workpad sync (its own sdk MCP server)
    #  #- mcp__lsp                        # project .mcp.json servers need mcp__<server> here
    # Hard-deny list (enforced under both permission modes). The harness's
    # task-management/monitor tools misfire in unattended runs — deferred
    # schemas fail validation and periodic task reminders provoke spurious
    # calls (docs/investigations/claude-session-token-optimization.md).
    # disallowed_tools:
    #   - Monitor
    #   - TaskCreate
    #   - TaskUpdate
    #   - TaskList
    #   - TaskGet
    #   - TaskStop
    #   - TaskOutput
    #   - SendMessage
    # setting_sources unset → loads the target repo's .claude/settings.json,
    # .mcp.json servers, and CLAUDE.md (contained by jai). Set [] to isolate.
    #setting_sources: []
    # Flip to true to restore the noisy SDK/CLI debug feed.
    verbose_logging: false
    # Account-quota-aware dispatch pausing (SPEC.md §5.3.5.3, §8.3). Disabled by
    # default; when enabled, pauses NEW dispatch while any usage window is at/above
    # dispatch_pause_percent (running agents keep going).
    # quota:
    #   enabled: true
    #   dispatch_pause_percent: 95.0
    #   refresh_ms: 60000
    #   max_backoff_ms: 900000   # cap for exponential backoff after failed/rate-limited polls
    #   stale_after_ms: 180000
    #   token_source: claude_cli_refresh   # keeps the OAuth token alive on an idle daemon
    #   cli_refresh_margin_ms: 300000
  codex:
    # command: pick ONE. Both run use_configured_permissions: true, so Symphony
    # omits sandbox on start and the *_sandbox fields below are documentation
    # only. SPEC.md §5.3.5.1 + ../SETUP.md.
    # (A) jai outer sandbox; Codex's own sandbox disabled at the CLI:
    # command: jai codex --config sandbox_mode=danger-full-access app-server
    # (B) host codex with a ~/.codex/config.toml permissions profile granting
    #     .git write (works around openai/codex#15505 — no version pin needed):
    command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
    approval_policy: never
    use_configured_permissions: true
    thread_sandbox: workspace-write
    turn_sandbox_policy:
      type: workspaceWrite
      writableRoots:
        - /home/hniska/code/.symphony-mirrors
      networkAccess: true
    # Quota from the app-server rate-limit stream (no polling); only enabled /
    # dispatch_pause_percent / stale_after_ms apply. Disabled by default.
    # SPEC.md §5.3.5.3, §8.3.
    # quota:
    #   enabled: true
    #   dispatch_pause_percent: 95.0
server:
  port: 3453
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets, or you have handed the issue off to a non-active state (e.g. `Human Review`) — that handoff is the correct way to end.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.

## Linear access

All Linear access goes through Symphony's injected `linear_graphql` tool (exposed as `mcp__symphony__linear_graphql`). Use it for every Linear read and write, **except** workpad comment syncs — those use the companion `sync_workpad` tool (`mcp__symphony_workpad__sync_workpad`), which reads the body from a local `workpad.md` so the multi-KB payload never enters the conversation context (and is not re-paid on every cache_read). Do **not** call `mcp__plugin_linear_linear__*` or any other "Linear MCP" plugin tools — they are not available in this session and will be denied; reaching for them only wastes a turn. If `linear_graphql` is not present, stop and ask the user to configure Linear. See the `linear` skill for query/mutation recipes and the `sync_workpad` lifecycle.

## Skills

- `linear`: raw Linear GraphQL — reads, comment edits, state moves, attachments, uploads.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep the remote branch current and create/update the PR (title, template body, `symphony` label).
- `pull`: sync the branch with latest `origin/main` and resolve conflicts before handoff.
- `land`: when the ticket reaches `Merging`, open and follow `.codex/skills/land/SKILL.md`, which includes the `land` loop.

## Operating rules

- Operate autonomously end-to-end. Never ask a human for follow-up; only stop for a true external blocker (missing required tools/auth/secrets) after exhausting documented fallbacks (see **Waiting and blocked**).
- Reproduce first: confirm the current behavior/issue signal before changing code so the fix target is explicit. Spend the up-front effort on planning and verification design.
- Keep exactly one persistent workpad comment marked `## Symphony Workpad` as the single source of truth for progress and handoff. Reuse it; never open a second workpad and never post separate "done"/summary comments. Do not edit the issue body/description for planning or tracking. If in-session comment editing is unavailable, use the update script; only report blocked if both MCP editing and the script fail.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it into the workpad as required checkboxes (no optional downgrade) and execute it before the work is complete.
- Keep ticket metadata current (state, checklist, acceptance criteria, links) and keep issue text concise, specific, and reviewer-oriented. Move state only when the matching quality bar is met.
- Out-of-scope improvements found mid-execution: file a *separate* Linear issue instead of expanding scope. The follow-up needs a clear title, description, and acceptance criteria; place it in `Backlog`; assign it to the current issue's project; link the current issue as `related`; add `blockedBy` when the follow-up depends on the current issue. If the current issue depends on that follow-up, add the `blockedBy` link on the current issue and keep it in an active state (`In Progress` preferred), not `Human Review`.
- Temporary local proof edits (e.g. tweak a `make` input, hardcode a response path) are allowed only to validate assumptions and **must be reverted before commit**; document them in the workpad `Validation`/`Notes`.
- Prefer `Edit` over `Write` when changing an existing file; use `Write` only to create a new file or fully rewrite one you have `Read` in full this turn.
- Each Bash call runs in a fresh shell: `export`s and `cd` do not persist across calls. Use absolute paths, or `cd /abs/path && <cmd>` within a single call.
- Batch independent tool calls (multiple reads/greps/status checks) into a single response instead of one per round-trip — every round-trip re-reads the whole conversation context.
- When re-checking a file you have already read, re-read only the relevant slice (`Read` with `offset`/`limit`, or `sed -n`), not the whole file.
{%- if agent.kind == "claude" %}
- Ignore harness task-management reminders (nudges to use `TaskCreate`/`TaskList`/etc.); do not call `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`, `TaskOutput`, `TaskStop`, `Monitor`, or `SendMessage` — progress tracking lives in the workpad. This does **not** cover the subagent tool, which appears as `Agent` in tool calls and as `Task` in the tool list: delegating to it is expected, per the delegation rule below.
{%- endif %}
- Never use `sleep` (or `ScheduleWakeup`) to wait for external state such as CI or a merge — see **Waiting and blocked**.
  {%- if agent.kind == "claude" %}
- Delegate independent investigation to subagents. When a step splits into parts that do not depend on each other — surveying unfamiliar areas, gathering evidence across several files, answering separate questions — issue them as parallel `Agent` calls, and pick a cheaper model for mechanical search-and-read work. Two rules on what comes back: report a subagent's findings only once you have actually received them (never summarise, cite, or tick off work from a launch acknowledgement), and re-open a file before citing a specific line rather than citing from memory.
  {%- endif %}

## State routing

Fetch the issue by its explicit ticket ID, read its current state, and route. If the state and issue content are inconsistent, add a short note in the workpad and proceed with the safest flow.

| State | Action |
| --- | --- |
| `Backlog` | Out of scope. Do not modify content or state; wait for a human to move it to `Todo`. |
| `Todo` | Move to `In Progress` immediately, ensure the `## Symphony Workpad` bootstrap comment exists, then run **Execution flow**. If a PR is already attached, run the **PR feedback sweep protocol** first. |
| `In Progress` | Continue **Execution flow** from the existing workpad. |
| `Human Review` | Nothing to do — wait for a human decision. See **Waiting and blocked**. |
| `Merging` | Open and follow `.codex/skills/land/SKILL.md`, then run the `land` loop until merged. Do not call `gh pr merge` directly. After merge, move to `Done`. |
| `Rework` | Run the **Rework** reset (below). |
| `Done` | Terminal. Do nothing and shut down. |

Before reusing a branch, check its PR: if the branch's PR is `CLOSED` or `MERGED`, do not reuse that branch or prior state — create a fresh branch from `origin/main` and restart from reproduction/planning as a new attempt.

{% unless issue.state == "Merging" %}
## Execution flow

For `Todo` (already moved to `In Progress`) or `In Progress`:

1. Open the workpad: search active/unresolved comments for `## Symphony Workpad`; reuse it if present, otherwise create exactly one. Persist its comment ID and write all progress only to that ID. Edit a local `workpad.md` (absolute path required) and push it with the `sync_workpad` tool — exact signature `sync_workpad(issue_id, file_path, comment_id?)`; the body-file parameter is named `file_path`, not `workpad_path`. First sync omits `comment_id` and returns `comment.id` (persist it); later syncs pass that id. Keep `## Symphony Workpad` as the first heading so the marker still resolves.
2. Reconcile before new edits: check off done items, expand/fix the plan for current scope, and confirm `Acceptance Criteria` and `Validation` still fit.
3. Write/refresh a hierarchical plan in the workpad, including:
   - a one-line **deliverable determination**: not every issue is resolved by code. Some are resolved by a documentation/decision record, by recording a deferral, or by closing as already-satisfied. Signals for a non-code resolution: markers like `(deferred)`, "defer", "spike/investigate/decide whether", "behind a flag", "out of scope", or work gated on a precondition that is not yet true; or a sibling issue resolved the same way. When the resolution is non-code, follow the repo's established pattern for it instead of forcing an implementation. If build-vs-defer intent is genuinely ambiguous, pick the safest interpretation, proceed without stalling, and record the assumption so the handoff surfaces it.
   - a compact environment stamp as a code-fence line at the top — `<host>:<abs-workdir>@<short-sha>` (e.g. `devbox-01:/home/dev-user/code/workspaces/MT-32@7bdde33bc`); omit fields already in Linear (issue ID, status, branch, PR link);
   - acceptance criteria and TODOs as checkboxes; for user-facing changes add a UI-walkthrough criterion describing the end-to-end path to validate;
   - any ticket-provided `Validation`/`Test Plan`/`Testing` items, copied in as required checkboxes.
   Run a principal-style self-review of the plan and refine it.
4. Capture a concrete reproduction signal (command/output or deterministic behavior) and record it in the workpad `Notes`.
5. Run the `pull` skill to sync `origin/main` before any code edits, and record a `pull skill evidence` note (merge source(s); `clean` or `conflicts resolved`; resulting `HEAD` short SHA).
6. Implement against the TODOs, keeping the workpad current after each meaningful milestone (reproduction done, change landed, validation run, feedback addressed). Never leave completed work unchecked. For a `Todo` ticket that already had a PR attached, run the **PR feedback sweep protocol** before new feature work.
   {%- if agent.kind == "claude" %}
   - Before the validation gate, check the change size with `git diff --stat`. Only run a code-review pass when the diff is non-trivial (more than one file changed, or roughly >60 changed lines). For a non-trivial diff, invoke `/code-review low` once (the effort level is a bare word, not a flag; this is the diff-scoped built-in skill — fewer, high-confidence findings, no PR needed) — NOT `/simplify`, which fans out whole-repo review subagents and is disproportionate here. For a small single-file diff, skip the review pass entirely. Route any resulting edits through the same validation gate.
   {%- endif %}
7. Validation gate (local): run the project's full local quality gate — not just the tests for the lines you touched — plus every ticket-provided `Validation`/`Test Plan`/`Testing` item; treat unmet items as incomplete. Add a targeted proof that directly demonstrates the changed behavior, but the full gate must also pass. Re-check all acceptance criteria and close gaps. The `push` skill runs this gate and the PR-body check before pushing; run the gate before every `git push`, and if anything fails, fix and rerun until green, then commit (`commit` skill) and push (`push` skill).
8. Publish: ensure the PR is linked on the issue (prefer attachment over a workpad note) and carries the `symphony` label. Merge latest `origin/main` into the branch and rerun the gate if that pulled in changes.
9. Finalize the workpad: mark plan/acceptance/validation items checked; add handoff notes (commit + validation summary); when the delivered work diverges from a literal reading of the issue — a non-code resolution, a deferred/partial scope, or work that turned out already done — also state an explicit **Next step for the reviewer**: what shipped, how it relates to the issue's literal ask, and the concrete next action and why (e.g. "this PR records the deferral — merging it closes the issue as deferred; the feature is intentionally not built"), kept in the workpad and PR body, never the issue description; keep the PR URL on the issue (attachment/link fields), not in the workpad; add a short `### Confusions` section only when something was genuinely unclear. Do not post a separate completion comment.
10. Hand off when the **Completion bar** is met: move the issue to `Human Review` and end the turn. Exception: if waiting on an unresolved `blockedBy` dependency, keep the issue active (do not move to `Human Review`) so Symphony resumes when the blocker clears.

## PR feedback sweep protocol (required)

When a ticket has an attached PR, run this before moving to `Human Review`, and repeat until no actionable items remain:

1. Identify the PR number from issue links/attachments.
2. Gather feedback from every channel:
   - the top-level review summary body and standalone PR comments (`gh pr view --comments`);
   - inline review comments (`gh api repos/<owner>/<repo>/pulls/<pr>/comments`);
   - review summaries/states (`gh pr view --json reviews`).
3. Treat every actionable item — human or bot, inline thread or prose — as blocking until either the code/test/docs address it or a justified pushback reply is posted on that thread.
   - The top-level review summary body and standalone PR comments count the same as inline threads. Scan them for follow-up asks — e.g. "please confirm", "can you verify", "worth a follow-up", "out of scope", "is this intentional", or any direct question to the author — and treat each as a required acceptance item: resolve it in code/docs or post a justified reply.
4. Mirror each feedback item and its resolution into the workpad checklist before moving to `Human Review`.
5. Re-run the validation gate after feedback-driven changes and push the updates.
{% endunless %}

## Waiting and blocked

Waiting on CI or a review decision — **never block on it**:

- Local validation is your gate. Once the validation gate is green, the branch is pushed, the PR is linked and labelled `symphony`, and the workpad is finalized, move the issue to `Human Review` and end the turn.
- Do not wait on, watch, or re-poll remote CI from an active state — the one exception is `Merging` (see the last bullet). A single Bash call is killed at the 10-minute hard max, and ending the turn while the issue is still active triggers an immediate continuation relaunch that counts against the per-issue session budget — repeated CI waits self-escalate the issue. Neither is a valid way to wait.
- `Human Review` is not an active state: after handoff Symphony will not re-invoke you until a human moves the issue to `Merging` or `Rework`. There is nothing to poll, so do not `ScheduleWakeup`/`sleep` or hand-roll a wait loop.
- Remote CI is gated at merge: in `Merging` the `land` skill watches CI via `land_watch.py` and won't squash-merge until green. Watching CI is land's job, in `Merging` only.

Blocked-access escape hatch — only when completion is blocked by a missing required tool or auth/permission that cannot be resolved in-session:

- GitHub is **not** a valid blocker by default. Try fallback strategies first (alternate remote/auth mode, then continue the publish/review flow) and document them in the workpad before treating GitHub access as blocking.
- For a missing non-GitHub tool or unavailable non-GitHub auth, move the ticket to `Human Review` with a concise blocker brief in the workpad: what is missing, why it blocks required acceptance/validation, and the exact human action needed to unblock. Keep it in the workpad — no extra top-level comments. If no workpad exists yet, add a single blocker comment with the same content.

{% unless issue.state == "Merging" %}
## Completion bar before Human Review

- The plan/acceptance/validation checklist in the single workpad comment is complete and accurate.
- Acceptance criteria and all ticket-provided validation items are done, and the local validation gate is green for the latest commit.
- The PR feedback sweep is complete with no actionable items remaining.
- The branch is pushed, the PR is linked on the issue, and it carries the `symphony` label.
- When the delivered work diverges from the issue's literal ask, the workpad states an explicit reviewer next-step (what shipped, how it maps to the ask, and the concrete next action).

## Rework

Treat `Rework` as a full approach reset, not incremental patching:

1. Re-read the full issue body and all human comments; explicitly decide what to do differently this attempt.
2. Close the existing PR tied to the issue.
3. Remove the existing `## Symphony Workpad` comment.
4. Create a fresh branch from `origin/main`.
5. Restart the normal kickoff: if the issue is `Todo` move it to `In Progress` (otherwise keep its state), create a new `## Symphony Workpad` bootstrap comment, then run **Execution flow** end-to-end.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Symphony Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task
  - [ ] 1.2 Child task
- [ ] 2\. Parent task

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] targeted tests: `<command>`

### Handoff

- <what shipped + the reviewer's concrete next step; if it diverges from the issue's literal ask, say so and why>

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
{% endunless %}
