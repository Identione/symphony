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
  # Each poll cycle issues several Linear GraphQL calls; intervals below the
  # 30s schema default exhaust Linear's hourly budget and arm a 1-hour
  # rate-limit back-off that stalls the daemon.
  interval_ms: 30000
workspace:
  root: ~/code/workspaces
# Declarative repo metadata (SPEC.md §5.3.6). `repo.url` is consumed by
# `hooks.after_create` for fresh per-issue workspaces and by `symphony
# preflight` for an unauthenticated `git ls-remote` reachability probe.
# `repo.path` is optional and operator-facing only; Symphony itself never
# reads or writes through it.
repo:
  url: https://github.com/Identione/symphony.git
hooks:
  after_create: |
    git clone --depth 1 https://github.com/Identione/symphony.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
  # Per-failure-code retry policy (IDE-72). Each entry overrides the built-in
  # default for the matching error code from the adapter taxonomy
  # (IDE-71). Recognized codes: `rate_limited`, `overloaded`,
  # `context_window_exhausted`, `quota_exceeded`, `invalid_request`,
  # `unknown`. Entry keys:
  #
  #   strategy:          `backoff` (default) or `no_retry`
  #   base_ms:           initial delay for `backoff`; per-attempt doubling
  #   max_ms:            hard cap for `backoff`
  #   honor_retry_after: when true, the orchestrator uses any upstream
  #                      `Retry-After` hint (clamped to max_ms)
  #
  # Omit the section entirely to keep the built-in policy:
  #   rate_limited / overloaded         → 30s base, honors Retry-After
  #   context_window_exhausted          → no_retry (issue routed to blocked)
  #   quota_exceeded / invalid_request  → no_retry
  #   unknown                           → 10s base (legacy exponential backoff)
  # retry_policy:
  #   rate_limited:
  #     strategy: backoff
  #     base_ms: 60000
  #     max_ms: 900000
  #     honor_retry_after: true
  #   unknown:
  #     strategy: no_retry
  # Deterministic-failure escalation (IDE-73). After N consecutive failures
  # carrying the same structured `error_code` (IDE-71 taxonomy:
  # quota_exceeded / context_window_exhausted / invalid_request / port_exit /
  # claude_sidecar_exit), Symphony appends a summary to the existing
  # `## Symphony Workpad` comment — or, if none exists, posts a standalone
  # blocker comment. After M, it also moves the issue to
  # `deterministic_failure_escalation_state` so the polling loop stops
  # re-dispatching. Transient codes (`rate_limited`, `overloaded`,
  # `turn_timeout`, `response_timeout`, `unknown`) reset the counter so a brief upstream blip
  # never trips these thresholds. Defaults: 3 / 5 / "Human Review". Lower the
  # alert/escalation thresholds for tighter feedback; raise
  # max_retry_backoff_ms below to slow retries between alerts.
  # deterministic_failure_alert_threshold: 3
  # deterministic_failure_escalation_threshold: 5
  # deterministic_failure_escalation_state: "Human Review"
  # Cumulative, episode-scoped ceiling on agent sessions per issue (P1/R1(a)).
  # Failure-mode-agnostic backstop for the deterministic-failure streak: it
  # catches an issue that keeps finishing turns cleanly yet never leaves the
  # active set (poll-only / blocked-parent loop). On breach the issue escalates
  # to `deterministic_failure_escalation_state`. The count persists per issue
  # under the instance `run/` (survives daemon restart / `make upgrade`; wiped
  # by `make clean`) and resets when the issue leaves the active set. Default 8.
  # max_sessions_per_issue: 8
  # Budget-pressure steering + non-destructive cutoff (IDE-189 / Layer 0).
  # These knobs are global `agent.*` (not per-adapter): both mechanisms live in
  # the adapter-agnostic shared turn loop / orchestrator, so codex and claude
  # are covered identically.
  #
  # budget_pressure_turns: when the continuation march is within this many turns
  # of `max_turns`, the *next* turn's prompt carries an explicit directive to
  # commit the working state now (reusing the `commit` skill already defined in
  # this prompt body) so converging work is captured before the cap forcibly
  # stops the run. Must leave >=1 actionable turn; `0` disables steering.
  # budget_pressure_turns: 2
  # preserve_uncommitted_work: master switch for non-destructive cutoff. Before
  # any session stop or `max_turns` cutoff, snapshot a dirty working tree to a
  # `refs/symphony/wip/<id>` commit (captures modified + staged + UNTRACKED
  # files via a temp-index commit-tree) without touching HEAD, the branch, or
  # the working tree. Recover with `git log refs/symphony/wip/<ID>`.
  # preserve_uncommitted_work: true
  # preserve_uncommitted_work_branch: also create a visible/diffable
  # `symphony/wip/<id>` branch alongside the ref (the ref is always created).
  # preserve_uncommitted_work_branch: false
  # cutoff_timeout_ms: timeout for the preservation git-shell invocation.
  # cutoff_timeout_ms: 60000
  # Deterministic per-turn progress signals (IDE-211 / Layer 1). At each turn
  # boundary a cheap non-mutating git probe classifies the issue as
  # progressing/stuck/oscillating/repeated_error plus an independent
  # `at_risk_no_commits` flag. Reported + logged + on the dashboard only — never
  # acted on (Layers 0/2 own enforcement). See docs/progress_signals.md.
  # progress_signal_enabled: master switch.
  # progress_signal_enabled: true
  # progress_signal_window_k: consecutive-turn window K (>= 2) before
  # stuck/repeated_error fire and the turn floor for at_risk_no_commits.
  # progress_signal_window_k: 4
  # progress_signal_git_timeout_ms: per-turn probe timeout; a slow/locked repo
  # degrades to "unknown" (assessment unchanged) rather than stalling the loop.
  # progress_signal_git_timeout_ms: 2000
  # progress_trigger_min_turns: turn floor for the at_risk_no_commits arm of the
  # Layer-2 trigger predicate.
  # progress_trigger_min_turns: 4
  # AI overseer (IDE-212 / IDE-230 / Layer 2). A gated Anthropic call that judges
  # an extending run against its plan and either APPROVES continued extension
  # (up to absolute_max_turns) or GIVES UP — posting findings, suppressing the
  # retry, and moving the issue to Human Review after one graceful wind-down turn.
  # ON BY DEFAULT, but dormant without a resolved api_key (then the run caps at
  # `max_turns` and posts a "could not judge" comment). Fails open on any error.
  # See SPEC.md §13.6. Uncomment to override the defaults shown:
  # overseer:
  #   enabled: true                  # on by default; needs a resolved api_key to act
  #   engine: api                    # only "api" (read-only Messages call) is implemented
  #   model: claude-sonnet-4-6
  #   api_key: $ANTHROPIC_API_KEY    # resolved like tracker.api_key/$LINEAR_API_KEY
  #   streak_to_llm: 5               # consult after 5 consecutive deterministic no-progress turns
  #   mandatory_llm_every: 40        # also consult every N turns regardless (0 disables)
  #   absolute_max_turns: 500        # hard per-session ceiling (max_turns is the keyless fallback)
  #   winddown_timeout_ms: 120000    # bounded final commit + workpad-update turn before Human Review
  #   min_turns_between: 3           # cooldown between calls
  #   max_calls_per_session: 25      # per-run call cap (hitting it stops extension, never silent)
  #   transcript_window: 40          # bounded transcript evidence window
  #   confidence_floor: 0.6          # below this, downgrade to a (continue) approval
  #   allow_abort: false             # when false, an abort verdict is treated as escalate
  # Claude Agent SDK adapter (SPEC.md §10.8). Switch to `codex` to use the
  # legacy Codex App-Server adapter — the nested `agent.codex` block below
  # is preserved so the swap is one-line.
  kind: claude
  claude:
    # ── command: pick ONE ──
    # `$SYMPHONY_CLAUDE_PRIV_DIR` is injected by `Claude.AppServer` and
    # points at this app's `priv/claude_agent`; bash expands it at exec
    # time, so the path resolves regardless of the per-issue workspace cwd.
    # The Claude Agent SDK enforces its own boundary via `permission_mode`
    # + `allowed_tools` below. `jai` is an optional outer sandbox — see
    # ../SETUP.md (Approach A — Claude variant).
    #
    # (A) jai outer sandbox: COW $HOME overlay protects ~/.ssh, ~/.gnupg, etc.
    command: jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
    #
    # (B) no outer sandbox (Claude SDK is the only boundary):
    #command: uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
    # Scope Claude auth to this CLAUDE_CONFIG_DIR so we use the identione
    # Max subscription, not whatever ~/.claude/ happens to be logged into.
    # Symphony's preflight checks <config_dir>/.credentials.json, and the
    # sidecar inherits CLAUDE_CONFIG_DIR=<config_dir> at run time.
    # Under (A), writes to this dir land in jai's COW overlay and are lost on
    # session end — accepted tradeoff (auth reads still pass through).
    config_dir: ~/.claude-identione
    # Model is intentionally unpinned → the Claude CLI / Max-subscription
    # default applies. Uncomment to pin a specific model.
    # model: claude-opus-4-7
    # Reasoning effort: low|medium|high|xhigh|max. Unset → SDK default (high).
    # `xhigh` is Opus 4.7-only (the parallel to Codex's model_reasoning_effort).
    # effort: xhigh
    # Level-1 belt: caps SDK model turns *within a single continuation*.
    # Defaults to 40 (well above the observed 2–4 norm) so a within-query tool
    # runaway can't march unbounded. Distinct from the top-level
    # `agent.max_turns` (the Level-2 continuation cap). Uncomment to override.
    # max_turns: 40
    # R2b: per-call cap (bytes) on native-tool output (Read/Bash/Grep/Glob). A
    # PostToolUse hook shrinks oversized results head+tail so a large output
    # isn't re-paid as cache_read on every later turn; the model is told it can
    # re-read a narrower slice. Default 16384 (16 KiB); set 0 to disable.
    # tool_output_limit: 16384
    # Tool access is the `permission_mode` switch:
    #   bypassPermissions — allow-all (active default). `allowed_tools` is ignored
    #                       and every tool runs (incl. WebFetch/WebSearch/Agent).
    #                       Only the jai command + workspace-cwd invariant remain
    #                       as the boundary. This is the Codex danger-full-access
    #                       equivalent — appropriate because we run under jai.
    #   dontAsk           — whitelist mode. Denies anything not in `allowed_tools`
    #                       without prompting. The commented whitelist below mirrors
    #                       what Codex's `approval_policy: never` + workspace-write
    #                       grants: full filesystem + shell, but no
    #                       WebFetch/WebSearch and no unsupervised sub-agents.
    #                       An empty/absent allowed_tools under dontAsk denies
    #                       ALL tools and is rejected at boot (Config.validate!).
    #                       To use it, set `permission_mode: dontAsk` and uncomment
    #                       the `allowed_tools` list.
    permission_mode: bypassPermissions
    # allowed_tools (ignored under bypassPermissions; the dontAsk whitelist):
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
    #  # In-process MCP tool the sidecar exposes; round-trips back to Symphony
    #  # so Linear auth never leaves the orchestrator.
    #  - mcp__symphony__linear_graphql
    #  # Project `.mcp.json` server tools (e.g. an `lsp` code-intelligence
    #  # server) must be allowlisted to be callable under `dontAsk`: add
    #  # `mcp__<server>` here (e.g. `mcp__lsp`) or rely on the repo's loaded
    #  # `.claude/settings.json` `permissions.allow`.
    #  #- mcp__lsp
    # `setting_sources` is intentionally unset: like an interactive `claude`
    # run, the agent loads the target repo's `.claude/settings.json`
    # (incl. `enableAllProjectMcpServers`), project `.mcp.json` servers, and
    # `CLAUDE.md`. The `jai` command above is the outer sandbox that contains
    # this inherited surface (repo hooks / permission rules). Uncomment for
    # deterministic isolation (load no host-level settings).
    #setting_sources: []
    # Quiet by default so Claude's debug feed doesn't drown out per-issue
    # orchestration output. Flip to `true` to restore the noisy debugging view:
    # SDK partial-message + hook-event streams, the underlying `claude` CLI's
    # stderr forwarded as `log` envelopes, and Symphony's per-envelope
    # `claude tool_call` / `assistant_message` / `turn_completed` log lines.
    verbose_logging: false
    # Account-quota-aware dispatch pausing (SPEC.md §5.3.5.3, §8.3). Disabled by
    # default. When `enabled`, Symphony polls the Claude OAuth usage endpoint
    # every `refresh_ms` and stops dispatching NEW issues whenever any usage
    # window is at/above `dispatch_pause_percent` (running agents keep going).
    # The OAuth token is read from $CLAUDE_CODE_OAUTH_TOKEN, else
    # <config_dir>/.credentials.json. Quota is still tracked/displayed when
    # disabled — only the pause action is gated.
    # quota:
    #   enabled: true
    #   dispatch_pause_percent: 95.0
    #   refresh_ms: 60000
    #   stale_after_ms: 180000
    #   # token_source: claude_cli_refresh keeps the OAuth token alive on an
    #   # idle daemon by running a zero-inference `claude` startup (it performs
    #   # the OAuth refresh in place) when the cached token nears expiry. Leave
    #   # as `credentials_file` if you instead use a long-lived
    #   # CLAUDE_CODE_OAUTH_TOKEN (`claude setup-token`).
    #   token_source: claude_cli_refresh
    #   cli_refresh_margin_ms: 300000
  codex:
    # ── command: pick ONE of (A) or (B) ──
    # Both variants run with `use_configured_permissions: true`, which makes
    # Symphony omit `sandbox`/`sandboxPolicy` on thread/turn start. The
    # thread_sandbox / turn_sandbox_policy fields below are ignored under
    # that flag and kept only as documentation. See ../SETUP.md.
    #
    # (A) jai outer sandbox; Codex's own sandbox disabled at the CLI.
    # command: jai codex --config sandbox_mode=danger-full-access app-server
    #
    # (B) host `codex` with `~/.codex/config.toml` permissions profile.
    #     The profile's `:project_roots".git" = "write"` grant overrides the
    #     0.115+ `.git` deny rule (https://github.com/openai/codex/issues/15505),
    #     so no version pin is needed.
    command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
    approval_policy: never
    use_configured_permissions: true
    thread_sandbox: workspace-write
    turn_sandbox_policy:
      type: workspaceWrite
      writableRoots:
        - /home/hniska/code/.symphony-mirrors
      networkAccess: true
    # Codex quota usage is derived from the app-server rate-limit stream (no
    # polling), so only `enabled` / `dispatch_pause_percent` / `stale_after_ms`
    # apply here. Disabled by default; see SPEC.md §5.3.5.3, §8.3.
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

