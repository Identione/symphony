# Token Exhaustion Behavior

This note documents how Symphony reacts when the underlying coding-agent runs
out of "tokens" mid-turn, separately for the Codex
(`SymphonyElixir.Codex.AppServer`) and Claude
(`SymphonyElixir.Claude.AppServer` + Python sidecar in
`elixir/priv/claude_agent/`) adapters.

Companion to `elixir/docs/logging.md` (logging conventions) and
`elixir/docs/token_accounting.md` (Codex token-usage accounting on the happy
path). This file covers the unhappy path.

## Failure Modes

"Out of tokens" is shorthand for four distinct upstream conditions, each of
which should ideally be handled differently:

1. **Context-window exhaustion** — accumulated conversation exceeds the
   model's max input tokens.
2. **Per-turn output cap** — the model hits its `max_output_tokens` budget
   and stops mid-response (or `max_turns` in the agent loop).
3. **Account/quota/credit exhaustion** — the upstream API returns a billing
   or quota error (HTTP 429 with a quota body, or 402, etc.).
4. **Rate limit / TPM-RPM throttling** — transient, looks the same as quota
   exhaustion at the wire level.

## TL;DR

For the *error* failure modes — context-window exhaustion, account/quota
exhaustion, and rate-limit throttling — neither adapter distinguishes them
from a generic "agent crashed" failure. They collapse into a single opaque
error tuple (`{:error, {:claude_sdk_error, msg}}` for Claude,
`{:error, {:turn_failed, params}}` / `{:error, {:codex_error_notification,
params}}` for Codex) and land in the orchestrator as a non-`:normal` task
exit. The orchestrator then runs a uniform exponential-backoff retry that
ignores the underlying cause, never changes Linear state, and has no
max-attempts ceiling.

Per-turn output cap is a partial exception: Claude's sidecar surfaces it as
a clean `turn_end` (`ResultMessage`) and the adapter preserves `stop_reason`
(e.g. `"max_tokens"`) and `num_turns` in the success result
(`app_server.ex:387-389,503-511`). So the *signal* is carried through the
adapter — but Symphony does not act on it at the orchestration level
(only echoed to the verbose info log at `agent_runner.ex:106-114`); the
issue continues as if the turn ended normally. Codex's per-turn output cap
isn't even surfaced — it arrives as a normal `turn/completed`.

Net effect: the issue stays in `In Progress` and gets re-attempted up to
once every `agent.max_retry_backoff_ms` (default 5 min, `config/schema.ex:281`)
until either the issue moves out of `active_states` or the agent eventually
succeeds.

## Adapter Traces

### Claude (`SymphonyElixir.Claude.AppServer` + sidecar)

**Wire surface.** The Python sidecar at `elixir/priv/claude_agent/symphony_claude_agent/sidecar.py`
emits one of two terminal envelopes per turn:

- `turn_end` — built from a `ResultMessage`, carrying
  `stop_reason`, `num_turns`, `usage`, `session_id`
  (`sidecar.py:465-475`).
- `error` — emitted on any sidecar exception with a single
  `category` field (`sidecar.py:444-452`, `594-597`, `608-611`,
  `641-649`).

The sidecar only ever sets `category` to one of two values:

- `"claude_sidecar_not_found"` — SDK import failed (`sidecar.py:397`).
- `"claude_sdk_error"` — everything else, including every Anthropic SDK
  exception, malformed JSON, "turn before init", and the catch-all in
  `_drive_safe` (`sidecar.py:360,431,436,449,594,597,610,646`).

The exception class name is interpolated into the human-readable `error`
string but never structured. So `RateLimitError`, `OverloadedError`,
`InvalidRequestError` (context length), and a NameError in the sidecar all
arrive as `category="claude_sdk_error"` with the class name only readable by
substring-matching the message text.

**Elixir classification.** `Claude.Wire` whitelists envelope types and
atomizes the `category` field as a known key (`wire.ex:14-25,99-116`), but
`Claude.AppServer` does not pattern-match on it:

```elixir
defp handle_envelope({:ok, %{type: :error, error: msg}, _leftover},
                    _session, _context, _buffer) do
  {:error, {:claude_sdk_error, msg}}
end
```
(`app_server.ex:392-394`)

Sidecar process death surfaces as a separate tuple but is also undifferentiated:

```elixir
{^port, {:exit_status, status}} ->
  {:error, {:claude_sidecar_exit, status}}
```
(`app_server.ex:345-346`)

