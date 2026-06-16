# Symphony Claude-agent token-spend analysis

_Analysis date: 2026-06-16. Author: investigation of on-disk session transcripts + Symphony code._

This document explains **where the Claude sessions that Symphony launches spend their tokens**,
why, and the concrete levers (with `file:line`) to reduce that spend. Per-issue raw numbers are in
[`claude-token-ledger.csv`](./claude-token-ledger.csv).

---

## 0. Where the sessions actually live (and why they looked "missing")

Symphony's `claude` adapter runs the Python sidecar (`elixir/priv/claude_agent/`) under the `jai`
outer sandbox (`agent.claude.command: jai uv run …`). `jai` gives the process a **copy-on-write
`$HOME` overlay**, and the Claude Agent SDK writes its session transcripts to
`$CLAUDE_CONFIG_DIR/projects/<workspace-path>/…`. Those writes land in the overlay.

SETUP.md:146-148 describes the overlay writes as "discarded on session end", but in practice `jai`
**persists the overlay change-layer** under `~/.jai/default.changes/`. So every agent transcript is
recoverable here:

```
~/.jai/default.changes/.claude-identione/projects/
   -home-hniska-code-symphony-workspaces-entry-product-spec-IDE-<n>/   # instance: entry / entry-elixir
   -home-hniska-code-symphony-workspaces-symphony-IDE-<n>/             # instance: symphony
   -home-hniska-code-workspaces-IDE-<n>/                              # older workspace.root
```

The transcripts under `~/.claude-identione/projects/-home-hniska-stash-…-symphony*` are **interactive
operator sessions** (entrypoint `cli`, Opus 4.8) — debugging/operating Symphony by hand — **not**
agent runs. The only agent transcript that ever landed there (`…-symphony-IDE-71`) was an early
non-jai test. _(Correction 2026-06-16: the **ledger** row for IDE-71 is `claude-opus-4-7`, not Sonnet —
this "Sonnet test" label is contradicted by the data; the per-issue cost analysis treats IDE-71 as the
Opus run it records. See the §3a correction.)_

> ⚠️ The per-turn token `usage` Symphony forwards from the sidecar (`agent_runner.ex:199-204`) is
> logged at **debug** level; the instances run at info, so the token counts are **not** in
> `instances/*/log/`. The jai overlay transcripts are currently the only token-level record. A
> `jai` cleanup would erase them.

---

## 1. Headline

| Scope | Value |
|---|---|
| Issue-workspaces (agent runs) | **82** |
| Distinct SDK sessions (resumes) | **517** (mean 6.3 / issue, max **58**) |
| Total assistant turns | **26,802** (mean 327, median 212, max **1,467**) |
| Model | **`claude-opus-4-7`** (99.7% of turns) |
| **Total spend** | **≈ $6,530** (Opus list rates) |

For comparison, the entire body of interactive operator sessions about Symphony was ≈ $400. **The
autonomous fleet is ~16× the hand-driven usage and is the only cost center worth optimizing.**

---

## 2. Where the tokens go

### 2a. By token type — 80% is context handling, not generation

| Token type | Volume | ~Cost | Share |
|---|---:|---:|---:|
| **cache_read** | 2,156,790,000 | ~$3,235 | **49.5%** |
| **cache_creation** | 66,492,396 | ~$1,995 | **30.5%** |
| output | 17,351,428 | ~$1,301 | 19.9% |
| input (uncached) | 248,590 | ~$4 | 0.1% |

`cache_read : cache_creation ≈ 32 : 1` — caching is working well (each cached token is re-read ~32×).
The cost is **not** cache-miss waste; it is the structural cost of **re-reading a large context across
a huge number of turns**. `cache_read` is literally `Σ(context_size)` over all 26,802 turns.

### 2b. Output is 90% tool-call arguments; thinking is off

| Generated block | ~Tokens | Share |
|---|---:|---:|
| tool_use args (Bash/Edit/… arguments) | ~2,178,000 | 90.2% |
| assistant text | ~235,000 | 9.7% |
| thinking | ~900 | 0.0% |

