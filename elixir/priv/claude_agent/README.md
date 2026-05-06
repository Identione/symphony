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
    iterates `client.receive_response()` until a `ResultMessage`.
  - `tool_result` / `permission_response` — round-trip replies for in-process
    MCP tools and `can_use_tool` callbacks (placeholders pending tool wiring).
  - `interrupt` — `await client.interrupt()`.
  - `shutdown` — clean exit.

Sidecar → Symphony:

  - `ready`, `system_init`, `assistant_message`, `tool_call`,
    `permission_request`, `token_usage`, `turn_end`, `error`, `log`.
