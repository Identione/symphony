# Claude session execution optimization — findings from live transcripts (2026-07-05)

Analysis of the Claude sidecar sessions run by the `entry-elixir-v1-app-v2` instance,
issues IDE-264…IDE-276 (Jul 1–4, 2026). Raw transcripts live under
`~/.jai/default.changes/.claude-identione/projects/-home-hniska-code-symphony-workspaces-entry-product-spec-IDE-*/`.
All sessions ran `claude-opus-4-8`, `effort` unset (SDK default `high`).

**Implementation status (2026-07-05):** findings 1, 3, 4, 6, 7, 8 are addressed —
per-state `model_by_state`/`effort_by_state` + `disallowed_tools` set in all three
instances (knob examples in `WORKFLOW.md`/`cli/init.ex`), the body now states the
`sync_workpad` signature, gates the implementation-only sections on
`issue.state != "Merging"` (guarded by a `core_test.exs` render test), and carries
batching/slice-re-read/task-reminder rules; instance bodies resynced. Finding 2's
schema-side alias and finding 5 (continuation context) are follow-up PRs.

## Method note (avoid repeating a measurement bug)

Claude Code JSONL repeats the same `message.usage` on **every content-block
record** of one API response. Summing usage across `assistant` records
double-counts by ~2×. Dedupe by `message.id` before summing. Deduped shape of
the analyzed sessions:

| Run type | API calls | Output tokens | Context end | Cache-read total |
|---|---|---|---|---|
| Implementation run (Todo/In Progress) | 100–112 | 70k–110k | 190k–260k | 12M–18.5M |
| Merging/land run | 6–8 | ~3.5k | ~55k | 0.2M–0.3M |

Fixed cost of **every** run (fresh session per orchestrator run): ~40k tokens
(≈15.7k cached-shared system prefix + ≈19k per-session cache write + ≈5.7k
uncached input). The full ~18.5k-char rendered WORKFLOW body is re-sent
verbatim on every run of the same issue — a diff of run 1 vs run 4 prompts for
IDE-272 differs only in the `Current status:` line.

Within-run continuation turns (the short "Continuation guidance" prompt from
`AgentRunner.build_turn_prompt/5`) correctly share the session; the ~40k fixed
cost is paid per *run* (re-claim), not per continuation turn.

## Findings, ranked by expected savings

### 1. ~75% of output tokens are invisible thinking (effort=high everywhere)

The heaviest run (IDE-267 `ea67ab4e`, 112 calls) billed 110.5k output tokens
while its visible content (text + tool inputs) is ~28k tokens; the gap is 81
thinking blocks (persisted with empty text + encrypted signature). `effort` is
unset in the instance front matter, so the SDK default `high` applies to every
run — including mechanical Merging/land runs.

