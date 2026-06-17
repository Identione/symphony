# Symphony Claude-agent token-spend — execution fix plan

_Plan date: 2026-06-17. Grounded in a direct analysis of the live SDK transcripts on
`slimshady.tonka.se:~/.jai/default.changes/.claude-identione/projects/` (1,114 sessions, 471 MB)
plus the installed `claude-agent-sdk` source. Companion to
[`claude-token-spend-analysis.md`](./claude-token-spend-analysis.md),
[`claude-token-spend-remediation-plan.md`](./claude-token-spend-remediation-plan.md), and
[`claude-token-ledger.csv`](./claude-token-ledger.csv)._

This is the **actionable** plan: what to build, in what order, red→green per repo convention, with
`file:line` anchors. It supersedes the earlier remediation plan's Fix-1/Fix-2 *mechanisms* where the
production data proved a better signal exists.

---

## 0. What the production data proved

| Mode | Evidence (transcripts) | Magnitude (operator table) | Status |
|---|---|---|---|
| **Rate-limit masquerade** | 274/517 issue sessions carry top-level `error:"rate_limit"`, `isApiErrorMessage:true`, `stop_reason:"stop_sequence"`, text `"You've hit your limit · resets 11:20am (Europe/Stockholm)"`. Sessions repeatedly burn **exactly 20** rate-limit turns (= `agent.max_turns`). | 29% of all assistant turns are in rate-limited sessions; 67–83% on the worst tickets (IDE-136 83%, IDE-163 80%, IDE-164 67%) | **Open — P0** |
| **Blocked parent-tracker re-dispatch** | IDE-132 is a true sub-issue parent (`children{nodes}` queries; workpad: *"parent tracker for the seven-PR refactor"*). 18 sessions × ~20 poll-only continuation turns, relaunched retry #1…#7. | 62% of IDE-132's 1,467 turns | **Largely fixed in code (189677e); deploy-lag. Verify + harden** |
| **General no-progress / streak defeat** | 9/18 IDE-132 sessions interleave rate-limits, which reset the IDE-74 `max_turns_reached` streak so escalation never trips. | the long tail | **Open — P1** |

**Provenance.** These shares are now a rerunnable artifact, not an ad-hoc scan:
[`scripts/scan_token_waste.py`](../scripts/scan_token_waste.py) →
[`claude-token-waste-by-issue.csv`](./claude-token-waste-by-issue.csv) (run 2026-06-17, 517 issue
sessions / 26,802 assistant turns). It reports two measures: a mechanical floor (`ratelimit_share` =
literal limit-hit records ÷ turns; 17% overall) and session-level attribution (`rl_session_share` =
turns in any rate-limited session ÷ turns; 29% overall) — the latter reproduces the operator table to
the point (IDE-163 0.799, IDE-164 0.672, IDE-162 0.533, IDE-161 0.432). It also surfaced **IDE-136**
(58 sessions, 83% session-level waste), the single biggest rate-limit waster and absent from the
operator table. The scan measures *rate-limit* waste only; blocked-retry waste (IDE-132) needs a
separate poll-only/no-diff heuristic and is not in this CSV.

**Key coupling insight:** the rate-limit masquerade isn't only its own waste — because it currently
surfaces as a *clean turn*, it resets the deterministic-failure streak (`orchestrator.ex:267-284` →
`clear_deterministic_failure/1`) and defeats the IDE-74 guard that should stop blocked loops. Fixing
P0 also un-breaks P1's existing escalation.

### Deployed-version finding (2026-06-17)

