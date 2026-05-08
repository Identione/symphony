"""Symphony Claude Agent SDK sidecar entrypoint.

Long-lived subprocess that hosts the Claude Agent SDK and bridges Symphony
over a line-delimited JSON wire protocol on stdio (SPEC.md §10.8).

The protocol is intentionally narrow: see priv/claude_agent/README.md for the
envelope vocabulary. Anything Symphony does not pre-approve via `dontAsk` +
`allowed_tools` + the workspace-boundary `PreToolUse` hook is denied.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import traceback
import uuid
from dataclasses import dataclass, field
from typing import Any

# ``claude_agent_sdk`` is a runtime dependency. Importing it lazily lets the
# unit-level smoke test verify the wire-protocol helpers without requiring the
# SDK to be installed.
try:  # pragma: no cover - import-time guard
    from claude_agent_sdk import (  # type: ignore[import-not-found]
        ClaudeAgentOptions,
        ClaudeSDKClient,
        ResultMessage,
        SystemMessage,
        create_sdk_mcp_server,
        tool,
    )

    _SDK_AVAILABLE = True
except ImportError:  # pragma: no cover - exercised only when SDK missing
    _SDK_AVAILABLE = False


CLAUDE_CODE_SYSTEM_PROMPT_PRESET = {"type": "preset", "preset": "claude_code"}


# Length cap for any single rendered block in `render_message_text`. Sidecar
# can afford a generous limit because each call produces one envelope, not a
# per-key log line. Symphony's Logger handler caps further on its end (256
# chars per value) per `elixir/docs/logging.md`.
_RENDER_TEXT_LIMIT = 1024


# Mirrors the canonical schema in
# elixir/lib/symphony_elixir/codex/dynamic_tool.ex (`@linear_graphql_input_schema`).
# Used only when the `init` envelope arrives without `tool_specs` (older
# Symphony or the SYMPHONY_CLAUDE_AGENT_DRY_RUN smoke path). Symphony's
# `init.tool_specs` takes precedence at runtime so there is one source of truth.
_LINEAR_GRAPHQL_FALLBACK_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["query"],
    "properties": {
        "query": {
            "type": "string",
            "description": "GraphQL query or mutation document to execute against Linear.",
        },
        "variables": {
            "type": ["object", "null"],
            "description": "Optional GraphQL variables object.",
            "additionalProperties": True,
        },
    },
}


def extract_tool_schemas(env: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Read `init.tool_specs` and index each spec's `inputSchema` by name."""

    specs = env.get("tool_specs") or []
    if not isinstance(specs, list):
        return {}

    schemas: dict[str, dict[str, Any]] = {}
    for spec in specs:
        if not isinstance(spec, dict):
            continue
        name = spec.get("name")
        schema = spec.get("inputSchema")
        if isinstance(name, str) and isinstance(schema, dict):
            schemas[name] = schema
    return schemas


class PendingToolCalls:
    """Tracks in-flight Symphony tool-call round-trips by ``tool_use_id``.

    The MCP tool function calls :meth:`register` to allocate a future, emits a
    ``tool_call`` envelope, and awaits the future. The sidecar's main loop
    calls :meth:`resolve` when Symphony writes back a ``tool_result``.
    """

    def __init__(self) -> None:
        self._pending: dict[str, asyncio.Future[Any]] = {}

    def register(self, tool_use_id: str) -> asyncio.Future[Any]:
        loop = asyncio.get_running_loop()
        future: asyncio.Future[Any] = loop.create_future()
        self._pending[tool_use_id] = future
        return future

    def has(self, tool_use_id: str) -> bool:
        return tool_use_id in self._pending

    def resolve(self, tool_use_id: str, result: Any) -> None:
        future = self._pending.pop(tool_use_id, None)
        if future is None:
            return
        if not future.done():
            future.set_result(result)


@dataclass
class SessionState:
    """Per-process Claude session bookkeeping."""

    session_id: str | None = None
    client: Any | None = None  # ClaudeSDKClient when SDK present
    pending_tool_calls: PendingToolCalls = field(default_factory=PendingToolCalls)
    tool_schemas: dict[str, dict[str, Any]] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Wire helpers (pure — easy to unit-test without the SDK)
