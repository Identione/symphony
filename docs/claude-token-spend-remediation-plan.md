# Symphony Claude-agent token-spend — remediation plan

_Plan date: 2026-06-16. Companion to [`claude-token-spend-analysis.md`](./claude-token-spend-analysis.md)
and [`claude-token-ledger.csv`](./claude-token-ledger.csv)._

This plan audits each lever the spend analysis proposed **against the current code**, records what
is already (partly) solved, corrects two inaccuracies in the analysis, and lays out a prioritized,
TDD-first fix list with `file:line` anchors.

---

## 1. Status check — analysis items vs. current code

Nothing in the analysis is **fully** fixed. Two items gained infrastructure since the analysis
window; the rest are untouched.

| # | Analysis item | Status | Evidence (current code) |
|---|---|---|---|
| 3a / **P0** | Model is Opus 4.7 (≈5× price) | ⚠️ **Partial — infra only** | `model_by_state`/`effort_by_state` added in `c5b8ba0` (`elixir/lib/symphony_elixir/config/schema.ex:339-340`; resolved at `elixir/lib/symphony_elixir/claude/app_server.ex:171-204`). Only **`merging → haiku`** is wired, in the single new `instances/entry-elixir-v1-app-v2/WORKFLOW.md`. The bulk Todo/In-Progress work — where ~all the spend is — runs on the **unset global model → SDK default → Opus**. `entry`/`symphony` set no model at all. |
| 3b / **P1** | No give-up / convergence cap | ⚠️ **Partial** | IDE-73/74 added deterministic-failure escalation: `max_turns_reached` is now a counted code (`elixir/lib/symphony_elixir/deterministic_failure.ex:62`), escalating to **Human Review** after 5 consecutive hits (`schema.ex:461-463`). Three structural holes remain — see §3, R1. |
| 3c / **P2** | Tool output not truncated | ❌ **Not solved** | `translate_symphony_tool_result` passes `output` verbatim (`elixir/priv/claude_agent/symphony_claude_agent/sidecar.py:241-249`). |
| 3d | No context compaction | ❌ **Not solved** | SDK payload still only carries `max_turns/max_budget_usd/model/effort` (`sidecar.py:306-345`); no compaction knob. |
| 3e / **P3** | `linear_graphql` pretty-printed JSON | ❌ **Not solved** | `Jason.encode!(payload, pretty: true)` unchanged (`elixir/lib/symphony_elixir/codex/dynamic_tool.ex:142`). |
| P4 | 1-hour prompt cache | ❌ **Not solved** (low priority) | No cache-control plumbing in the sidecar. |

---

## 2. Two corrections to the original analysis

While verifying, two points in the analysis turned out to be off, and they change the plan:

1. **P2's recommended location only fixes the small half.** `translate_symphony_tool_result` only
   handles `mcp__symphony__linear_graphql` results (~0.67M tok). `Read`/`Bash`/`Grep`/`Edit` are
   **SDK-native tools executed inside the sidecar's Claude SDK** — they never pass through that
   function (the sidecar only bridges `linear_graphql` via `forward_tool_call_to_symphony`). So
   capping there does **nothing** for the dominant `Read` (3.1M) + `Bash` (1.6M) cost. The real lever
   for those is a **`PostToolUse` hook** (the SDK supports `hooks` — `claude_agent_sdk/types.py:1753`;
   the sidecar currently passes none) and/or prompt steering.

2. **P1 is narrower than "no cap at all."** The analysis says `retry_policy.ex` "only escalates on
   repeated identical error codes." True — but `max_turns_reached` is now one of those codes (landed
   `2823d40`, 2026-06-10, mid-window). The *actual* remaining gaps are specific (§3).

---

## 3. The real P1 gaps (after IDE-73/74)

The deterministic-failure escalation **does** cap the "agent keeps hitting `max_turns`" case once
deployed. What it does **not** cover:

- **Normal exits reset the counter.** `elixir/lib/symphony_elixir/orchestrator.ex:274` calls
  `clear_deterministic_failure/1` on every `:normal` agent exit. An agent that voluntarily ends a
  turn ("I think I'm done") while the issue is still active wipes the counter and relaunches with a
  1s delay (`@continuation_retry_delay_ms`, `orchestrator.ex:14`). Any issue where the agent
  intermittently "finishes" but the work isn't actually accepted never accumulates toward escalation.
- **No cumulative cap.** There is no `max_sessions_per_issue` / cumulative-turn ceiling that is
  independent of "consecutive same error code."