The orchestrator runs on `slimshady.tonka.se` from `~/stash.tail-f.com/identione/symphony`, deployed
HEAD **`836634d` (2026-06-12 11:02)**, escript built 06-12 11:26 — a clean **5 commits behind** main
(`fe409b8`; fast-forward). The deployed build **already contains** the parent guard (189677e), IDE-74,
and `deterministic_failure.ex`. It is **missing**: `531cb65` provider-quota-aware dispatch pausing
(#58), `c5b8ba0` per-state model/effort overrides (R0 lever), `7a08e43` review-gating. This splits the
two waste modes cleanly by date:

- **IDE-132 (06-10/11) — deploy-lag, now fixed.** Ran *before* the 06-12 build, so on a pre-guard
  binary. Today's build won't re-dispatch it.
- **IDE-163 (06-13, 80% rate-limit) — NOT deploy-lag.** Ran on a build that *has* the guard + IDE-74
  and still wasted 80% on rate-limits. This is hard proof that **P0 is real and unfixed by anything
  that has landed** — the dispatch-level mitigations don't stop a running session's wall-march.

### Turn-level model (so the fixes target the right layer)

```
Level 3  Orchestrator relaunches (sessions)   IDE-132:18 IDE-163:24   — capped by: NOTHING today
Level 2  Symphony continuation turns/session  cap = agent.max_turns = 20 (schema.ex:451)
Level 1  Claude SDK model turns/continuation  cap = agent.claude.max_turns = UNSET (schema.ex:327)
```
44–81 model turns/session ÷ 20 continuations ≈ 2–4 SDK turns each → Level 1 is unbounded. Raising
`agent.max_turns` (the rejected "150" idea) makes Level 2 *worse* (a rate-limited session would burn
150 wall-hits instead of 20). The real brakes are at Level 1/2 (P0) and Level 3 (P1).

---

## Step 0 — Deploy current main + enable quota pausing *(no new code; do first)*

Two near-zero-effort wins that are already built but not live:

1. **Deploy `fe409b8` to slimshady and restart the daemon.** Clean fast-forward from the deployed
   `836634d`. Picks up #58 (quota pausing), per-state model/effort overrides (R0), and review-gating.
   Confirms the parent guard is actually *running* (the 06-12 checkout has it; verify the daemon was
   restarted onto a build that includes it).
2. **Enable provider-quota dispatch pausing.** It is preventive and already written, but
   `agent.claude.quota.enabled` defaults to **false** (`schema.ex:187`) and is commented out in
   `WORKFLOW.md:144-160`. Set in the live instance:
   ```yaml
   agent:
     claude:
       quota:
         enabled: true
         dispatch_pause_percent: 95.0
         refresh_ms: 60000
         token_source: claude_cli_refresh   # keeps the OAuth token fresh on an idle daemon
   ```
   This stops *new* dispatches once any usage window ≥ 95% (running agents continue). It is the
   **preventive** Level-3 layer; it does **not** replace P0 (a session already running still marches
   into the wall, and the 95% threshold + a stale endpoint leave a gap). P0 is the reactive backstop;
   the two compose.

3. **Re-run the measurement (baseline already committed).** The pre-deploy baseline is captured —
   [`scripts/scan_token_waste.py`](../scripts/scan_token_waste.py) →
   [`claude-token-waste-by-issue.csv`](./claude-token-waste-by-issue.csv) (2026-06-17). Re-run it after
   the deploy (`ssh slimshady.tonka.se 'python3 -' < scripts/scan_token_waste.py`) and diff against the
   baseline to measure what Step 0 actually reclaimed before committing the ~1 day to P0.

Re-measure after Step 0 before sizing the rest — it may erase the parent-tracker tail entirely and
blunt the rate-limit storms.

---

## P0 — Classify the rate-limit masquerade at the sidecar *(biggest lever; ~1 day)*

**Root cause.** The Claude subscription usage-limit is **not raised as an exception** — the SDK
delivers it as an `AssistantMessage` whose `error` field is set. The parser maps the transcript's
top-level `error:"rate_limit"` onto `AssistantMessage.error`
(`.venv/.../claude_agent_sdk/_internal/message_parser.py:176`; field declared at
`types.py:1029`, enum `AssistantMessageError` at `types.py:1002`). The sidecar's `AssistantMessage`
branch (`sidecar.py:584-603`) renders text + usage and **discards `.error`**, then a normal
`turn_end` follows. Elixir treats `turn_end` as success (`app_server.ex:456-459`); the
`to_error_code("rate_limited")` path only fires for `type:error` envelopes (`app_server.ex:461-463`).
Net: clean turn → continuation loop re-prompts (blind to `stop_reason`) up to 20× → `:max_turns_reached`
→ 1 s relaunch → repeat for the whole multi-hour window.

> Implement with the structured `AssistantMessage.error`, **not** a text regex over forwarded prose:
> the enum field is version-stable and lives in the sidecar — the same "detect where you control the
> signal" discipline as the in-tree `max_budget_usd` work (`test_forward_message_budget.py`, currently
> staged). `RateLimitEvent`/`RateLimitInfo.resets_at` (`types.py:1186-1222`) is a richer signal but
> appears in only 2/1,114 transcripts, so it's secondary. _(Earlier conversation floated an Elixir-side
> prose regex, raising `agent.max_turns` to 150, and a new `:claude_rate_limited` code — all rejected
> here for the reasons inline. They were discussion options, not prior committed designs.)_

