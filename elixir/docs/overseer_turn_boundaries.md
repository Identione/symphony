# Turn-Cap Soft-Landing & Overseer Boundaries

How Symphony decides when a coding-agent turn should *stop and be judged* rather
than *crash the run* — what was broken, what shipped, and where it is going.

Related: [progress_signals.md](progress_signals.md) (Layer-1 deterministic
check), [token_exhaustion.md](token_exhaustion.md) (cost-side robustness),
SPEC §13.6 (the Layer-2 overseer). Lineage: IDE-198 (the failing issue that
surfaced this), IDE-230 (overseer), IDE-73/74 (deterministic-failure pipeline).

## TL;DR

A within-query turn-cap breach used to **crash the run and bypass the overseer**,
feeding a blind retry loop. It is now **soft-landed as a clean continuation
boundary the overseer judges** (when the overseer is active). This is the first
step toward a model where the cap is only a backstop and Symphony interrupts on
its own read of progress, cost, and time.

---

## 1. The problem

### 1.1 Three different things called "max turns"

The single biggest source of confusion. They live at different granularities and
are easy to conflate:

| Name | Default | Scope | Owner |
|---|---|---|---|
| `agent.claude.max_turns` | 100 | model↔tool cycles **inside one** SDK `query()` | Claude SDK (`--max-turns`) |
| `agent.max_turns` | 20 | Symphony **continuations** (re-prompts), legacy budget | Symphony |
| `agent.overseer.absolute_max_turns` | 500 | Symphony **continuations**, overseer budget | Symphony |

Two turn *types*, nested — never parallel:

- **Agent-driven (inner) turns** — model↔tool cycles within one SDK `query()`
  (Claude) or one `turn/start` (Codex). Counted by the adapter.
- **Symphony turns (continuations)** — Symphony re-prompts the same session after
  a turn ends. Counted by `AgentRunner` (`turn_number`).

A Symphony continuation *contains* a burst of inner turns; the overseer budget
(`absolute_max_turns`) is on the **outer** axis, while the cost actually accrues
on the **inner** axis.

### 1.2 The structural bypass

The continuation loop (`AgentRunner.do_run_codex_turns/5`) drove the turn through
`adapter.run_turn/4` and only ran the overseer (`handle_turn_continuation/4` →
`extend_with_overseer/4`) on a **clean** `{:ok, turn_session}` return. Any
mid-turn adapter error short-circuited *before* the overseer:

```
adapter.run_turn -> {:error, …}  ──►  run fails  ──►  blind retry loop
                                      (overseer never consulted)
adapter.run_turn -> {:ok, …}     ──►  handle_turn_continuation -> overseer
```

So the two failure signals that *should* be budget decisions were instead
run-ending crashes:

- **`:max_turns_reached`** — the Claude SDK's `error_max_turns` (a within-`query()`
  cap breach), mapped by `Claude.AppServer.to_error_code/1`.
- **`:turn_timeout`** — the Symphony-side wall-clock guard in the adapter reader
  (`Claude.AppServer` `collect_until_terminal`, `Codex.AppServer` `receive_loop`).

### 1.3 The per-adapter asymmetry

The inner loop is bounded differently per adapter:

- **Claude** has a turn-*count* cap (`agent.claude.max_turns` → SDK `--max-turns`).
  A breach returns a **ResultMessage** — the session is **idle and resumable**.
- **Codex** has **no count cap at all** (no `agent.codex.max_turns`; `turn/start`
  sends no iteration limit). Its only bound is the Symphony-side wall-clock
  `agent.codex.turn_timeout_ms`.

Note the wall-clock bound (`turn_timeout_ms`) is **Symphony's, not the agent's** —
and it already exists identically for *both* adapters. It does **not** make the
agent give up; it makes Symphony **stop listening** while the underlying turn
keeps running.

### 1.4 What this did to IDE-198

The agent made real progress on a doc-metamodel change but could not clear the
interlocking validation gates within 40 inner turns. Every session therefore hit
`error_max_turns`, which bypassed the overseer and fed the blind retry loop —
which then collided overnight with a shared-account rate-limit storm and a
leaked-slot deadlock. The overseer, whose entire job is to notice
"busy-but-doomed" and escalate, **never got to run**.

---

## 2. What shipped

`AgentRunner.do_run_codex_turns/5` now matches the Claude inner-cap breach and
routes it into the **same continuation/judge path as a clean `turn_end`**:

```elixir
case adapter.run_turn(...) do
  {:ok, turn_session} ->
    handle_turn_continuation(context, app_session, issue, turn_number)

  # IDE-230: a within-query cap breach is a cadence boundary, not a crash.
  {:error, {:claude_sdk_error, :max_turns_reached, _msg}} = result ->
    if is_pid(context.overseer_session) do
      handle_turn_continuation(context, app_session, issue, turn_number)  # overseer judges
    else
      result                                                              # legacy fail-fast
    end

  other ->
    other
end
```

Three deliberate properties:

1. **Safe to resume.** The SDK *returns* a ResultMessage on `error_max_turns`, so
   the session is idle and the persistent sidecar client still holds the
   conversation. Handing it to `extend_with_overseer/4` and re-prompting resumes
   in place; the extension is bounded by `overseer.absolute_max_turns`.