- **`max_budget_usd` is inert as a stop — the breach is silently swallowed at the sidecar boundary.**
  It is a real per-**session** SDK cap (`claude_agent_sdk/types.py:1652`) but unset everywhere — and
  worse than "maps to `:unknown`," a breach **never reaches Elixir's error path at all**. The SDK
  *returns* (does not raise) a `ResultMessage(subtype="error_max_budget_usd", is_error=True)`, but the
  sidecar's `_forward_message` `ResultMessage` branch (`sidecar.py:527-537`) ignores `subtype`/`is_error`
  and emits a bare `turn_end`. Elixir handles `turn_end` as **success** (`app_server.ex:456-458`);
  `to_error_code/1` is only reached for `type: :error` envelopes (`app_server.ex:461-462`). So a budget
  breach arrives as a **clean turn completion** → `handle_agent_down(:normal)` →
  `clear_deterministic_failure` + 1s relaunch (`orchestrator.ex:267-284`): it both **relaunches and
  resets the streak**. Even if set, it would not halt. _(This is why R1(a) — a cap that doesn't depend
  on any error code — is the load-bearing guardrail; see R1(b).)_

> **Deploy-lag caveat (operator note, 2026-06-16):** the worst post-IDE-74 data point — IDE-163,
> 24 sessions / 1,123 turns on 2026-06-13 — has **two equally plausible explanations, and the data
> can't distinguish them**: (1) the daemon was still on an older build without the IDE-74 escalation
> (not redeployed after the 06-10 commit), or (2) it *was* on the latest build but hit the
> normal-exit-resets-the-streak gap above — a 24-session issue is fully consistent with the latest
> build if the agent intermittently exits `:normal` and never reaches 5 *consecutive*
> `max_turns_reached`. So IDE-163 may be live evidence **for** that gap, not merely a deploy artifact.
> The three gaps are real **in the committed code** regardless. A clean re-run on the latest build is
> the right way to tell (1) from (2) and to measure how much of the tail IDE-74 already removes before
> investing in R1.

---

## 4. Remediation plan (prioritized, TDD-first)

Per repo convention: write the reproducing/red test first, then the green fix.

### R0 — Move bulk work off Opus *(config only; biggest single lever, ~5×)*
- **Target the two live Claude instances by name:** `instances/symphony/WORKFLOW.md` (currently no
  model) and `instances/entry-elixir-v1-app-v2/WORKFLOW.md` (currently only `merging→haiku`).
  **`instances/entry` is the `codex` instance — irrelevant to Claude spend; don't touch it.** (The big
  historical `entry`-rooted spend came from a since-renamed `entry-product-spec` workspace no longer on
  disk.)
- In each, set under `agent.claude` an **explicit** global `model: claude-sonnet-4-6` (or a
  `model_by_state` covering `todo`/`in progress`/`rework`). **Pin it explicitly — do not rely on the
  unset-model → SDK default path:** when Symphony omits `model` the sidecar drops the key
  (`sidecar.py:325-326`) and the model silently tracks whatever the CLI ships, so the only way to both
  *choose* Sonnet and *hold* it is to name it. The resolution path is already covered by
  `claude_adapter_config_test.exs` — **no code change**.
- Pair with `effort_by_state` to drop review/merging states to `low`.
- Validate quality on a handful of issues. **Caveat on the evidence:** there is **no clean
  same-workload Sonnet datapoint** — the "~$7" figure is IDE-71's *Opus* tokens (ledger: `claude-opus-4-7`,
  $34.16) re-priced at Sonnet rates, not a measured Sonnet run; the only genuinely Sonnet rows
  (`old/5`, `old/9`) are trivially small ($0.31–$0.54). The case for R0 rests on the **rate card**
  (Opus list ≈ 5× Sonnet on every line that matters), which holds independently; the 5× edge survives
  unless Sonnet needs >5× the turns (unlikely).