### P0.1 — Sidecar: emit a structured error on `AssistantMessage.error`
Emit the **raw SDK literal** as `error_code` and do all atom mapping in Elixir `to_error_code` — the
same split as the budget path (sidecar emits `error_max_budget_usd`; the atom mapping lives only in
`to_error_code`). Keeps the error vocabulary in one language.
- _Green_ (`sidecar.py:584-603`): before rendering text, check `getattr(message, "error", None)`; if
  set, emit `{"type":"error","error_code": <raw literal>, "error": <prose>, "session_id": …}` and
  return (suppress the plain `assistant_message`). Pass the literal verbatim — `"rate_limit"`,
  `"billing_error"`, `"server_error"`, `"authentication_failed"`, `"invalid_request"`.
- _Red_ (`elixir/priv/claude_agent/tests/test_forward_message_rate_limit.py`, mirroring
  `test_forward_message_budget.py`): for a **single** `AssistantMessage(error="rate_limit",
  stop_reason="stop_sequence", content=[text "You've hit your limit · resets 11:20am (Europe/Stockholm)"])`,
  `_forward_message` emits one `{"type":"error","error_code":"rate_limit", …}` and **no**
  `assistant_message`. Assert at the **message** level (error emitted, assistant_message suppressed) —
  do **not** copy the budget test's `not any(turn_end)`: at the *session* level the SDK still yields a
  trailing `ResultMessage`/`turn_end` after the error message (harmless — `app_server.ex:461-463` reads
  the error first and tears the session down). Control case: `error=None` → normal `assistant_message`.

### P0.2 — Sidecar: compute the reset delay (avoid Elixir timezone math)
- _Red_: the reset text `"resets 11:20am (Europe/Stockholm)"` is parsed to seconds-from-now; an
  unparseable/absent reset omits the hint rather than guessing.
- _Green_: parse `~r/resets\s+(\d{1,2}:\d{2})\s*([ap]m)\s*\(([^)]+)\)/i` with `zoneinfo` to the next
  future occurrence of that wall-clock time in that tz. Embed it **inside the `error` string as
  `"retry-after <seconds>"`** so the *existing* Elixir parser picks it up with no wire-schema change
  (`agent_runner.ex:80` matches `retry[\s_-]?after[^\d]{0,8}(\d+)`). _(Optional later: a first-class
  `retry_after_ms` envelope field + a `Wire`/`AppServer` pass-through.)_

### P0.3 — Elixir: map the literals and honor a long reset
- _Green_ (`app_server.ex:515-524`): add `to_error_code` clauses for the **raw literals** —
  `"rate_limit" → :rate_limited`, `"billing_error" → :quota_exceeded`, `"server_error" → :overloaded`,
  `"authentication_failed" → :invalid_request`. (`:invalid_request` is no-retry +
  deterministic-escalate — the right posture for an auth/config failure; a dedicated `:auth_failed`
  would only help dashboards.) The existing `"rate_limited"`/`"overloaded"` clauses stay (they serve
  envelopes that already carry a mapped code).
- `classify_error_code` already passes the atom through (`agent_runner.ex:52`); `extract_retry_after_ms`
  already parses the embedded `retry-after` (`agent_runner.ex:67-90`); the orchestrator already wires
  both into `RetryPolicy.decide` (`orchestrator.ex:316-319`). **The one real gap:** `RetryPolicy` caps
  `:rate_limited` honor-retry-after at `max(cap, 900_000)` = 15 min (`retry_policy.ex:93-94`) — a
  multi-hour window would retry after 15 min and re-hit the wall.
  - _Green_: **split `:rate_limited` out of the shared `rate_limited`/`overloaded` clause**
    (`retry_policy.ex:93-94`). Give `:rate_limited` `max_ms: 6 * 3_600_000` (honoring the real reset);
    **leave `:overloaded` on the current short cap** — a transient 503's `retry-after` is seconds, and
    a 6 h ceiling there would let a malformed hint strand an issue for hours. Keep `:rate_limited`
    **transient** in `DeterministicFailure` (`deterministic_failure.ex:26-30`).
  - _Red_ — **two** assertions change, not one new test:
    - **Update** the existing `orchestrator_retry_policy_test.exs:76`
      `{:retry, 900_000} = decide(:rate_limited, 1, 5_000_000, settings)` → `{:retry, 5_000_000}`.
    - **Keep** the `:overloaded` assertions (`:188-190`) green — proves the split didn't widen the 503 cap.