All Linear access goes through Symphony's injected `linear_graphql` tool (exposed as `mcp__symphony__linear_graphql`). Use it for every Linear read and write. Do **not** call `mcp__plugin_linear_linear__*` or any other "Linear MCP" plugin tools — they are not available in this session and will be denied; reaching for them only wastes a turn. If `linear_graphql` is not present, stop and ask the user to configure Linear. See the `linear` skill for query/mutation recipes.

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
- Never use `sleep` (or `ScheduleWakeup`) to wait for external state such as CI or a merge — see **Waiting and blocked**.

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

## Execution flow

For `Todo` (already moved to `In Progress`) or `In Progress`:

1. Open the workpad: search active/unresolved comments for `## Symphony Workpad`; reuse it if present, otherwise create exactly one. Persist its comment ID and write all progress only to that ID.
2. Reconcile before new edits: check off done items, expand/fix the plan for current scope, and confirm `Acceptance Criteria` and `Validation` still fit.
3. Write/refresh a hierarchical plan in the workpad, including:
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
9. Finalize the workpad: mark plan/acceptance/validation items checked; add handoff notes (commit + validation summary); keep the PR URL on the issue (attachment/link fields), not in the workpad; add a short `### Confusions` section only when something was genuinely unclear. Do not post a separate completion comment.
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

