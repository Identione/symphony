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
exhaustion, and rate-limit throttling — both adapters now carry a
structured taxonomy code (IDE-71). The error tuples are
`{:error, {:claude_sdk_error, code, msg}}` for Claude and
`{:error, {:turn_failed, code, params}}` /
`{:error, {:codex_error_notification, code, params}}` for Codex, where
`code` is one of `:context_window_exhausted`, `:rate_limited`,
`:overloaded`, `:quota_exceeded`, `:invalid_request`, `:unknown`. The
orchestrator does **not yet** branch on this code — that lands in IDE-72,
which depends on the classification this ticket adds. Today's behavior
is still a uniform exponential-backoff retry that ignores the underlying
cause, never changes Linear state, and has no max-attempts ceiling.

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

- `turn_end` — built from a clean `ResultMessage`, carrying
  `stop_reason`, `num_turns`, `usage`, `session_id`.
- `error` — emitted on any sidecar exception **and** on a
  `ResultMessage(is_error=True)` returned by the CLI. Every `error`
  envelope carries both `category` (legacy two-value discriminator) and
  `error_code` (IDE-71 taxonomy: one of `context_window_exhausted`,
  `rate_limited`, `overloaded`, `quota_exceeded`, `invalid_request`,
  `unknown`) computed by `classify_error_code` from the exception class
  name, HTTP status, and message body (`sidecar.py`, `classify_error_code`).

`category` still distinguishes the two failure-domain buckets:

- `"claude_sidecar_not_found"` — SDK import failed.
- `"claude_sdk_error"` — everything else, including every Anthropic SDK
  exception, malformed JSON, "turn before init", and the catch-all in
  `_drive_safe`.

**Elixir classification.** `Claude.Wire` whitelists envelope types,
atomises the `category` field, and atomises `error_code` only when its
value is in the closed IDE-71 taxonomy (`wire.ex`). `Claude.AppServer`
pattern-matches on the structured code and surfaces it as the 2nd
element of a 3-tuple:

```elixir
defp handle_envelope({:ok, %{type: :error} = env, _leftover},
                    _session, _context, _buffer) do
  {:error, {:claude_sdk_error, error_code_from_envelope(env),
            Map.get(env, :error, "")}}
end
```
(`app_server.ex` `handle_envelope/4`)

`error_code_from_envelope/1` defaults to `:unknown` whenever the
envelope omits `error_code` or carries an out-of-whitelist value, so
the orchestrator always receives an atom in the structured position.

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
| Context-window exhaustion | `anthropic.BadRequestError` ("prompt is too long") or HTTP 413 | `error`, `error_code="context_window_exhausted"` | `{:error, {:claude_sdk_error, :context_window_exhausted, msg}}` | Yes — structured code |
| Per-turn output cap | `ResultMessage(stop_reason="max_tokens")` | `turn_end` (success path) | `{:ok, %{stop_reason: "max_tokens", …}}` | Yes — `stop_reason` carried in result and logged when `verbose_logging=true` (`agent_runner.ex:106-114`) |
| `max_turns` (SDK-level cap from `init.max_turns`) | `ResultMessage(subtype="error_max_turns")` | `error`, `error_code="invalid_request"` (max_turns is deterministic) | `{:error, {:claude_sdk_error, :invalid_request, msg}}` | Yes |
| Account/quota | `RateLimitError`/`BadRequestError` w/ `credit_balance_too_low` body | `error`, `error_code="quota_exceeded"` (message heuristic wins over 429 status) | `{:error, {:claude_sdk_error, :quota_exceeded, msg}}` | Yes |
| Rate limit (transient) | `RateLimitError` or HTTP 429 without a quota body | `error`, `error_code="rate_limited"` | `{:error, {:claude_sdk_error, :rate_limited, msg}}` | Yes |
| Overloaded | `OverloadedError`, HTTP 503/529 | `error`, `error_code="overloaded"` | `{:error, {:claude_sdk_error, :overloaded, msg}}` | Yes |
| Other 4xx | `BadRequestError` / `AuthenticationError` / `PermissionDeniedError` | `error`, `error_code="invalid_request"` | `{:error, {:claude_sdk_error, :invalid_request, msg}}` | Yes |
| Unrecognised | Anything else (sidecar `NameError`, unknown class, ResultMessage with no body) | `error`, `error_code="unknown"` | `{:error, {:claude_sdk_error, :unknown, msg}}` | Falls back to `:unknown` — orchestrator should treat as retryable-generic |