**Fix (config only — the `model_by_state`/`effort_by_state` knobs landed in
PR #60 and are resolved per run in `claude/app_server.ex`):**

```yaml
agent:
  claude:
    model: claude-opus-4-8
    model_by_state:
      Merging: claude-sonnet-5        # or haiku for pure land loops
    effort_by_state:
      Merging: low
      Rework: medium
```

State keys are lowercased on parse; per-state entries win over the top-level
`model`/`effort`. Expected: large cut of output tokens on non-implementation
runs, and materially more issues per Max-plan 5-hour window (the session limit
is the real binding constraint — this analysis itself hit it).

### 2. `sync_workpad` first call fails in ~100% of sessions

Every analyzed session (8/8 issues checked, IDE-261…IDE-276) makes its first
`sync_workpad` call with `workpad_path` and gets
`Additional properties are not allowed ('workpad_path' was unexpected)`, then
retries with `file_path`. The WORKFLOW body says "Edit a local `workpad.md` …
push it with the `sync_workpad` tool" but never states the parameter name, so
the model infers `workpad_path`. One wasted round-trip per run at 50–150k
context each.

**Fix (either):**
- One line in the WORKFLOW body (template source: `cli/init.ex` `agent_block/1`
  + `elixir/WORKFLOW.md`; instance bodies via body-splice, never
  `make init --force`): state the exact signature —
  `sync_workpad(issue_id, file_path, comment_id?)`.
- Or accept `workpad_path` as an alias in `@sync_workpad_input_schema`
  (`codex/dynamic_tool.ex:36`).

### 3. Per-checkbox workpad sync ceremony (~13% of all API calls)

Execution flow step 6 mandates: "After ticking off **each individual
checkbox**, immediately edit `workpad.md` and call `sync_workpad` — do not
batch". Observed cost in IDE-267 run 1: 8 workpad `Edit`s + 7 `sync_workpad`s
= 15 of 112 API calls (~2–2.5M cache-read tokens in that run alone; late-run
calls execute at 200k+ context).

**Fix:** relax to milestone-granularity — e.g. "sync after completing each
Execution-flow step, after any blocking discovery, and always before ending
the turn; adjacent quick checkboxes may share one sync." Keeps observability;
halves the ceremony.

### 4. Full 18.5k-char body re-sent per run; make it state-conditional

The body is re-rendered by `PromptBuilder` per run with live issue state
(`Current status:` changes), so Liquid conditionals work today. A Merging run
needs only the land-loop instructions (~2k chars), not Execution flow, PR
feedback sweep, Workpad template, Rework, Completion bar. A Rework run needs
the sweep protocol but not the plan scaffolding.

**Fix (template only):** wrap the big sections in
`{% if %}`-on-state conditionals in the body template. Cuts the ~19k/run
per-session cache write by 50%+ on non-implementation runs. Remember the two
hand-maintained template copies (`elixir/WORKFLOW.md` + `cli/init.ex`) and the
instance body-splice procedure.

### 5. Re-orientation tax on every new run (no continuation context)

Each run is a fresh session; the agent re-derives PR number, workpad
`comment_id`, branch state, and blocking-comment status via `gh` +
`linear_graphql` (5–10 calls per run; e.g. IDE-271 `7f672082` spent 6 of 8
calls re-discovering state before acting). Symphony already knows most of it:
it tracks `pr-link` records and routes every `sync_workpad` result (which
returns `comment.id`).

**Fix (code):** orchestrator persists per-issue facts across runs (PR URL,
workpad comment id, branch, last run HEAD) and `PromptBuilder` injects a short
"Continuation context" block on re-claims. Saves 5–10 calls/run and removes a
class of drift errors.

### 6. Harness task-reminder noise → stray tool misfires

Each session receives ~18 `task_reminder` attachments nudging TaskCreate/
TaskUpdate usage; sessions then call `TaskList`/`Monitor`/`SendMessage`
speculatively. `Monitor` failed 4/4 times (deferred tool, schema never loaded
via ToolSearch). Pure overhead for an unattended agent.

**Fix:** add `Monitor`, `TaskCreate`, `TaskUpdate`, `TaskList`, `SendMessage`
to `disallowed_tools` in the claude block (or a body line: "Ignore task-tool
reminders; do not use Task*/Monitor tools"). Also check whether the sidecar
can suppress the reminder attachments via env/settings.

### 7. No parallel tool calls

106 of 112 API calls in the heaviest run carried exactly one `tool_use`; only
5 carried two. Discovery phases (multiple independent greps/reads) serialize
into one round-trip each at full context price.

**Fix (body line):** "When tool calls are independent (multiple
reads/greps/status checks), issue them in a single response." Worth 10–20% of
calls on implementation runs.

### 8. Repeated full-file re-reads

Same large files re-read up to 7× per run (IDE-272 `org_show_live.ex`,
~17KB ≈ 4.3k tokens per read). `tool_output_limit` (16 KiB head+tail,
default on) is working — observed capped Bash results — but doesn't stop
whole-file `Read` churn under the cap.

**Fix (body line):** "When re-checking a file you already read, re-read only
the relevant slice (offset/limit) — not the whole file." Modest but free.

## Non-findings (fine as-is)

- Merging/land runs are already tight (6–8 calls) — the win there is model/
  effort routing (finding 1), not flow changes.
- `setting_sources: ["project"]` correctly scopes the tool pool; ToolSearch
  costs 1 call/session to load the two MCP schemas.
- No dead time: largest inter-record gap 118s (a long-running command), no
  polling loops.
- Shell-state re-prefixing (`cd <workspace>` on 36/49 Bash calls in one run,
  `repo=…` redefinition per call) is cosmetic token noise, low priority.

## Rough impact estimate

Per issue lifecycle (3–4 runs): today ~30–40M cache-read, ~250–450k output
tokens. Findings 1–4 (config + template only, no Elixir changes) cut output
tokens an estimated 40–60% and per-run fixed cost 50%+ on non-implementation
runs; findings 5–7 (one code change + body lines) cut another 15–25% of API
calls. The binding constraint is Max-plan session quota, so these translate
directly into more issues per window.

## Analysis tooling

Throwaway scripts (usage dedupe by `message.id`, tool-flow tracer, attachment/
batching profiler) were session-scratchpad only; the tables above are
reproducible from the transcript paths in the header with ~50 lines of Python.
