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
import re
import sys
import traceback
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

try:  # pragma: no cover - py<3.9 only
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - py<3.9 only
    ZoneInfo = None  # type: ignore[assignment]

# ``claude_agent_sdk`` is a runtime dependency. Importing it lazily lets the
# unit-level smoke test verify the wire-protocol helpers without requiring the
# SDK to be installed.
try:  # pragma: no cover - import-time guard
    from claude_agent_sdk import (  # type: ignore[import-not-found]
        AssistantMessage,
        ClaudeAgentOptions,
        ClaudeSDKClient,
        HookMatcher,
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

# Length cap for a tool *result* that Claude actually consumes (not just logs).
# A linear_graphql result is pasted into the conversation and re-read on every
# subsequent turn, so an uncapped body is paid for ~Σ(turns) times via
# cache_read. 8 KiB keeps a generous head+tail while bounding that cost. This is
# deliberately distinct from `_RENDER_TEXT_LIMIT` (log-only) and `fold_text`.
_TOOL_RESULT_LIMIT = 8192

# Default per-call cap (bytes) for *native* tool output (Read/Bash/Grep/Glob)
# applied by the PostToolUse truncation hook (R2b). Same cache_read reasoning as
# `_TOOL_RESULT_LIMIT` — a returned tool result is re-sent on every later turn,
# so a large output is paid for ~Σ(turns) times — but more generous than the
# linear_graphql cap because a source-file Read needs room. Overridable per
# session via `init.tool_output_limit`; 0 disables the hook entirely.
_NATIVE_TOOL_OUTPUT_LIMIT = 16384

# Keywords for mapping exception messages to structured error codes.
_CONTEXT_WINDOW_KEYWORDS = frozenset(
    ["context window", "context_window", "context length", "context_length", "token limit"]
)
_RATE_LIMIT_KEYWORDS = frozenset(["rate limit", "rate_limit", "ratelimit", "ratelimited"])
_OVERLOADED_KEYWORDS = frozenset(["overloaded", "overload"])
_QUOTA_KEYWORDS = frozenset(["credit balance", "quota exceeded", "quota_exceeded", "billing"])
_INVALID_REQUEST_KEYWORDS = frozenset(["invalid request", "invalid_request"])


def _classify_from_message(msg: str) -> str:
    """Return an error code by scanning the lowercased message for known keywords."""
    lower = msg.lower()
    if any(kw in lower for kw in _CONTEXT_WINDOW_KEYWORDS):
        return "context_window_exhausted"
    if any(kw in lower for kw in _RATE_LIMIT_KEYWORDS):
        return "rate_limited"
    if any(kw in lower for kw in _OVERLOADED_KEYWORDS):
        return "overloaded"
    if any(kw in lower for kw in _QUOTA_KEYWORDS):
        return "quota_exceeded"
    if any(kw in lower for kw in _INVALID_REQUEST_KEYWORDS):
        return "invalid_request"
    return "unknown"


def _classify_sdk_error(exc: BaseException) -> str:
    """Map an SDK exception to a structured error code.

    Checks SDK-specific class hierarchy first, then falls back to keyword
    scanning of the string representation for ProcessError cases where the
    CLI embeds the upstream HTTP reason in its message.
    """
    if _SDK_AVAILABLE:
        try:
            from claude_agent_sdk._errors import (  # type: ignore[import-not-found]
                CLINotFoundError,
                ProcessError,
            )

            if isinstance(exc, CLINotFoundError):
                return "unknown"
            if isinstance(exc, ProcessError):
                return _classify_from_message(str(exc))
        except ImportError:
            pass
    return _classify_from_message(str(exc))


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


def _elide_head_tail(text: str, limit: int, marker: str) -> str:
    """Drop the middle of `text` to fit `limit`, keeping the head (where
    structure/keys usually live) and the tail (e.g. error suffixes). `marker` is
    formatted with `omitted` (the dropped char count) and spliced in between."""

    omitted = len(text) - limit
    head_len = limit // 2
    tail_len = limit - head_len
    return f"{text[:head_len]}{marker.format(omitted=omitted)}{text[-tail_len:]}"


def cap_tool_result_text(text: str, *, limit: int = _TOOL_RESULT_LIMIT) -> str:
    """Elide an oversized tool-result body head+tail with a visible marker.

    Unlike `fold_text` (log-only, tail-dropping), this caps what Claude *sees*.
    """

    if len(text) <= limit:
        return text

    return _elide_head_tail(text, limit, "\n…({omitted} chars elided)…\n")


def _elide_native_output(text: str, limit: int) -> str:
    """Head+tail elision for a native-tool output leaf, with a marker that tells
    the model the cut was Symphony's (not the tool's) and that it can re-read a
    narrower slice if it needs the elided portion."""

    return _elide_head_tail(
        text,
        limit,
        "\n…[Symphony elided {omitted} chars to bound cache-read cost; "
        "re-read a narrower range/offset if you need the rest]…\n",
    )


def _truncate_tool_response(value: Any, limit: int) -> tuple[Any, bool]:
    """Recursively shrink long string leaves in a tool response while preserving
    its structure (keys, list shape, scalar types). Keeping the shape intact is
    what lets the SDK accept the replacement for built-in tools, whose
    `updatedToolOutput` must match the tool's output schema. Returns
    `(new_value, truncated?)`.
    """

    if isinstance(value, str):
        if len(value) <= limit:
            return value, False
        return _elide_native_output(value, limit), True

    if isinstance(value, dict):
        changed = False
        out: dict[Any, Any] = {}
        for key, item in value.items():
            new_item, item_changed = _truncate_tool_response(item, limit)
            out[key] = new_item
            changed = changed or item_changed
        return out, changed

    if isinstance(value, list):
        changed = False
        out_list = []
        for item in value:
            new_item, item_changed = _truncate_tool_response(item, limit)
            out_list.append(new_item)
            changed = changed or item_changed
        return out_list, changed

    return value, False


def _make_post_tool_use_truncator(limit: int):
    """Build a PostToolUse hook callback that caps oversized native-tool output."""

    async def _truncate_hook(input_data: Any, _tool_use_id: Any, _context: Any) -> dict[str, Any]:
        response = input_data.get("tool_response") if isinstance(input_data, dict) else None
        if response is None:
            return {}

        new_response, changed = _truncate_tool_response(response, limit)
        if not changed:
            return {}

        return {
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "updatedToolOutput": new_response,
            }
        }

    return _truncate_hook


