# Logging Best Practices

This guide defines logging conventions for Symphony so Codex can diagnose failures quickly.

## Goals

- Make logs searchable by issue and session.
- Capture enough execution context to identify root cause without reruns.
- Keep messages stable so dashboards/alerts are reliable.

## Required Context Fields

When logging issue-related work, include both identifiers:

- `issue_id`: Linear internal UUID (stable foreign key).
- `issue_identifier`: human ticket key (for example `MT-620`).

When logging Codex execution lifecycle events, include:

- `session_id`: combined Codex thread/turn identifier.

## Message Design

- Use explicit `key=value` pairs in message text for high-signal fields.
- Prefer deterministic wording for recurring lifecycle events.
- Include the action outcome (`completed`, `failed`, `retrying`) and the reason/error when available.
- Avoid logging large payloads unless required for debugging.

## Scope Guidance

- `AgentRunner`: log start/completion/failure with issue context, plus `session_id` when known.
- `Orchestrator`: log dispatch, retry, terminal/non-active transitions, and worker exits with issue context. Include `session_id` whenever running-entry data has it.
- `Codex.AppServer`: log session start/completion/error with issue context and `session_id`.
- `Claude.AppServer` (via `AgentRunner.compose_message_handler/4`): when `agent.claude.verbose_logging=true`, for every envelope received from the sidecar emit one `Logger.info` line in `key=value` form. When `verbose_logging=false` (default), every line below is suppressed — Symphony stays at the per-issue/per-session lifecycle level. Event vocabulary:
  - `claude tool_call for issue_id=… issue_identifier=… session_id=… name=<tool> input=<json>`
  - `claude assistant_message for issue_id=… issue_identifier=… session_id=… text="…"` (text body includes folded `[tool_use Name(id)] {input}` / `[tool_result id] body` / `[thinking] …` markers when present in the underlying SDK message)
  - `claude turn_completed for issue_id=… issue_identifier=… session_id=… stop_reason=… num_turns=… usage.input_tokens=… usage.output_tokens=…`
  - `claude permission_request for issue_id=… issue_identifier=… session_id=… request=<json>`
  - `claude system_init for issue_id=… issue_identifier=… session_id=…`
  - `<source>: <message>` for `:log` envelopes — the underlying `claude` CLI's stderr is forwarded with `source="claude_cli"`, so those lines start with `claude_cli:`. The sidecar only installs the stderr forwarder when `verbose_logging=true`; otherwise the CLI's stderr is dropped before it ever reaches Symphony.
  - All values are length-capped (256 chars) with a `…(N more chars)` suffix; partial-stream events (`assistant_delta`) are intentionally **not** logged even when `agent.claude.verbose_logging=true` (they would flood `symphony.log`).

## Checklist For New Logs

- Is this event tied to a Linear issue? Include `issue_id` and `issue_identifier`.
- Is this event tied to a Codex session? Include `session_id`.
- Is the failure reason present and concise?
- Is the message format consistent with existing lifecycle logs?