There is no cap on input length, no compaction step, and no inspection of
`stop_reason` for the per-turn-output-cap case beyond what
`build_turn_result/2` echoes back (`app_server.ex:503-511`).

**Per failure mode (Claude):**

| Failure mode | Upstream signal | Sidecar envelope | Elixir tuple | Distinguishable? |
|---|---|---|---|---|
| Context-window exhaustion | `anthropic.BadRequestError` ("prompt is too long") | `error`, `category="claude_sdk_error"`, message includes class name | `{:error, {:claude_sdk_error, "BadRequestError: …"}}` | Only by substring match on the message |
| Per-turn output cap | `ResultMessage(stop_reason="max_tokens")` | `turn_end` (success path) | `{:ok, %{stop_reason: "max_tokens", …}}` | Yes — `stop_reason` carried in result and logged when `verbose_logging=true` (`agent_runner.ex:106-114`) |
| `max_turns` (SDK-level cap from `init.max_turns`) | `ResultMessage(stop_reason="end_turn")` after N iterations | `turn_end` | `{:ok, %{stop_reason: "end_turn", num_turns: N, …}}` | Same as a normal completion — only distinguishable via `num_turns` |
| Account/quota | `RateLimitError` or `BadRequestError` w/ `credit_balance_too_low` | `error`, `category="claude_sdk_error"` | `{:error, {:claude_sdk_error, …}}` | Only by substring match |
| Rate limit (transient) | `RateLimitError` | same as quota | same as quota | **Indistinguishable from quota exhaustion** |

### Codex (`SymphonyElixir.Codex.AppServer`)

**Wire surface.** The Codex app-server speaks JSON-RPC over stdio. Symphony
classifies a turn into one of these terminal tuples
(`codex/app_server.ex:354-453`, `:986-1024`):

| Source | Tuple |
|---|---|
| `turn/completed` notification | `{:ok, :turn_completed}` |
| `turn/failed` notification | `{:error, {:turn_failed, params}}` (`:386-396`) |
| `turn/cancelled` notification | `{:error, {:turn_cancelled, params}}` (`:398-408`) |
| `codex/event/error` or `error` notification | `{:error, {:codex_error_notification, params}}` (`:514-528`) |
| Approval needed without auto-approve | `{:error, {:approval_required, payload}}` (`:503-511`) |
| Tool/turn input required | `{:error, {:turn_input_required, payload}}` (`:490-498`, `:530-538`) |
| JSON-RPC `error` reply to a request | `{:error, {:response_error, error}}` (`:1006-1014`) |
| Read-loop timeout (turn) | `{:error, :turn_timeout}` (`:373-374`) |
| Read-loop timeout (response init) | `{:error, :response_timeout}` (`:998-999`) |
| Port `:exit_status` in either loop | `{:error, {:port_exit, status}}` (`:370-371`, `:995-996`) |

The `params` payload for a `turn/failed` or `codex_error_notification` may
contain an upstream HTTP code or quota token, but Symphony does not parse
it: the entire `params` map is wrapped opaquely. Port exit is treated as
opaque too — the OS exit code is forwarded but never inspected.

**Per failure mode (Codex):**