### Codex (`SymphonyElixir.Codex.AppServer`)

**Wire surface.** The Codex app-server speaks JSON-RPC over stdio. Symphony
classifies a turn into one of these terminal tuples
(`codex/app_server.ex:354-453`, `:986-1024`):

| Source | Tuple |
|---|---|
| `turn/completed` notification | `{:ok, :turn_completed}` |
| `turn/failed` notification | `{:error, {:turn_failed, code, params}}` (IDE-71) |
| `turn/cancelled` notification | `{:error, {:turn_cancelled, params}}` |
| `codex/event/error` or `error` notification | `{:error, {:codex_error_notification, code, params}}` (IDE-71) |
| Approval needed without auto-approve | `{:error, {:approval_required, payload}}` |
| Tool/turn input required | `{:error, {:turn_input_required, payload}}` |
| JSON-RPC `error` reply to a request | `{:error, {:response_error, error}}` |
| Read-loop timeout (turn) | `{:error, :turn_timeout}` |
| Read-loop timeout (response init) | `{:error, :response_timeout}` |
| Port `:exit_status` in either loop | `{:error, {:port_exit, status}}` |

For `turn/failed` and `codex/event/error`, the `params` payload is
inspected by `classify_codex_error_payload/1` (priority: message-body
heuristics → HTTP status → upstream `error.code`/`error.type`) and the
resulting taxonomy atom is the 2nd element of the error tuple. Codes are
the same six values as the Claude side. The original `params` map is
preserved as the 3rd element so downstream consumers can still read it.
Port exit is still treated as opaque — the OS exit code is forwarded but
never inspected.

**Per failure mode (Codex):**

| Failure mode | Likely upstream signal | Tuple | Distinguishable? |
|---|---|---|---|
| Context-window exhaustion | `turn/failed`/error notification with `status=413` or context-length message | `{:error, {:turn_failed, :context_window_exhausted, params}}` | Yes — structured code |
| Per-turn output cap | `turn/completed` (Codex doesn't crash; the model just stops) | `{:ok, :turn_completed}` | No structured signal at the adapter — token-usage events (`elixir/docs/token_accounting.md`) are the only hint |
| `agent.max_turns` (Symphony-level) | n/a — orchestrator-side cap | `:ok` from `AgentRunner` | Only by reading the `Reached agent.max_turns…` info log (`agent_runner.ex:254-257`) |
| Account/quota | error payload mentioning `credit`/`quota`/`billing` (or 429 with that body) | `{:error, {:turn_failed, :quota_exceeded, params}}` or `{:error, {:codex_error_notification, :quota_exceeded, params}}` | Yes |
| Rate limit (transient) | HTTP 429 / `error.type=rate_limit_error` without a quota body | `{:error, {…, :rate_limited, params}}` | Yes |
| Overloaded | HTTP 503/529 / `error.type=overloaded_error` | `{:error, {…, :overloaded, params}}` | Yes |
| Other 4xx (auth, permission, etc.) | HTTP 4xx or `error.type` containing `invalid_request`/`permission`/`authentication` | `{:error, {…, :invalid_request, params}}` | Yes |
| Unrecognised error payload | Anything else (free-form message, opaque structure) | `{:error, {…, :unknown, params}}` | Falls back to `:unknown` |
| Codex CLI crash / `bash` exit | Port `:exit_status` (any code) | `{:error, {:port_exit, status}}` | Status forwarded but not classified — out of scope for IDE-71 (port exit is upstream-agnostic) |

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
missing) **gets stuck**. There is no max-attempts ceiling; the issue
loops at `agent.max_retry_backoff_ms` cadence (5 min default) with the
same outcome each time. There is no Linear-side signal — no comment, no
state change, no label — only the warning log line on each retry. An
operator looking only at Linear sees "this issue has been In Progress for
two days, what's happening?"

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