### R1 — Real per-issue convergence cap *(code; structural fix, cuts the 53%-from-top-20 tail)*
- **(a) Cumulative, error-code-independent cap — must be restart-durable.**
  - _Red:_ three tests. **(1) Cap:** N continuation relaunches with the issue staying active → after
    the cap, escalate to `deterministic_failure_escalation_state` instead of relaunching. **(2)
    Restart:** rebuild `Orchestrator.State` from empty (simulated daemon restart) with the issue still
    active and at/over the cap → it still escalates rather than resetting to zero and re-running.
    **(3) Reopen (must NOT escalate):** an issue that previously hit the cap and was escalated, then
    legitimately re-enters an active state (human moves it back to `Todo`/`Rework`) → reconcile starts
    a **fresh** budget and runs, rather than immediately re-escalating off the stale count.
  - _Green:_ add `agent.max_sessions_per_issue` (or `max_cumulative_turns_per_issue`) to `schema.ex`
    (default ~8); increment on each continuation launch (`orchestrator.ex:267-284`); on breach, route
    through the existing escalation machinery rather than `schedule_issue_retry`. Reset (see semantics
    below) must update the **persistent** store in lockstep with the in-memory clear at claim release /
    terminal state (`orchestrator.ex:1742`) — never one without the other.
  - **⚠️ Durability — the key design constraint.** `Orchestrator.State` is a purely in-memory GenServer
    struct (`orchestrator.ex:39-73`); every counter (`retry_attempts`, `deterministic_failures`,
    `claimed`, …) starts empty on boot. A daemon **restart or `make upgrade` deploy resets the counter
    while Linear still has the issue active and retryable** — exactly the deploy-lag scenario from §3 —
    so a cap tracked *only* in `State` is silently defeated by the operational event most correlated
    with runaway spend. (This also already weakens the IDE-73/74 escalation: a restart mid-streak
    resets the consecutive-failure count.) The cap must therefore be **derivable from a persistent
    source on reconcile**, not just held in memory. Options, cheapest first: **(i)** a hidden counter
    line / failure-section count in the `## Symphony Workpad` comment — Linear is the source of truth the
    orchestrator already reads and writes (`Tracker.fetch_comments/1`, and the deterministic-failure
    handler already appends sections there); **(ii)** count the agent's SDK session transcripts under the
    workspace; **(iii)** an explicit attempt counter in a Linear custom field. Recommend (i): on claim,
    reconstruct the per-issue count from the workpad before deciding to relaunch, so the guardrail
    survives restarts/deploys.
  - **⚠️ Reset semantics — resolve before picking a store.** A persistent counter is only safe with a
    persistent *reset* rule; otherwise a stale count escalates a legitimate new run. **Open question to
    settle first: does the cap count _lifetime_ sessions on the issue, or sessions _since the last entry
    into an active state_?** This plan recommends the **latter (episode-scoped)**: an issue a human
    legitimately moves back to `Todo`/`Rework` after review is a *new* convergence attempt and deserves
    a fresh budget — a lifetime cap would permanently poison any issue that needs more than one
    human-review round-trip. (Note the Rework flow already treats re-entry as a full reset — it deletes
    the `## Symphony Workpad` and starts fresh, `WORKFLOW.md:411` — but that deletion is *agent* behavior
    and must not be relied on for the guardrail's reset.)
  - Implementation of episode semantics: persist `{generation, count}`, where `generation` advances each
    time the issue **(re)enters an active state from a non-active state**. On reconcile, if the stored
    `generation` ≠ the current episode's, treat `count` as 0. The natural place to stamp a new generation
    (and zero the count) is the **host-side `Todo → In Progress` move that R6 hoists into the
    orchestrator** — so R1(a) and R6 should land together, or R1 must add its own active-entry detection.
    Required persistent resets, all orchestrator-driven (never implicit on agent workpad lifecycle):
    on terminal state, on any transition **out** of an active state (incl. escalation to
    `deterministic_failure_escalation_state`), and on fresh **re-entry** into an active state.
- **(b) Make `max_budget_usd` actually halt — fix at the sidecar, not `to_error_code`.**
  ⚠️ **The breach is discarded at the sidecar boundary** (see §3): the SDK returns a
  `ResultMessage(subtype="error_max_budget_usd", is_error=True)`, but `_forward_message` emits a bare
  `turn_end` that Elixir treats as success. `to_error_code/1` is **never called** with that string, so
  a `to_error_code`-only red/green would **pass while production keeps relaunching forever**. Detect it
  where the signal exists.
  - _Red (sidecar-level, the load-bearing test):_ a `ResultMessage(subtype="error_max_budget_usd",
    is_error=True)` makes `_forward_message` emit a `type: error` envelope (`error_code:
    "budget_exhausted"`), **not** a `turn_end`.
  - _Green:_ in the `ResultMessage` branch (`sidecar.py:527-537`), inspect `subtype`/`is_error` and emit
    the error envelope on a budget breach; **then** add `to_error_code("error_max_budget_usd") ->
    :budget_exhausted` (`app_server.ex:515-520`), add `:budget_exhausted` to
    `DeterministicFailure.@deterministic_codes` + `RetryPolicy` `:no_retry`, and set a default
    `max_budget_usd` in the two Claude instance configs.
  - _Pattern to copy:_ `max_turns` halts reliably **because it's detected Elixir-side** by counting
    turns (`agent_runner.ex:345-351` → `exit({:agent_run_failed, :max_turns_reached, …})` at `:30`),
    never trusting an SDK subtype. Budget needs the same "detect where you control the signal" discipline.
  - **R1(a) is the primary guardrail, R1(b) is a refinement.** Because a budget breach is
    *indistinguishable from a clean finish* at the Elixir layer until this sidecar fix lands, **any
    error-code-keyed cap (including R1(b)) misses it.** The cumulative, code-independent cap R1(a) is
    the robust stop and should not wait on R1(b).
- **(c) Optional non-progress detection** (no workspace diff / no Linear state change across K
  sessions → escalate). Heavier; phase 2, largely redundant once (a) lands.

### R2 — Cap tool output entering context *(cuts `cache_read`, the 49% line)*
- **(a) Cheap & immediate — prompt steering:** in the `WORKFLOW.md` body, steer the agent toward
  `Read` with `offset/limit`, `Grep` over full-file dumps, and not re-reading files already in
  context.
- **(b) High-value — `PostToolUse` truncation hook:**
  - _Red:_ sidecar test (`elixir/priv/claude_agent/tests/`) asserting a >cap `Read`/`Bash` result is
    elided head+tail with a marker.
  - _Green:_ register a `PostToolUse` hook in the `ClaudeAgentOptions` payload (`sidecar.py:306-345`)
    that caps large native-tool results (e.g. 8KB). This is the **only** way to touch the 4.7M-token
    `Read`+`Bash` cost.
- **(c) `linear_graphql` cap:** same head+tail cap in `translate_symphony_tool_result`
  (`sidecar.py:241-249`), distinct from the log-only `fold_text`.

### R3 — Slim `linear_graphql` *(small, trivial)*
- _Red:_ `dynamic_tool` test asserting compact encoding.
- _Green:_ drop `pretty: true` at `dynamic_tool.ex:142`. Field projection is a later refinement.

### R4 / R5 — Compaction & 1h cache *(defer)*
- With `max_turns=20`, in-session history is already short; the win is cross-session, and R1 cuts
  session count directly. Revisit after R0–R3. 1h cache stays unjustified (the 1s relaunch keeps the
  prefix warm; the 32:1 read:write ratio is healthy). Note: extended thinking is off and there is no
  `max_thinking_tokens` plumbing — adding it (`sidecar.py`, SDK field `types.py:1838`) would enable a
  Sonnet+thinking A/B once R0 lands.

---

## 5. Suggested order

**R0** (today, ~5×) → **R3 + R2a/c** (cheap) → **R1** (the tail) → **R2b** (the big context lever).
Before investing in R1, re-run a few issues on the **latest deployed build** to measure how much of
the tail IDE-74 already removes (see the deploy-lag caveat in §3).

---

## 6. Additional levers reviewed (2026-06-16)

A second batch of ideas, audited against current code. **Stale-reference note:** the proposals cited
`instances/entry/WORKFLOW.md:146-197/240-242/281`, but that instance is the 82-line **codex** workflow.
The real prompt content lives in `elixir/WORKFLOW.md` (482 lines, the canonical claude example); line
anchors below are corrected to it. Likewise `app_server.ex:413-417` is the sidecar-exit handler, not
tool dispatch — the real path is `dispatch_tool_call/3` at `app_server.ex:522`.

| # | Idea | Verdict | Evidence / correction |
|---|---|---|---|
| 1 | Native Elixir merge worker for `Merging` | ✅ valid, high-value | `land` loop is model-driven (`elixir/WORKFLOW.md:255,264,278,403`). Partly mitigated by `model_by_state: merging→haiku low` (`instances/entry-elixir-v1-app-v2/WORKFLOW.md:72`); a native worker removes the agent session entirely for clean merges. |
| 2 | Move Linear bootstrap host-side | ✅ valid, high-value | Bootstrap = `WORKFLOW.md` Step 0–1 (`268-319`). Orchestrator already has state pre-dispatch + does state moves (`DeterministicFailure.move_issue`→`Tracker.update_issue_state`); `Tracker.fetch_comments/1` exists. Hits every session's first turns. |
| 3 | State-specific prompt rendering | ✅ valid, easy | `build_prompt/2` renders the full template every time (`prompt_builder.ex:11-27`). **Route-branching on `issue.state` alone is template-only** (it's already in the Liquid context). **But the R6 injected facts are not** — see the strict-variables caveat below. |
| 4 | Remove/gate `/simplify` | ✅ **already done** | `WORKFLOW.md:362-364` (commit `7a08e43`) gates `/code-review low` on diff size and explicitly avoids `/simplify`; small diffs skip review. No instance mentions `/simplify`. |
| 5 | Per-session tool budgets + repetition detection | ⚠️ valid, split | Real dispatch `app_server.ex:522`; only `linear_graphql` routes through it. `Bash`/`Read` byte caps are SDK-native → must live in the R2b PostToolUse hook. |
| 6 | Cache identical `linear_graphql` per session | ✅ valid, with caveat | `DynamicTool.execute/3` is stateless (`dynamic_tool.ex:29-43`). **Cache read queries only; invalidate on any mutation** or stale Linear state breaks workpad reconciliation. |
| 7 | Host-side "dispatch facts" block | ✅ valid | Same theme as #2/#8. Inject read-only snapshot facts (HEAD/branch/`git status`/PR-exists); leave stateful actions (pull, conflict resolve) to the agent. |
| 8 | Continuation prompt = host progress digest | ✅ valid | `agent_runner.ex:363-373` (within-session) + `WORKFLOW.md:194-201` (cross-session `attempt` block) both just say "resume". Highest value on the cross-session relaunch. |

These collapse into three workstreams (plus #4, done):

### R6 — Host-side context injection *(#2 + #3 + #7 + #8; cuts turn count + first-turn surface)*
Precompute deterministic state host-side and stop paying the agent to rediscover it each session.
- _Red:_ `PromptBuilder` test asserting injected fields render; `agent_runner` test asserting the
  continuation `attempt` block carries the digest.
- _Green:_ orchestrator performs the `Todo → In Progress` move and fetches the workpad comment
  (`Tracker.update_issue_state`, `Tracker.fetch_comments/1`) before dispatch; pass compact fields
  (`current_state`, `workpad_comment_id`, `workpad_excerpt`, `existing_pr_url`,
  `unresolved_feedback_count`, plus a repo snapshot: HEAD/branch/`git status --short`) into
  `build_prompt/2` opts (`prompt_builder.ex:11-27`); thread `workspace_path` + last-stop-reason into
  the continuation digest (`agent_runner.ex:363-373`). In `WORKFLOW.md`, branch Step 0/routes on
  `issue.state` so only the relevant route + shared guardrails render. Keep the agent owning workpad
  *content* reconciliation; only the create/find/state-move is hoisted.
  - **⚠️ strict-variables caveat.** `build_prompt/2` renders with `@render_opts [strict_variables: true,
    strict_filters: true]` (`prompt_builder.ex:8`) and today exposes **only** `agent`, `attempt`, and
    `issue` (`prompt_builder.ex:17-25`). Under `strict_variables`, a template that references
    `current_state`, `existing_pr_url`, `workpad_comment_id`, etc. **raises at render time** until those
    keys are added to the render map. So: route-branching on `issue.state` is a pure template edit, but
    every injected fact requires a `PromptBuilder` code change first (extend the render map, and decide
    whether absent facts render as explicit empties vs. omitted blocks to stay strict-safe). Don't ship
    the template edits ahead of the code.
- Risk: injected facts are a dispatch-time snapshot — label them so; keep the "state vs content
  inconsistent" self-check (`WORKFLOW.md:288`).

### R7 — Per-session tool governor *(#5 + #6; fires before the R1 per-issue cap)*
One per-session state object captured in the `tool_executor` closure (`app_server.ex:82-84`).
- _Red:_ `DynamicTool`/app_server tests — Nth identical `{query,variables}` served from cache; over-budget
  call returns a concise tool error ("summarize progress and escalate"); a mutation busts the cache.
- _Green:_ add per-session counters (max Linear calls, max repeated-identical query) + a read-only
  `{query,variables}` memo with mutation-triggered invalidation, plumbed through `DynamicTool.execute/3`
  (`dynamic_tool.ex:29-43`). The `Bash`/`Read` byte budgets ride on the R2b hook.

### R8 — Native merge worker for `Merging` *(#1; removes whole sessions)*
- _Red:_ orchestrator/worker test — an issue entering `Merging` with a green, conflict-free PR is
  squash-merged and moved to `Done` without launching an agent; a conflict/ambiguous-review case falls
  back to the agent `land` flow.
- _Green:_ Elixir merge worker (find PR, poll checks, squash-merge via `gh`/API, move to `Done`),
  gated to clean cases; Claude invoked only on real conflicts or ambiguous review state. Reuses the
  existing GitHub credential-helper preflight.
- Risk: branch-protection / required-review nuances — the fallback-to-agent path is mandatory.

### Suggested placement
R6 and R7 are cheap-to-moderate and compound with R2; slot them after R2a/c and before/alongside R1.
R8 is a larger build — schedule after R0–R3 prove out, since `model_by_state: merging→haiku` already
blunts merge-session cost in the interim.