### P0.4 — Config belt: bound the still-unbounded Level-1 *(config only)*
P0 brakes Level-1 only for rate-limits. A non-rate-limit within-query tool runaway is bounded only by
`max_budget_usd` (unset by default) and, later, P1's *session* cap (which counts sessions, not
within-session turns). Set a ceiling well above the typical 2–4: default `agent.claude.max_turns ≈ 40`
(`schema.ex:327` / the two Claude instance `WORKFLOW.md`s). Tradeoff: too low truncates legitimate long
turns; 40 sits comfortably above observed norms. If you'd rather rely solely on `max_budget_usd`, make
that an explicit decision and set a default cap there instead.

_(Dropped from an earlier draft: a "stop the session on any `stop_sequence` turn-end" guard. It needs
new `stop_reason` plumbing into `handle_turn_continuation`, P0.1 already fires first (the
`AssistantMessage(error)` precedes the `ResultMessage`), and a blanket rule would false-stop any
legitimately configured stop sequence.)_

**Exit criteria:** a rate-limited session produces **one** `rate_limited` failure that backs off to
the reset time, instead of 20 wall-hits × N relaunches.

---

## P1 — Cumulative, restart-durable per-issue cap (R1(a)) *(the durable backstop; ~2–3 days)*

This is the only Level-3 brake and the failure-mode-agnostic guardrail. It catches everything the
parent guard and error-code streaks miss: relation-only trackers, intermittent `:normal` finishes,
and rate-limit-reset streaks. Full design is in the remediation plan §R1(a); restated here as the
build.

**Root cause.** `Orchestrator.State` is in-memory only (`orchestrator.ex:39-73`); a restart/`make
upgrade` resets every counter while Linear still has the issue active — the operational event most
correlated with runaway spend. `:normal` exits also clear the streak (`orchestrator.ex:274`).

- _Red_ — three tests (`orchestrator_*_test.exs`):
  1. **Cap:** N continuation relaunches with the issue staying active → after the cap, escalate via
     the existing `DeterministicFailure` machinery instead of `schedule_issue_retry`.
  2. **Restart-durable:** rebuild `State` from empty with the issue still active and at/over the cap
     → still escalates (not reset to zero).
  3. **Episode reset:** an escalated issue a human moves back to `Todo`/`Rework` → fresh budget, runs
     again (does not immediately re-escalate off the stale count).