## Waiting and blocked

Waiting on CI or a review decision — **never block on it**:

- Local validation is your gate. Once the validation gate is green, the branch is pushed, the PR is linked and labelled `symphony`, and the workpad is finalized, move the issue to `Human Review` and end the turn.
- Do not wait on, watch, or re-poll remote CI from an active state — the one exception is `Merging` (see the last bullet). A single Bash call is killed at the 10-minute hard max, and ending the turn while the issue is still active triggers an immediate continuation relaunch that counts against the per-issue session budget — repeated CI waits self-escalate the issue. Neither is a valid way to wait.
- `Human Review` is not an active state: after handoff Symphony will not re-invoke you until a human moves the issue to `Merging` or `Rework`. There is nothing to poll, so do not `ScheduleWakeup`/`sleep` or hand-roll a wait loop.
- Remote CI is gated at merge: in `Merging` the `land` skill watches CI via `land_watch.py` and won't squash-merge until green. Watching CI is land's job, in `Merging` only.

Blocked-access escape hatch — only when completion is blocked by a missing required tool or auth/permission that cannot be resolved in-session:

- GitHub is **not** a valid blocker by default. Try fallback strategies first (alternate remote/auth mode, then continue the publish/review flow) and document them in the workpad before treating GitHub access as blocking.
- For a missing non-GitHub tool or unavailable non-GitHub auth, move the ticket to `Human Review` with a concise blocker brief in the workpad: what is missing, why it blocks required acceptance/validation, and the exact human action needed to unblock. Keep it in the workpad — no extra top-level comments. If no workpad exists yet, add a single blocker comment with the same content.

## Completion bar before Human Review

- The plan/acceptance/validation checklist in the single workpad comment is complete and accurate.
- Acceptance criteria and all ticket-provided validation items are done, and the local validation gate is green for the latest commit.
- The PR feedback sweep is complete with no actionable items remaining.
- The branch is pushed, the PR is linked on the issue, and it carries the `symphony` label.

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

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
