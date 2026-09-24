# symphony-claude-agent

Long-lived Python sidecar that bridges Symphony to the
[`claude-agent-sdk`](https://github.com/anthropics/claude-agent-sdk-python).
Implements the wire protocol documented in `SPEC.md` §10.8.

## Run locally

```sh
uv run --project priv/claude_agent python -m symphony_claude_agent
```

`ANTHROPIC_API_KEY` (or one of the documented provider env vars) must be set in
the environment.

## Wire protocol

Line-delimited JSON over stdio.

Symphony → sidecar:

  - `init` — start a `ClaudeSDKClient` session in the supplied `cwd` with the
    provided `permission_mode`, `allowed_tools`, `disallowed_tools`,
    `system_prompt`, `setting_sources`, and optional `max_turns`.
  - `turn` — drive one Symphony turn: calls `client.query(prompt)` then
    iterates `client.receive_messages()` until a `ResultMessage` with no
    background task in flight. A `ResultMessage` that arrives while a
    `Workflow` (or backgrounded `Agent`) task runs is held, and the CLI's
    auto-started follow-up response is drained into the same turn. The
    emitted `turn_end` sums `num_turns`/`usage` over both. Each task is
    bracketed by `tool_started`/`tool_finished`.
  - `tool_result` / `permission_response` — round-trip replies for in-process
    MCP tools and `can_use_tool` callbacks (placeholders pending tool wiring).
  - `interrupt` — `await client.interrupt()`.
  - `shutdown` — clean exit.

Sidecar → Symphony:

  - `ready`, `system_init`, `assistant_message`, `tool_call`,
    `permission_request`, `token_usage`, `turn_end`, `error`, `log`.