Extended thinking is effectively disabled (15 of 26,787 assistant messages). Output cost is the model
emitting tool calls — i.e. a direct function of **turn count**, not verbose prose.

### 2c. What fills the context (drives cache_read)

Tool **results** are pasted into the conversation verbatim and then re-read on every subsequent turn:

| Tool | Results | Total chars | ~Tokens | Avg/result |
|---|---:|---:|---:|---:|
| **Read** | 1,691 | 12.5M | **~3.12M** | 7,377 ch (~1,850 tok) |
| **Bash** | 7,192 | 6.4M | **~1.59M** | 883 ch |
| **mcp__symphony__linear_graphql** | 1,327 | 2.7M | **~0.67M** | 2,018 ch |
| Agent (subagent results) | 214 | 0.7M | ~0.17M | 3,202 ch |
| Grep | 353 | 0.3M | ~0.08M | 920 ch |
| Edit / TodoWrite / Write / others | ~3,400 | 0.5M | ~0.13M | small |

`Read` alone is ~3.1M tokens of file dumps. A large file read early in a 300-turn session is paid for
~300× via cache_read. This is the single biggest controllable context driver.

### 2d. Turn / session distribution — the cost multiplier

```
turns/issue:   1-50: 3    51-200: 36    201-500: 27    501-1000: 14    1000+: 2
sessions/issue: mean 6.3, median 3, max 58
turns/session:  median 20 (== max_turns default), mean 52, max 367
```

`max_turns=20` caps a single session, but issues are **re-launched indefinitely** (see §3b), so the
per-issue turn count is unbounded. The long tail dominates:

| Concentration | Cumulative cost |
|---|---|
| Top 1 issue (IDE-132, 1,467 turns) | $357 (5%) |
| Top 5 | $1,163 (18%) |
| Top 10 | $2,041 (31%) |
| **Top 20** | **$3,433 (53%)** |

---

## 3. Why — root causes in the code

### 3a. Model is Opus 4.7, and it is the dominant price multiplier
- `elixir/lib/symphony_elixir/config/schema.ex:237` — `field(:model, :string)`, **no default**; set per
  instance in WORKFLOW.md (`agent.claude.model`, e.g. `elixir/WORKFLOW.md:97`,
  `instances/symphony/WORKFLOW.md`).
- Opus list rates are **~5× Sonnet** on every line that matters here: cache_read $1.50 vs $0.30/M,
  cache_creation $30 vs ~$3.75/M, output $75 vs $15/M.
- ⚠️ **Correction (2026-06-16):** there is **no clean same-workload Sonnet datapoint**. The "~$7"
  figure is **IDE-71's _Opus_ run re-priced at Sonnet rates**, not a measured Sonnet cost — the ledger
  row for IDE-71 is `claude-opus-4-7` at **$34.16** (13.35M cr × $1.50 + 0.30M cw × $30 + 0.069M out ×
  $75 ≈ $34.16; ÷5 ≈ $7). The only genuinely Sonnet-labeled rows are `old/5` ($0.54) and `old/9`
  ($0.31), both trivially small. The case for switching rests on the **rate card** (Opus list ≈ 5×
  Sonnet, above), which holds independently; equivalent Opus issues cost $80–$357.

### 3b. **No convergence / give-up cap** — issues re-run forever while "active"
- After every session exits normally (including hitting `max_turns`), the orchestrator schedules a
  re-launch **1 second later** (`orchestrator.ex:14` `@continuation_retry_delay_ms 1_000`;
  `orchestrator.ex:256-273`).
- The re-launch decision is purely state-driven: if the Linear issue is still in `Todo`/`In Progress`,
  run again (`orchestrator.ex:1639-1657`, `retry_candidate_issue?/2` at `:2374`).
- There is **no cap on sessions-per-issue, no progress/stall detection for normal exits, no
  convergence check** (`retry_policy.ex` only escalates on **repeated identical error codes**, not on
  slow progress). An issue the agent cannot close (or keeps "working") burns 20 turns × N relaunches
  until a human moves it out of an active state. This is what produces 24- and 58-session issues.