# ---------------------------------------------------------------------------


def emit(event: dict[str, Any], stream=sys.stdout) -> None:
    """Write a single JSON envelope followed by a newline and flush."""

    stream.write(json.dumps(event, separators=(",", ":")))
    stream.write("\n")
    stream.flush()


def fold_text(value: Any, *, limit: int = _RENDER_TEXT_LIMIT) -> str:
    """Render any value to a single string capped at ``limit`` chars.

    Non-strings are JSON-encoded compactly. Long output is truncated with a
    `…(<n> more chars)` suffix so the reader sees the omission rather than
    silently losing data.
    """

    if value is None:
        return ""
    if isinstance(value, str):
        text = value
    else:
        try:
            text = json.dumps(value, separators=(",", ":"), default=str)
        except (TypeError, ValueError):
            text = repr(value)

    if len(text) <= limit:
        return text

    omitted = len(text) - limit
    return f"{text[:limit]}…({omitted} more chars)"


def translate_symphony_tool_result(result: Any) -> dict[str, Any]:
    """Translate a Symphony ``tool_result.result`` payload into an MCP tool response.

    Symphony's ``Codex.DynamicTool.execute/2`` returns
    ``{"success": bool, "output": json_string, "contentItems": [...]}``. Claude
    only needs the inner ``output`` text plus a correctness signal — the
    ``success`` flag becomes MCP's ``is_error`` channel so Claude can recover
    from GraphQL/auth/transport failures, and ``contentItems`` is dropped (we
    surface ``output`` directly as a single text block instead of double-wrapping).
    """

    if result is None:
        return {"content": [{"type": "text", "text": ""}], "is_error": True}

    if not isinstance(result, dict):
        # Defensive: a malformed Symphony reply (e.g. raw string) is surfaced
        # to Claude as a JSON-encoded body and an error so it can recover
        # rather than silently consume garbage.
        return {
            "content": [{"type": "text", "text": json.dumps(result)}],
            "is_error": True,
        }

    is_error = not bool(result.get("success", False))

    if "output" in result and isinstance(result["output"], str):
        text = result["output"]
    else:
        # Defensive: missing/non-string `output` falls back to a JSON dump of
        # the whole map so nothing is silently lost — but only mark as error
        # if `success=false`, since this is a shape issue not a tool failure.
        text = json.dumps(result, separators=(",", ":"))

    return {"content": [{"type": "text", "text": text}], "is_error": is_error}


async def forward_tool_call_to_symphony(
    pending: PendingToolCalls,
    *,
    name: str,
    input: dict[str, Any],
    emit_stream=sys.stdout,
    tool_use_id: str | None = None,
) -> Any:
    """Emit a ``tool_call`` envelope and await Symphony's ``tool_result``."""

    if tool_use_id is None:
        tool_use_id = str(uuid.uuid4())

    future = pending.register(tool_use_id)
    emit(
        {
            "type": "tool_call",
            "tool_use_id": tool_use_id,
            "name": name,
            "input": input,
        },
        stream=emit_stream,
    )

    return await future


def parse_line(line: str) -> dict[str, Any]:
    """Decode a Symphony→sidecar JSON line. Raises ValueError on bad input."""

    decoded = json.loads(line)
    if not isinstance(decoded, dict):
        raise ValueError("envelope must be a JSON object")
    if "type" not in decoded:
        raise ValueError("envelope missing 'type' field")
    return decoded