def build_post_tool_use_hooks(limit: int):
    """Assemble the `hooks` mapping for `ClaudeAgentOptions`. Returns `None` when
    truncation is disabled (`limit <= 0`) or the SDK is unavailable."""

    if not isinstance(limit, int) or limit <= 0 or not _SDK_AVAILABLE:
        return None

    return {
        "PostToolUse": [
            HookMatcher(
                matcher="Bash|Read|Grep|Glob",
                hooks=[_make_post_tool_use_truncator(limit)],
            )
        ]
    }


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

    return {
        "content": [{"type": "text", "text": cap_tool_result_text(text)}],
        "is_error": is_error,
    }


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
        "system_prompt": system_prompt,
    }

    # Only forward setting_sources when Symphony actually supplied one. When the
    # init envelope omits it, leave it off the payload so ClaudeAgentOptions
    # uses its own default (None -> the CLI loads all filesystem settings:
    # .claude/settings.json, project .mcp.json, CLAUDE.md), matching an
    # interactive `claude` run. An explicit [] (isolation) or subset is passed
    # through verbatim. Distinguish "absent" from "[]" — `or []` would conflate
    # them and silently force isolation.
    setting_sources = init_envelope.get("setting_sources")
    if setting_sources is not None:
        payload["setting_sources"] = setting_sources

    if init_envelope.get("model"):
        payload["model"] = init_envelope["model"]

    if init_envelope.get("max_turns") is not None:
        payload["max_turns"] = init_envelope["max_turns"]

    if init_envelope.get("max_budget_usd") is not None:
        payload["max_budget_usd"] = init_envelope["max_budget_usd"]

    if init_envelope.get("effort"):
        payload["effort"] = init_envelope["effort"]

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

    # R2b: cap oversized native-tool output (Read/Bash/Grep/Glob) so a single
    # large result isn't re-paid as cache_read on every subsequent turn.
    tool_output_limit = env.get("tool_output_limit", _NATIVE_TOOL_OUTPUT_LIMIT)
    hooks = build_post_tool_use_hooks(tool_output_limit)
    if hooks:
        payload["hooks"] = hooks
    # The underlying `claude` CLI is always launched with `--verbose` by the
    # SDK, so its stderr is unconditionally chatty. Forward it back to
    # Symphony as `log` envelopes only when `init.verbose_logging` is on;
    # otherwise install a no-op sink so the SDK's stderr pump still drains
    # the pipe (avoids a back-pressure stall when buffers fill) but nothing
    # reaches the orchestrator.
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
        emit({"type": "error", "error": "turn before init", "category": "claude_sdk_error", "error_code": "invalid_request"})
        return

    prompt = env.get("prompt", "")
    if not isinstance(prompt, str) or not prompt:
        emit({"type": "error", "error": "turn.prompt missing", "category": "claude_sdk_error", "error_code": "invalid_request"})
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
                "error_code": _classify_sdk_error(exc),
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
        # A budget (or other terminal) breach is *returned*, not raised: the SDK
        # sets is_error=True with an `error_*` subtype. Emitting a bare turn_end
        # for it makes Elixir treat the breach as a clean finish and relaunch
        # forever. Surface it as a structured error so the orchestrator can map
        # the subtype to a deterministic code and escalate instead.
        if getattr(message, "is_error", False):
            subtype = getattr(message, "subtype", None) or "unknown"
            emit(
                {
                    "type": "error",
                    "error": subtype,
                    "error_code": subtype,
                    "session_id": state.session_id,
                }
            )
            return

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

    if _SDK_AVAILABLE and isinstance(message, AssistantMessage):
        # A Claude subscription usage-limit (and sibling auth/billing/server
        # failures) is *not raised* — the SDK sets ``AssistantMessage.error`` to
        # a literal from ``AssistantMessageError`` and then yields a normal
        # ResultMessage. Rendering it as an ``assistant_message`` makes Elixir
        # treat the continuation as clean and re-prompt up to ``agent.max_turns``
        # times, burning the whole rate-limit window. Surface it as a structured
        # error (raw literal as error_code; atom mapping lives in Elixir
        # ``to_error_code``) and suppress the plain message. Embed any parseable
        # reset wall-clock as ``retry-after <seconds>`` so the existing Elixir
        # retry-after parser honors the real window with no wire-schema change.
        sdk_error = getattr(message, "error", None)
        if sdk_error:
            prose = render_message_text(message) or str(sdk_error)
            emit(
                {
                    "type": "error",
                    "error": _embed_retry_after(prose),
                    "error_code": sdk_error,
                    "session_id": state.session_id,
                }
            )
            return

        text = render_message_text(message)
        if text is not None:
            emit({"type": "assistant_message", "text": text, "session_id": state.session_id})

        # Per-API-call billing arrives on AssistantMessage (claude-agent-sdk
        # ≥0.1.49 — "Preserve per-turn usage on AssistantMessage"). Surface it
        # as a token_usage envelope so the orchestrator can show live tokens
        # before turn_end arrives. Suppress when usage is None to avoid
        # claiming a billing event that didn't happen.
        usage = getattr(message, "usage", None)
        if usage is not None:
            emit(
                {
                    "type": "token_usage",
                    "session_id": state.session_id,
                    "usage": usage_to_envelope(usage),
                }
            )
        return

    text = render_message_text(message)
    if text is not None:
        emit({"type": "assistant_message", "text": text, "session_id": state.session_id})