2. **Overseer-gated.** Soft-landing only happens when a judge is present
   (`is_pid(context.overseer_session)`). With no overseer the breach falls through
   unchanged to the existing IDE-74/IDE-73 deterministic-failure path (fast
   escalation after `deterministic_failure_escalation_count` consecutive breaches
   → `deterministic_failure_escalation_state`). Soft-landing with no judge would
   only burn ~`max_turns`× the compute before a human is looped in.
3. **`:turn_timeout` is excluded — on purpose.** A wall-clock timeout abandons a
   turn whose underlying SDK/Codex turn is **still running**, so resuming the same
   session would desync the protocol (late envelopes from the abandoned turn read
   as the next turn's). It also semantically wants "interrupt & escalate," not
   "continue." Making it a clean boundary needs the interrupt-then-drain primitive
   in §4.

Docs updated alongside: `Claude.AppServer.to_error_code/1` comment,
`agent.claude.max_turns` schema doc (the cap now doubles as a *judging cadence*),
SPEC §13.6 control-loop paragraph. Tests:
`agent_runner_coverage_test.exs` (soft-land-continues-under-overseer;
gating-preserves-the-crash-without-one).

---

## 3. What it solves

- **The overseer can no longer be skipped by a cap breach.** The single most
  common terminal signal for a long-running Claude session (`error_max_turns`)
  now lands the overseer instead of the retry loop.
- **IDE-198 specifically:** an agent grinding without converging hits the cap,
  soft-lands, and the overseer sees no-new-commits / oscillation → escalates to
  Human Review after the fail-streak — instead of silently retrying ten times.
- **The cap becomes a cadence knob.** Because a breach is now a clean boundary,
  lowering `agent.claude.max_turns` (e.g. 8–12) gives a Symphony-judged
  *check-in cadence* for Claude today, with no new code — the burst is judged, not
  discarded.

What it does **not** yet solve: Codex has no count cadence (no knob), and
`:turn_timeout` is still a crash for both adapters. Both need §4.

---

## 4. Where it is going (proposed, not yet built)

The end-state: **the cap is a backstop, not a decision.** Symphony interrupts on
its own read of progress, cost, and time, uniformly across adapters.

### 4.1 The interrupt-then-drain primitive

The missing mechanism. On a Symphony decision to stop a turn early:
send `interrupt` (the Claude sidecar already supports it mid-turn via a detached
turn task) / `turn/cancel` (Codex), **drain to the real terminal envelope** with a
bounded secondary timeout, then hand the now-idle session to the overseer. A
teardown fallback covers an interrupt that doesn't take.

This makes **`:turn_timeout` a clean boundary** for both adapters, and unlocks a
Symphony-owned count/time/cost cadence that does not depend on a Claude-only SDK
feature.

### 4.2 From boundary-triggered to monitor-driven

Today all judging is boundary-triggered (`observe_progress` runs only after
`run_turn` returns). Raise the cap and the boundaries vanish — so judging must
move to a **during-turn monitor** that samples cheap signals on an interval and
decides when to interrupt. The seam already exists: Symphony sees every inner turn
live through the `on_message` handler (it already records them to the overseer
transcript), so an inner-turn counter + thresholds live there; a small
timer/accumulator covers wall-clock and token burn.

Trigger axes:

- **inner-turn count** — every N model↔tool cycles, check in;
- **wall-clock** — the existing `turn_timeout`, now landing cleanly;
- **token / cost burn** — the "using too many resources" axis, where cost actually
  accrues (and which per-turn logging currently drops — see token_accounting.md).

Gate cheaply first (free git/token/time samples), spend the overseer LLM only when
a cheap signal trips. This is *cheaper* than a fixed low-cap cadence: the inner
loop stays hot (cache-reads stay cheap) and judging overhead is paid only when
warranted.

### 4.3 A new overseer action: decompose

Current actions: continue / nudge / recommend_extend_budget / escalate / abort.
"This issue is too big — split it" is none of those — it is mis-scoping, not
failure. A new action (e.g. move to a *Needs Decomposition* state with a findings
note recommending the split) lets Symphony pull the plug on a doomed high-cost
grind *mid-flight* the moment the cost signal says it should have been three
issues.

### 4.4 What §4 would solve

- A **uniform, Symphony-owned** stop decision for both adapters (Codex finally gets
  a count/cost cadence; `turn_timeout` becomes a real boundary).
- **Cost-based** intervention, not just turn-based — interrupt a 200k-token grind
  before it finishes.
- **Mid-flight re-scoping** ("decompose") instead of waiting for a cap or a
  natural finish that may never come.

---

## Appendix: glossary

- **Agent-driven / inner turn** — one model↔tool cycle inside a single
  `query()`/`turn/start`. Capped (Claude) by `agent.claude.max_turns`.
- **Symphony turn / continuation** — one re-prompt of the same session.
  Counted by `turn_number`; bounded by `agent.overseer.absolute_max_turns`
  (overseer) or `agent.max_turns` (keyless fallback).
- **Soft-land** — treat an adapter signal that would otherwise crash the run as a
  clean turn boundary the overseer judges.
- **Boundary-triggered vs monitor-driven** — judging that runs between turns
  (today) vs on a Symphony-driven schedule during a turn (proposed §4.2).