def build_options_payload(init_envelope: dict[str, Any]) -> dict[str, Any]:
    """Translate an ``init`` envelope into ``ClaudeAgentOptions`` kwargs.

    Returns a plain dict so this is testable without the SDK installed.
    """

    cwd = init_envelope.get("cwd")
    if not cwd:
        raise ValueError("init.cwd is required")

    preset = init_envelope.get("system_prompt_preset", "claude_code")
    if preset == "claude_code":
        system_prompt: Any = CLAUDE_CODE_SYSTEM_PROMPT_PRESET
    else:
        system_prompt = ""  # minimal preset

    payload: dict[str, Any] = {
        "cwd": cwd,
        "permission_mode": init_envelope.get("permission_mode", "dontAsk"),
        "allowed_tools": init_envelope.get("allowed_tools", []) or [],
        "disallowed_tools": init_envelope.get("disallowed_tools", []) or [],
        "setting_sources": init_envelope.get("setting_sources", []) or [],
        "system_prompt": system_prompt,
    }

    if init_envelope.get("model"):
        payload["model"] = init_envelope["model"]

    if init_envelope.get("max_turns") is not None:
        payload["max_turns"] = init_envelope["max_turns"]

    if init_envelope.get("max_budget_usd") is not None:
        payload["max_budget_usd"] = init_envelope["max_budget_usd"]

    if init_envelope.get("verbose_logging"):
        # Surface partial-stream events and hook lifecycle messages so a
        # reader can see Claude's per-token output and PreToolUse/PostToolUse
        # decisions. Symphony's runner handler decides what to log; the SDK
        # only emits these when explicitly enabled.
        payload["include_partial_messages"] = True
        payload["include_hook_events"] = True

    return payload


def usage_to_envelope(usage: Any) -> dict[str, int]:
    """Normalize a Claude SDK ``Usage`` object/dict into our wire shape."""

    if usage is None:
        return {
            "input_tokens": 0,
            "output_tokens": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        }

    if isinstance(usage, dict):
        get = usage.get
    else:
        def get(key: str, default: int = 0) -> int:
            return getattr(usage, key, default)

    return {
        "input_tokens": int(get("input_tokens", 0) or 0),
        "output_tokens": int(get("output_tokens", 0) or 0),
        "cache_creation_input_tokens": int(get("cache_creation_input_tokens", 0) or 0),
        "cache_read_input_tokens": int(get("cache_read_input_tokens", 0) or 0),
    }


# ---------------------------------------------------------------------------
# Async sidecar driver (SDK required)
# ---------------------------------------------------------------------------


async def _stdin_lines():
    """Async generator yielding stripped, non-empty stdin lines."""

    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(loop=loop)
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        raw = await reader.readline()
        if not raw:
            return
        text = raw.decode("utf-8", errors="replace").strip()
        if text:
            yield text


async def _drive(state: SessionState, env: dict[str, Any]) -> None:
    """Dispatch a single Symphony→sidecar envelope."""

    msg_type = env.get("type")

    if msg_type == "init":
        await _handle_init(state, env)
    elif msg_type == "turn":
        await _handle_turn(state, env)
    elif msg_type == "interrupt":
        await _handle_interrupt(state)
    elif msg_type == "shutdown":
        await _handle_shutdown(state)
    elif msg_type == "tool_result":
        tool_use_id = env.get("tool_use_id")
        if isinstance(tool_use_id, str):
            state.pending_tool_calls.resolve(tool_use_id, env.get("result"))
    elif msg_type == "permission_response":
        # Permission round-trip uses the same future registry, keyed by
        # `permission_request_id`. Currently unused (the SDK's `can_use_tool`
        # path is not wired yet); accept the envelope so Symphony can send it
        # without erroring.
        request_id = env.get("permission_request_id")
        if isinstance(request_id, str):
            state.pending_tool_calls.resolve(request_id, env.get("response"))
    else:
        emit({"type": "error", "error": f"unknown envelope type: {msg_type}", "category": "claude_sdk_error"})


def _build_symphony_mcp_server(state: SessionState):  # pragma: no cover - SDK runtime
    """Register Symphony's exposed tools as in-process MCP entries.

    Currently only `linear_graphql` is wired (per SPEC §10.4). Each tool
    function emits a `tool_call` envelope and awaits Symphony's `tool_result`,
    so all auth/transport stays on the Symphony side.
    """

    schema = state.tool_schemas.get("linear_graphql", _LINEAR_GRAPHQL_FALLBACK_SCHEMA)

    @tool(
        "linear_graphql",
        "Execute a raw GraphQL query or mutation against Linear using "
        "Symphony's configured tracker auth.",
        schema,
    )
    async def linear_graphql(args: dict[str, Any]) -> dict[str, Any]:
        result = await forward_tool_call_to_symphony(
            state.pending_tool_calls,
            name="linear_graphql",
            input=args,
        )

        return translate_symphony_tool_result(result)

    return create_sdk_mcp_server(name="symphony", version="0.1.0", tools=[linear_graphql])