- _Green_:
  - Add `agent.max_sessions_per_issue` to `schema.ex` (default ~8).
  - Increment per continuation/relaunch at the dispatch/`:normal`-down sites (`orchestrator.ex:267-284`).
  - On breach, route through `DeterministicFailure` escalation, not retry.
  - **Durability — local store, not Linear.** Persist to a **local** keyed-by-issue store: DETS (or a
    small file) under `instances/<name>/run/`. `run/` survives a daemon restart and `make upgrade`
    (only `make clean` or a host migration wipes it — and on host migration the workspace is gone too,
    so the episode is moot). That satisfies the only stated requirement ("survive restart / `make
    upgrade`") without the read-modify-write race across poll cycles, brittle parsing, human-visible
    noise, and per-session Linear write that a `## Symphony Workpad` sentinel counter would incur. Keep
    Linear reconstruction (`Tracker.fetch_comments/1`) as an *optional host-migration-only fallback*,
    not the primary mechanism. Persist and clear in lockstep with the in-memory state at
    terminal/claim-release (`orchestrator.ex:~1742`).
  - **Episode semantics:** persist `{generation, count}`; advance `generation` on every (re)entry to
    an active state from a non-active state; on reconcile, a stale generation means `count = 0`.
    Reset on terminal state, on any transition *out* of active, and on fresh re-entry.

---

## P2 — Parent-tracker: verify the deploy, then close the residual edges *(small)*

The common case is **already fixed**: commit **189677e** (2026-06-10 23:49) added
`parent_issue?`/`has_children` so umbrella issues are never dispatch-eligible
(`orchestrator.ex:1342,1353`, evaluated every poll). IDE-132 is exactly that case; its waste is
**deploy-lag** (sessions 06-10/06-11 coincide with the guard landing).

### P2.0 — Verify (folded into Step 0)
The deployed checkout (`836634d`) already contains the guard, so the action is just **restart the
daemon onto it (Step 0) and re-measure** a few parent trackers. The 62% blocked tail (IDE-132) was a
pre-06-12 build artifact and should not recur. If it does, the daemon was not actually restarted onto
the new build — check before writing P2.1.

### P2.1 — Extend the guard to relation-only trackers
The guard keys on `has_children` (Linear sub-issues). A coordinator linked via `blockedBy`/`related`
has `has_children=false` → still dispatch-eligible → still loops.
- _Red_ (`orchestrator` dispatch test): an active issue with open `blocks`/`related` dependents and no
  own scope is not dispatched.
- _Green_: broaden `candidate_issue?` (`orchestrator.ex:1329-1345`) — or rely on P1's cap as the
  generic catch. Prefer P1 as the robust answer; P2.1 only if relation-trackers are common.

### P2.2 — Parent → Done ownership
Now that agents never touch parents, nothing moves a parent to terminal when its last child finishes.
- _Red_: all children terminal → parent moved to terminal by the host.
- _Green_: a lightweight host-side reconciler in `reconcile_*` that closes a parent when every child
  is terminal. Small, removes a class of "stuck active" parents.

### P2.3 — Branch (don't trim) the continuation contract in WORKFLOW.md
`WORKFLOW.md:202` (*"Do not end the turn while the issue remains in an active state unless… blocked"*)
is the **general Level-2 driver for every issue** — it's why sessions burn all 20 continuation turns —
not parent-specific prose. So **branch** it, don't trim: parents/relation-trackers get a "you don't own
this work, stop" instruction, while the general directive stays intact for normal work issues (removing
it outright would change behavior for all issues).

---

## P3 — Context/output levers (carried from remediation plan, unchanged) *(after P0–P2)*

- **R2b PostToolUse truncation hook** — the only lever on the dominant `Read`(3.1M)+`Bash`(1.6M)
  native-tool `cache_read` cost; the sidecar registers no hooks today (`sidecar.py` init payload).
- **R0 model_by_state / effort_by_state** — keep Opus on planning; push mechanical states
  (`merging→haiku low`) cheaper. Config-only.
- **R6/R7/R8** — host-side context injection, per-session tool governor, native merge worker. See
  remediation plan §6.

---

## Sequence & measurement

1. **Step 0 — deploy main + enable quota pausing** (hours, no code) — reclaims the parent tail for
   free and adds the preventive rate-limit layer. Re-measure.
2. **P0 rate-limit sidecar fix** (≈1 day) — biggest reactive lever; IDE-163 proves it's needed even
   on a current build; also un-breaks IDE-74 escalation.
3. **P1 cumulative cap** (2–3 days) — durable backstop for everything else.
4. **P2.1–P2.3** harden parent edges (only if Step 0 re-measure still shows parent waste).
5. **P3** context/output levers.

After P0+P2.0, **recompute `claude-token-ledger.csv`** weighted by tokens/$ (not turn-count) — a
rate-limit turn is cheap on output but still pays `cache_read` on the resumed context, so the $-split
differs from the turn-count table. The recomputed ledger decides how hard to push P3.

## Test/quality gate

Per repo convention every change is red→green; sidecar tests under
`elixir/priv/claude_agent/tests/`, Elixir under `elixir/test/...`. Before handoff:
`cd elixir && make all` (setup → build → fmt-check → lint → coverage → dialyzer). Update `SPEC.md`
(§10.8 wire vocabulary if a new envelope field is added), `elixir/docs/token_exhaustion.md`, and the
two Claude instance `WORKFLOW.md`s where config defaults change.