### 3c. **No truncation of tool output into the conversation**
- The sidecar's `fold_text` (`sidecar.py:191-213`, `_RENDER_TEXT_LIMIT = 1024`) only truncates text
  **rendered for logging**. `translate_symphony_tool_result` (`sidecar.py:216-249`) passes the tool
  `output` to Claude **verbatim, uncapped**.
- Elixir-side caps (`agent_runner.ex:242-254` 256-char log cap; `workspace.ex:406-416` 2KB hook-log
  cap) are also **log-only**.
- Net: full `Read`/`Bash` outputs enter the context unbounded (§2c).

### 3d. **No context compaction**
- The sidecar passes only `max_turns` and `max_budget_usd` to the SDK (`sidecar.py:319,322`); it does
  **not** enable auto-compaction or any history summarization. Within a session, history accumulates
  in full until `max_turns`.

### 3e. `linear_graphql` returns raw, pretty-printed JSON
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex:142` — `Jason.encode!(payload, pretty: true)`, no
  field filtering/flattening. 1,327 calls × ~2KB = ~0.67M tokens; pretty-printing inflates it further.

### 3f. Caching, thinking, max_tokens — not the problem
- Prompt caching is SDK-default (no knobs in Symphony). The 32:1 read:write ratio shows it is
  effective; cache-miss churn is **not** a material cost. (The 1s re-launch gap keeps the prefix warm
  even at a 5-minute TTL.)
- Thinking is off; no per-turn `max_tokens` cap. Neither is a current cost driver.

---

## 4. Recommended optimizations (prioritized)

> Estimated savings are relative to the observed ~$6,530 baseline and **compound** with each other.

### P0 — Switch the agent model to Sonnet (≈ −75–80%, ~$5,000+)
The largest single lever and a one-line config change per instance.
- Set `agent.claude.model: claude-sonnet-4-6` in each `instances/*/WORKFLOW.md` (knob:
  `config/schema.ex:237`).
- Same workload, ~5× lower unit price on every token type. **Validate quality on a few issues** — if
  Sonnet needs more turns, the 5× price edge still wins unless it needs >5× the turns (unlikely).
  _(The "$7 IDE-71" figure cited earlier is a Sonnet-rate **re-pricing** of an Opus run, not a measured
  Sonnet result — see the §3a correction. The lever rests on the rate card, which holds regardless.)_
- Optional refinement: Sonnet **with** extended thinking often converges in fewer turns; worth A/B-ing
  once a thinking knob exists (none today — would require adding `max_thinking_tokens` plumbing in
  `sidecar.py`).

### P1 — Add a per-issue give-up / convergence cap (cuts the long tail, ~15–35%)
The structural fix; without it, any non-converging issue is an unbounded token sink (top 20 issues =
53% of spend, and the worst are clearly non-converging at 900–1,467 turns).
- Add a **max-sessions-per-issue** (or max-cumulative-turns-per-issue) ceiling in the continuation
  path (`orchestrator.ex:256-273` / `handle_retry_issue_lookup` at `:1639-1657`). On breach, escalate
  the issue to the human-review state instead of re-launching — reuse the existing deterministic-
  failure escalation machinery (`retry_policy.ex`).
- Consider **non-progress detection**: if a continuation produces no workspace diff / no Linear state
  change across K sessions, stop and escalate.
- Wire `agent.claude.max_budget_usd` (already in schema, `:244`) through to a real per-issue budget
  ceiling and verify it actually halts re-launches.

### P2 — Cap tool output entering the conversation (cuts cache_read, ~10–25%)
`Read` (3.1M tok) + `Bash` (1.6M tok) are re-read every turn.
- Add a real content cap (head+tail with an elision marker) to tool results in
  `translate_symphony_tool_result` (`sidecar.py:216-249`) — e.g. 4–8KB per result — distinct from the
  log-only `fold_text`.
- Prompt-side: in the WORKFLOW body, steer the agent toward targeted reads (`Read` with offset/limit,
  `Grep` over full-file dumps) and away from re-reading files it already has.

### P3 — Slim `linear_graphql` responses (~3–5%)
- Drop `pretty: true` (`dynamic_tool.ex:142`) and/or project only the fields the prompt needs. 1,327
  calls makes even small per-call savings add up.

### P4 — Enable 1-hour prompt cache for the restart pattern (small, situational)
- Low priority given the healthy 32:1 ratio, but the multi-session resume pattern (517 sessions) could
  benefit from explicit 1h cache breakpoints if re-launch gaps ever exceed the default TTL. Requires
  adding cache-control plumbing in the sidecar (none today).

**Suggested order:** P0 (config, immediate, ~5×) → P1 (caps the tail / prevents runaway issues) →
P2 → P3.

---

## 5. Appendix

### 5a. Top 15 issues by cost

| Issue | Instance | Turns | Sessions | cr (M) | cw (M) | out (K) | Cost |
|---|---|---:|---:|---:|---:|---:|---:|
| IDE-132 | entry | 1,467 | 18 | 108.9 | 2.8 | 1,464 | $357 |
| IDE-163 | entry | 1,123 | 24 | 64.0 | 2.2 | 650 | $210 |
| IDE-100 | entry | 451 | 7 | 88.8 | 1.6 | 343 | $207 |
| IDE-161 | entry | 969 | 22 | 52.9 | 2.4 | 646 | $201 |
| IDE-162 | entry | 917 | 22 | 47.2 | 2.4 | 606 | $188 |
| IDE-158 | entry | 894 | 15 | 62.5 | 1.7 | 541 | $187 |
| IDE-73 | symphony | 460 | 3 | 74.1 | 1.2 | 390 | $177 |
| IDE-164 | entry | 964 | 23 | 52.5 | 1.9 | 484 | $173 |
| IDE-141 | entry | 628 | 11 | 67.1 | 1.0 | 548 | $172 |
| IDE-126 | entry | 459 | 3 | 74.1 | 1.1 | 314 | $169 |
| IDE-160 | entry | 812 | 14 | 45.6 | 2.0 | 455 | $162 |
| IDE-156 | entry | 548 | 16 | 32.3 | 2.9 | 328 | $161 |
| IDE-85 | entry | 592 | 7 | 53.7 | 1.6 | 385 | $158 |
| IDE-140 | entry | 591 | 9 | 66.4 | 1.0 | 332 | $156 |
| IDE-92 | entry | 385 | 2 | 75.9 | 0.8 | 210 | $152 |

Full 82-row ledger: [`claude-token-ledger.csv`](./claude-token-ledger.csv).

### 5b. Method / reproduce
- Source: `~/.jai/default.changes/.claude-identione/projects/` — dirs prefixed
  `-home-hniska-code-symphony-workspaces-*` and `-home-hniska-code-workspaces-IDE-*` (agent runs only;
  `…-stash-…-symphony*` excluded as interactive).
- Per assistant message, summed `usage.{input_tokens, cache_creation_input_tokens,
  cache_read_input_tokens, output_tokens}`; cost via Opus list rates (input $15, output $75,
  cache-write(1h) $30, cache-read $1.50 per Mtok); Sonnet at one-fifth.
- Output split (thinking/text/tool_use) approximated by content-block character length.
- Caveat: pricing is list-rate and approximate; `<synthetic>` messages (cancellations) carry no usage
  and are excluded from cost.
- ⚠️ **Data-quality caveats (don't trust these columns):** the `start`/`end` timestamps are frequently
  **reversed** (e.g. IDE-132 `start` 13:37 / `end` 11:39; IDE-73 `start` 06-08 / `end` 06-01; IDE-163
  `end` before `start`), so treat them as an unordered pair, not a duration. The `IDE-171` row has
  `model=?` and all-zero usage despite 132 turns — a parse miss; exclude it from any per-row analysis.
  Token/cost columns are unaffected; only timestamps and the IDE-171 row are suspect.