async def _handle_init(state: SessionState, env: dict[str, Any]) -> None:
    if not _SDK_AVAILABLE:
        emit(
            {
                "type": "error",
                "error": "claude-agent-sdk is not installed in the sidecar venv",
                "category": "claude_sidecar_not_found",
            }
        )
        return

    payload = build_options_payload(env)
    state.tool_schemas = extract_tool_schemas(env)
    payload["mcp_servers"] = {"symphony": _build_symphony_mcp_server(state)}
    # The underlying `claude` CLI is always launched with `--verbose` by the
    # SDK, so its stderr is unconditionally chatty. Forward it back to
    # Symphony as `log` envelopes only when `init.verbose_logging` is on;
    # otherwise discard it so it doesn't reach the orchestrator (and isn't
    # attached at all to ClaudeAgentOptions, letting the SDK drop it).
    if env.get("verbose_logging"):
        payload["stderr"] = lambda line: emit(
            {
                "type": "log",
                "level": "info",
                "source": "claude_cli",
                "message": line.rstrip(),
            }
        )
    else:
        payload["stderr"] = lambda _line: None
    options = ClaudeAgentOptions(**payload)
    state.client = ClaudeSDKClient(options=options)
    await state.client.__aenter__()
    emit({"type": "ready"})


async def _handle_turn(state: SessionState, env: dict[str, Any]) -> None:
    client = state.client
    if client is None:
        emit({"type": "error", "error": "turn before init", "category": "claude_sdk_error"})
        return

    prompt = env.get("prompt", "")
    if not isinstance(prompt, str) or not prompt:
        emit({"type": "error", "error": "turn.prompt missing", "category": "claude_sdk_error"})
        return

    try:
        await client.query(prompt)

        async for message in client.receive_response():
            await _forward_message(state, message)
    except Exception as exc:  # pragma: no cover - SDK runtime path
        emit(
            {
                "type": "error",
                "error": f"{type(exc).__name__}: {exc}",
                "category": "claude_sdk_error",
                "trace": traceback.format_exc(),
            }
        )


async def _forward_message(state: SessionState, message: Any) -> None:
    if _SDK_AVAILABLE and isinstance(message, SystemMessage):
        if getattr(message, "subtype", None) == "init":
            data = getattr(message, "data", {}) or {}
            session_id = data.get("session_id") if isinstance(data, dict) else None
            if session_id:
                state.session_id = session_id
                emit({"type": "system_init", "session_id": session_id})
        return

    if _SDK_AVAILABLE and isinstance(message, ResultMessage):
        emit(
            {
                "type": "turn_end",
                "stop_reason": getattr(message, "stop_reason", "end_turn"),
                "num_turns": getattr(message, "num_turns", 1),
                "usage": usage_to_envelope(getattr(message, "usage", None)),
                "session_id": state.session_id,
            }
        )
        return

    text = render_message_text(message)
    if text is not None:
        emit({"type": "assistant_message", "text": text, "session_id": state.session_id})


def render_message_text(message: Any) -> str | None:
    """Render an SDK Message's content blocks as folded text — keeps
    `tool_use`/`tool_result`/`thinking` visible inside the existing
    `assistant_message` envelope so we don't widen the wire protocol.
    """

    content = getattr(message, "content", None)
    if not content:
        return None

    parts: list[str] = []
    for block in content:
        rendered = _render_block(block)
        if rendered is not None:
            parts.append(rendered)

    return "\n".join(parts) if parts else None