# Matches the subscription usage-limit reset notice, e.g.
# "You've hit your limit · resets 11:20am (Europe/Stockholm)".
_RESET_RE = re.compile(
    r"resets\s+(\d{1,2}):(\d{2})\s*([ap]m)\s*\(([^)]+)\)", re.IGNORECASE
)


def _parse_reset_seconds(text: str, now: datetime | None = None) -> int | None:
    """Parse a ``resets <h:mm><am|pm> (<tz>)`` notice into seconds-from-now.

    Returns the delay to the *next future* occurrence of that wall-clock time in
    the named timezone, or ``None`` if the notice is absent/unparseable or the
    timezone is unknown — callers then omit the hint rather than guess.
    """

    if ZoneInfo is None:
        return None
    match = _RESET_RE.search(text or "")
    if match is None:
        return None

    hour12, minute, meridiem, tz_name = match.groups()
    try:
        tz = ZoneInfo(tz_name.strip())
    except Exception:  # unknown/invalid tz name
        return None

    hour = int(hour12) % 12
    if meridiem.lower() == "pm":
        hour += 12

    now = now or datetime.now(timezone.utc)
    now_tz = now.astimezone(tz)
    target = now_tz.replace(
        hour=hour, minute=int(minute), second=0, microsecond=0
    )
    if target <= now_tz:
        target += timedelta(days=1)

    return int((target - now_tz).total_seconds())


def _embed_retry_after(prose: str) -> str:
    """Append a ``retry-after <seconds>`` hint to the error prose when the reset
    wall-clock is parseable, so the existing Elixir parser
    (``agent_runner.parse_retry_after/1``) honors the real window without any
    wire-schema change. Leaves the prose untouched otherwise.
    """

    seconds = _parse_reset_seconds(prose)
    if seconds is None or seconds <= 0:
        return prose
    return f"{prose} retry-after {seconds}"


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
            emit({"type": "error", "error": str(exc), "category": "claude_sdk_error", "error_code": "invalid_request"})
            continue
        except json.JSONDecodeError as exc:
            emit({"type": "error", "error": f"malformed json: {exc}", "category": "claude_sdk_error", "error_code": "invalid_request"})
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
                        "error_code": "invalid_request",
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
                "error_code": _classify_sdk_error(exc),
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