| Failure mode | Likely upstream signal | Tuple | Distinguishable? |
|---|---|---|---|
| Context-window exhaustion | `turn/failed` with a `params.error` describing context length | `{:error, {:turn_failed, params}}` | Only by inspecting `params` content |
| Per-turn output cap | `turn/completed` (Codex doesn't crash; the model just stops) | `{:ok, :turn_completed}` | No structured signal at the adapter — token-usage events (`elixir/docs/token_accounting.md`) are the only hint |
| `agent.max_turns` (Symphony-level) | n/a — orchestrator-side cap | `:ok` from `AgentRunner` | Only by reading the `Reached agent.max_turns…` info log (`agent_runner.ex:254-257`) |
| Account/quota | `turn/failed` or `codex/event/error` with HTTP 429/402 in `params` | `{:error, {:turn_failed, …}}` or `{:error, {:codex_error_notification, …}}` | Substring match on `inspect(params)` only |
| Rate limit (transient) | Same as quota | Same as quota | **Indistinguishable from quota exhaustion** |
| Codex CLI crash / `bash` exit | Port `:exit_status` (any code) | `{:error, {:port_exit, status}}` | Status forwarded but not interpreted; clean shutdown (`status=0`) and crash (`status!=0`) coalesce by the time orchestrator sees them |

## Orchestration Layer

`AgentRunner.run/3` is the boundary between the adapter and the orchestrator.
On any adapter failure it logs and **raises**, which kills the
`Task.Supervisor`-managed process:

```elixir
case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
  :ok -> :ok
  {:error, reason} ->
    Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
    raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
end
```
(`agent_runner.ex:20-27`)

The Orchestrator's `:DOWN` handler then takes over:

```elixir
case reason do
  :normal -> # …schedule continuation check
  _ ->
    Logger.warning("Agent task exited for issue_id=… session_id=… reason=…; scheduling retry")
    next_attempt = next_retry_attempt_from_running(running_entry)
    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      error: "agent exited: #{inspect(reason)}",
      …
    })
end
```
(`orchestrator.ex:146-170`)

Retry delay is purely a function of attempt count
(`orchestrator.ex:960-971`):

```elixir
defp failure_retry_delay(attempt) do
  max_delay_power = min(attempt - 1, 10)
  min(@failure_retry_base_ms * (1 <<< max_delay_power),
      Config.settings!().agent.max_retry_backoff_ms)
end
```

`@failure_retry_base_ms = 10_000` (`orchestrator.ex:14`), and
`agent.max_retry_backoff_ms` defaults to 300_000
(`config/schema.ex:281`). So a stuck agent retries at 10s, 20s, 40s, …
capped at 5 minutes, **forever**, as long as the Linear issue stays in an
active state. The issue's Linear state is never changed by the
orchestrator on failure; the only way out is for a human (or the agent
itself on a future attempt) to move it.

The 30-second poll loop (`polling.interval_ms`,
`config/schema.ex:77`) does not interact with the retry timer; the
orchestrator's `Process.send_after` for `{:retry_issue, …}` is independent.

There is also a stall watchdog: if `running_entry`'s
`last_codex_timestamp` has not advanced for `active_stall_timeout_ms`
(default 5 min, `config/schema.ex:209`), the orchestrator forcibly
terminates the worker and re-schedules a retry with the same backoff
(`orchestrator.ex:484-504`). A network-blocked sidecar that emits no
events for 5 min is therefore reaped even if it would have eventually
returned.

`agent.max_turns` (default 20, `config/schema.ex:280`) is enforced inside
`AgentRunner.handle_turn_continuation/3` (`agent_runner.ex:241-267`).
When the cap is hit while the issue is still active, `AgentRunner` returns
`:ok`, which gives the orchestrator the same `:normal` exit it would see
for a clean completion. From the orchestrator's perspective, hitting
`max_turns` is **indistinguishable** from a successful completion — both
schedule a 1-second `delay_type: :continuation` re-poll
(`orchestrator.ex:147-157`). The only distinguishing signal is the info
log `Reached agent.max_turns for … with issue still active`
(`agent_runner.ex:254-257`).

## Logging Conformance

Per `elixir/docs/logging.md`, error/lifecycle logs should carry `issue_id`,
`issue_identifier`, and (when known) `session_id`.

| Site | Level | Includes |
|---|---|---|
| `claude/app_server.ex:69` (sidecar startup failure) | `error` | none — by design, no issue is bound yet |
| `claude/app_server.ex:109` (turn-write failure) | `error` | issue context only |
| `claude/app_server.ex:120` (turn ended in error) | `warning` | issue context only |
| `codex/app_server.ex:125` (Codex turn ended in error) | `warning` | issue context **and** `session_id` |
| `codex/app_server.ex:141` (Codex startup failure) | `error` | issue context only |
| `codex/app_server.ex:527` (`codex/event/error` notification) | `warning` | **none** — payload only |
| `codex/app_server.ex:1035` (heuristic stderr forward) | `warning` | **none** — text only |
| `agent_runner.ex:25` (`AgentRunner.run` failure) | `error` | issue context only |
| `agent_runner.ex:106-114` (Claude `turn_completed`, verbose only) | `info` | issue context, `session_id`, `stop_reason`, `num_turns`, usage |
| `orchestrator.ex:160` (`:DOWN` non-normal) | `warning` | `issue_id`, `session_id`, reason — **no `issue_identifier`** |
| `orchestrator.ex:172` (post-DOWN summary) | `info` | `issue_id`, `session_id` — **no `issue_identifier`** |
| `orchestrator.ex:491` (stall reaper) | `warning` | full triple |
| `orchestrator.ex:823` (retry schedule) | `warning` | `issue_id`, `issue_identifier` — **no `session_id`** |

The Python sidecar has no structured logging at all. Error envelopes
intentionally omit `session_id` (the sidecar doesn't know it until the
SDK's first `system_init`), but they also lack any cross-reference back
to the failing turn.

## Recoverable vs. Stuck

A run that fails because of a transient cause (rate limit, brief network
blip, sidecar OOM-killed once) **recovers** — the orchestrator's
exponential-backoff retry will eventually re-dispatch and the agent will
re-run from scratch with a fresh workspace state.

A run that fails because of a deterministic cause (account out of credit,
context window permanently overflowed for this prompt, sidecar binary
missing) **gets stuck on the retry side, but IDE-73 closes the
visibility gap.**

After `agent.deterministic_failure_alert_threshold` (default 3) consecutive
failures carrying the same structured `error_code` (IDE-71 taxonomy —
`quota_exceeded`, `context_window_exhausted`, `invalid_request`,
`claude_sidecar_exit`, `port_exit`), `SymphonyElixir.DeterministicFailure`
appends a summary section to the existing `## Symphony Workpad` comment —
or, if no workpad is found, posts a standalone blocker comment in line
with the workflow's blocked-access escape hatch. After
`agent.deterministic_failure_escalation_threshold` (default 5), it moves
the issue to `agent.deterministic_failure_escalation_state` (default
`"Human Review"`) so the polling loop stops re-dispatching it.

Transient codes (`rate_limited`, `overloaded`, `turn_timeout`,
`response_timeout`, `unknown`) reset the counter so a brief upstream blip
never trips the threshold. Switching to a *different* deterministic code
also restarts the streak from one, since the new failure mode deserves a
fresh alert.

## Desired Behavior

These are the gaps. Each is a candidate for a follow-up ticket; specific
proposals are listed in the next section.

1. **Distinguish quota / rate-limit / context-window exhaustion from
   generic crash.** Sidecar should map exception classes to a structured
   `error_code` field (or split `category` into a real taxonomy);
   `Codex.AppServer` should classify `params.error.code` /
   `params.error.type` from `turn/failed` and `codex/event/error`. Both
   adapters should propagate that classification through the
   `{:error, …}` tuple so the orchestrator can branch on it.
2. **Differentiated retry policy.** A `RateLimitError` deserves a longer
   backoff that respects `Retry-After`; a context-window overflow does
   not deserve any retry until something has shrunk the input; a
   `credit_balance_too_low` does not deserve any retry at all without a
   human in the loop.
3. **Surface stuck issues to Linear.** After N consecutive deterministic
   failures with the same classification, post a workpad comment (or
   move the issue out of `active_states`) so the failure is visible to
   whoever owns the ticket. Today Symphony just keeps retrying.
4. **Make `max_turns` exhaustion distinguishable from clean completion.**
   `AgentRunner.handle_turn_continuation/3` should signal `:max_turns`
   to the orchestrator (or post a workpad comment) when it returns `:ok`
   while the issue is still active — currently the only signal is one
   info log line, lost in the rest of the per-turn chatter.
5. **Audit logs for required context fields.** Several existing error
   sites are missing `issue_identifier` or `session_id`; see the table
   above.
6. **(Stretch) Compact context on context-window exhaustion.** Today the
   retry loop re-runs the same prompt against a workspace that's only
   gotten larger. A summarize-and-retry path would be worth scoping but
   is not a fix for the orchestration gaps above.

## Follow-up Tickets

Filed against the Symphony project, all `Backlog`, all linked `related`
to IDE-70.

| Ticket | Title | Notes |
|---|---|---|
| IDE-71 | Adapter: classify quota / rate-limit / context-window errors instead of collapsing to generic crash | Foundation; `blocks` IDE-72 and IDE-73 |
| IDE-72 | Orchestrator: differentiate retry policy by failure code (rate-limit vs quota vs context-window) | `blockedBy` IDE-71 |
| IDE-73 | Orchestrator: surface stuck issues to Linear after N consecutive deterministic failures | `blockedBy` IDE-71 |
| IDE-74 | AgentRunner: signal max_turns exhaustion distinctly from clean completion | Coordinate with IDE-73 |
| IDE-75 | Logging: backfill missing `issue_identifier` / `session_id` on agent error and orchestrator retry sites | Pure backfill, independent |