def _render_block(block: Any) -> str | None:
    # Attribute-sniff (rather than `isinstance`) so the wire-helper tests can
    # pass `SimpleNamespace`s without importing `claude_agent_sdk`.
    text = getattr(block, "text", None)
    if isinstance(text, str):
        return text

    thinking = getattr(block, "thinking", None)
    if isinstance(thinking, str):
        return f"[thinking] {fold_text(thinking)}"

    tool_use_id = getattr(block, "tool_use_id", None)
    if isinstance(tool_use_id, str):
        # ToolResultBlock-shaped: tool_use_id + content (+ optional is_error).
        marker = (
            f"[tool_result {tool_use_id} is_error]"
            if bool(getattr(block, "is_error", False))
            else f"[tool_result {tool_use_id}]"
        )
        return f"{marker} {fold_text(getattr(block, 'content', ''))}"

    tool_use_name = getattr(block, "name", None)
    tool_use_input = getattr(block, "input", None)
    if isinstance(tool_use_name, str) and tool_use_input is not None:
        # ToolUseBlock / ServerToolUseBlock-shaped: name + id + input map.
        block_id = getattr(block, "id", "?")
        prefix = "server_tool_use" if "Server" in type(block).__name__ else "tool_use"
        return f"[{prefix} {tool_use_name}({block_id})] {fold_text(tool_use_input)}"

    return None


async def _handle_interrupt(state: SessionState) -> None:
    client = state.client
    if client is None:
        return

    interrupt = getattr(client, "interrupt", None)
    if interrupt is None:
        return

    await interrupt()


async def _handle_shutdown(state: SessionState) -> None:
    client = state.client
    if client is not None:
        await client.__aexit__(None, None, None)


async def _serve() -> None:
    """Sidecar main loop.

    `turn` envelopes are dispatched as background `asyncio.Task`s so the loop
    can keep reading stdin while a turn is in flight. This is required:
    while `_handle_turn` iterates `client.receive_response()`, the SDK
    invokes Symphony-provided MCP tools (e.g. `linear_graphql`), which
    `await` a future that can *only* be resolved by a `tool_result` envelope
    from Symphony. If the loop blocked on the turn, that envelope would
    never get read and the future would never resolve — Symphony's stall
    watchdog would fire after ~5 min. Other envelope types
    (`tool_result`, `permission_response`, `interrupt`, `shutdown`,
    `init`) are cheap and handled inline.
    """

    state = SessionState()
    turn_task: asyncio.Task[None] | None = None

    async for line in _stdin_lines():
        try:
            envelope = parse_line(line)
        except ValueError as exc:
            emit({"type": "error", "error": str(exc), "category": "claude_sdk_error"})
            continue
        except json.JSONDecodeError as exc:
            emit({"type": "error", "error": f"malformed json: {exc}", "category": "claude_sdk_error"})
            continue

        msg_type = envelope.get("type")

        if msg_type == "turn":
            if _turn_in_flight(turn_task):
                # Symphony's protocol expects one turn at a time. If a
                # second arrives, surface it rather than silently queuing.
                emit(
                    {
                        "type": "error",
                        "error": "turn already in progress; ignoring concurrent turn envelope",
                        "category": "claude_sdk_error",
                    }
                )
                continue

            turn_task = asyncio.create_task(_drive_safe(state, envelope))
            continue

        await _drive_safe(state, envelope)

        if msg_type == "shutdown":
            if _turn_in_flight(turn_task):
                turn_task.cancel()
                try:
                    await turn_task
                except (asyncio.CancelledError, Exception):
                    pass
            return


def _turn_in_flight(turn_task: asyncio.Task[None] | None) -> bool:
    return turn_task is not None and not turn_task.done()


async def _drive_safe(state: SessionState, envelope: dict[str, Any]) -> None:
    """Surface `_drive` errors as `error` envelopes — used both inline and as
    the entry point for backgrounded turn tasks, so a crash never goes silent.
    """

    try:
        await _drive(state, envelope)
    except Exception as exc:  # pragma: no cover - defence in depth
        emit(
            {
                "type": "error",
                "error": f"{type(exc).__name__}: {exc}",
                "category": "claude_sdk_error",
                "trace": traceback.format_exc(),
            }
        )


def main() -> int:
    """Entry point used by the ``[project.scripts]`` shim."""

    if os.environ.get("SYMPHONY_CLAUDE_AGENT_DRY_RUN") == "1":
        # Smoke mode: emit `ready` and exit. Useful for unit-level checks.
        emit({"type": "ready"})
        return 0

    try:
        asyncio.run(_serve())
    except KeyboardInterrupt:
        return 130

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
