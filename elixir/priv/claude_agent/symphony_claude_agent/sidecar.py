"""Symphony Claude Agent SDK sidecar entrypoint.

Long-lived subprocess that hosts the Claude Agent SDK and bridges Symphony
over a line-delimited JSON wire protocol on stdio (SPEC.md §10.8).

The protocol is intentionally narrow: see priv/claude_agent/README.md for the
envelope vocabulary. Denial rests on `permission_mode=dontAsk` plus the
Elixir-supplied `allowed_tools`/`disallowed_tools` whitelist — anything not
on that whitelist is rejected by the SDK itself. The PreToolUse/PostToolUse
hooks defined here (`build_tool_lifecycle_hooks`,
`build_post_tool_use_hooks`) are lifecycle notifications and output-size
caps only; they never deny a tool call.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import sys
import time
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


# Partial-message streaming type. Imported separately from the core SDK block so
# that a future SDK build which renames/drops it degrades to "no deltas
# forwarded" instead of disabling the whole sidecar.
try:  # pragma: no cover - import-time guard
    from claude_agent_sdk import StreamEvent  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover
    StreamEvent = None  # type: ignore[assignment]

# Minimum wall-clock gap between forwarded partial-stream activity envelopes. 1s
# keeps the orchestrator's stall watchdog (default 300s) well fed while
# coalescing token-rate deltas down to a trickle.
_STREAM_ACTIVITY_MIN_INTERVAL_S = 1.0


CLAUDE_CODE_SYSTEM_PROMPT_PRESET = {"type": "preset", "preset": "claude_code"}


# Env overrides forced onto the spawned claude CLI for every sidecar session.
#
# ``ENABLE_CLAUDEAI_MCP_SERVERS=0`` keeps the operator's personal claude.ai MCP
# integrations (Google Drive, the Linear plugin, …) out of the unattended agent.
# Those servers are irrelevant to orchestration — the workflow body even tells
# the agent never to call ``mcp__plugin_linear_linear__*`` — and, worse, they
# bloat the CLI's "tool search" deferred pool. Once the available-tool count
# crosses the CLI's threshold, in-process MCP tools are deferred into a
# searchable pool that drops ``mcp__symphony_workpad__sync_workpad`` (it sorts
# after ``mcp__symphony__linear_graphql``), so the agent's ``ToolSearch`` can't
# find it and every workpad sync silently falls back to ``linear_graphql`` —
# defeating sync_workpad's purpose of keeping the multi-KB body out of the
# model's token stream. Dropping the claude.ai servers shrinks the pool so
# sync_workpad survives. ``options.env`` overrides the spawned CLI's inherited
# process env (per the SDK transport).
#
# ``CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`` keeps delegated subagents inside the
# turn. Since CLI 2.1.198 the Agent tool backgrounds by default and the per-call
# ``run_in_background`` is the *model's* choice, so a delegating agent gets an
# "Async agent launched successfully" ack instead of findings, ends the turn
# having done nothing, and its late ``Task*`` traffic lands in whatever turn
# opens next (claude-code#788). That is doubly fatal here: Symphony drains
# ``receive_response()`` to ``ResultMessage`` and then leaves the stream unread
# until the orchestrator starts the next continuation turn, which is exactly the
# window that bug needs. This env var is the only lever that actually forces
# synchronous execution — ``AgentDefinition.background=False`` is inert, and
# prompt phrasing is persuasion, not a guarantee. Measured A/B on the bundled
# CLI 2.1.191: without it, one Agent call, a 934-char launch ack, zero inner
# subagent tool calls, no answer; with it, the same call returns real findings
# and the subagent's own tool calls arrive tagged with ``parent_tool_use_id``.
#
# ``CLAUDE_CODE_THISTLE_GREBE=default`` opts out of the CLI's server-toggleable
# "subagent steer" experiment (GrowthBook flag ``tengu_thistle_grebe``, shipped
# in CLI 2.1.224): any non-default steer strips the Agent tool's encouraging
# when-to-use text, and ``counter_steer`` injects a system-prompt block telling
# the model to do bounded work inline instead of delegating. Symphony's
# workflow contract treats delegation as an execution gate, so a remote flag
# flip would silently invert measured behavior with no code change on our side.
_SIDECAR_CLI_ENV: dict[str, str] = {
    "ENABLE_CLAUDEAI_MCP_SERVERS": "0",
    "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
    "CLAUDE_CODE_THISTLE_GREBE": "default",
}

_TOOL_VISIBILITY_LOG_SOURCE = "claude_tool_visibility"
_TOOL_VISIBILITY_LOG_LIMIT = 1200


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

# Claude Code sometimes reports subscription exhaustion as ordinary assistant
# prose without setting AssistantMessage.error. Keep this deliberately narrow so
# normal product text containing "limit" does not become a synthetic failure.
_USAGE_LIMIT_PROSE_RE = re.compile(
    r"\b(?:you(?:'|’)ve|you have)\s+hit\s+your\s+limit\b.*\bresets\b",
    re.IGNORECASE | re.DOTALL,
)

# A 401 from api.anthropic.com surfaces the same way (plain prose, no
# AssistantMessage.error). Requires both "failed to authenticate" and "401" so
# product copy mentioning authentication doesn't become a synthetic failure.
_AUTH_FAILURE_PROSE_RE = re.compile(
    r"failed\s+to\s+authenticate\b.*\b401\b",
    re.IGNORECASE | re.DOTALL,
)


# Upstream HTTP status → ``AssistantMessageError`` literal. Mirrors the
# vocabulary the Elixir ``Claude.AppServer.to_error_code/1`` maps from. Used
# for both ``SystemMessage(subtype="api_error")`` and
# ``ResultMessage(api_error_status=...)`` paths so a session-wide upstream
# failure surfaces on the first occurrence instead of churning ``agent.max_turns``.
_HTTP_STATUS_TO_ERROR_CODE = {
    401: "authentication_failed",
    402: "billing_error",
    413: "context_window_exhausted",
    429: "rate_limit",
    500: "server_error",
    502: "server_error",
    503: "server_error",
    504: "server_error",
    529: "server_error",
}


def _http_status_to_error_code(status: int | None) -> str:
    """Map an upstream HTTP status to the SDK error literal Elixir maps from."""
    if status is None:
        return "unknown"
    if status in _HTTP_STATUS_TO_ERROR_CODE:
        return _HTTP_STATUS_TO_ERROR_CODE[status]
    if 400 <= status < 500:
        return "invalid_request"
    if 500 <= status < 600:
        return "server_error"
    return "unknown"


def _coerce_status(value: Any) -> int | None:
    """Return ``value`` as an int if it parses as a positive HTTP status, else None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, str):
        try:
            parsed = int(value.strip())
        except ValueError:
            return None
        return parsed if parsed > 0 else None
    return None


# Keys an upstream payload may hold the HTTP status under. Walked breadth-first
# at every nesting level so we don't get fooled by alternate schemas like
# ``{"error":{"response":{"status":401}}}``. Keep narrow — adding generic keys
# (e.g. ``code``) risks colliding with non-status int fields.
_STATUS_KEYS = ("status", "status_code", "statusCode", "http_status")
_NESTING_KEYS = ("error", "response", "body", "details", "data")


def _extract_api_error_status(data: dict[str, Any]) -> int | None:
    """Best-effort dig out the HTTP status from a SystemMessage api_error payload.

    Walks both the canonical ``data["error"]["status"]`` shape and observed
    variants where the upstream response is wrapped under ``response`` /
    ``body`` etc. Accepts string-valued statuses (some upstream frames emit
    ``"401"`` rather than ``401``). Bounded BFS so a malformed cycle can't loop.
    """

    seen: set[int] = set()
    queue: list[Any] = [data]
    visits = 0
    while queue and visits < 32:
        visits += 1
        node = queue.pop(0)
        if not isinstance(node, dict):
            continue
        node_id = id(node)
        if node_id in seen:
            continue
        seen.add(node_id)
        for key in _STATUS_KEYS:
            if key in node:
                status = _coerce_status(node[key])
                if status is not None:
                    return status
        for key in _NESTING_KEYS:
            if key in node:
                queue.append(node[key])
    return None


def _render_upstream_detail(data: dict[str, Any]) -> str | None:
    """Best-effort one-line render of the upstream error's ``type`` / ``message``
    for operator triage. Walks the same nesting keys ``_extract_api_error_status``
    does so the detail stays close to the canonical payload shape."""

    seen: set[int] = set()
    queue: list[Any] = [data]
    visits = 0
    while queue and visits < 32:
        visits += 1
        node = queue.pop(0)
        if not isinstance(node, dict):
            continue
        node_id = id(node)
        if node_id in seen:
            continue
        seen.add(node_id)
        msg = node.get("message")
        typ = node.get("type")
        if isinstance(msg, str) and msg.strip():
            return f"{typ}: {msg}" if isinstance(typ, str) and typ else msg
        for key in _NESTING_KEYS:
            if key in node:
                queue.append(node[key])
    return None


def _extract_retry_after_seconds(data: dict[str, Any]) -> int | None:
    """Pull a ``Retry-After`` header value out of a SystemMessage api_error
    payload. The CLI surfaces it under ``data["error"]["headers"]`` with case-
    insensitive keys; accept both ``retry-after`` and ``Retry-After``."""

    seen: set[int] = set()
    queue: list[Any] = [data]
    visits = 0
    while queue and visits < 32:
        visits += 1
        node = queue.pop(0)
        if not isinstance(node, dict):
            continue
        node_id = id(node)
        if node_id in seen:
            continue
        seen.add(node_id)
        headers = node.get("headers")
        if isinstance(headers, dict):
            for hkey, hval in headers.items():
                if isinstance(hkey, str) and hkey.lower() == "retry-after":
                    secs = _coerce_status(hval)
                    if secs is not None:
                        return secs
        for key in _NESTING_KEYS:
            if key in node:
                queue.append(node[key])
    return None


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

# Mirrors `@sync_workpad_input_schema` in dynamic_tool.ex. Used only when
# `init.tool_specs` is absent (older Symphony / dry-run path).
_SYNC_WORKPAD_FALLBACK_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["issue_id"],
    "properties": {
        "issue_id": {
            "type": "string",
            "description": 'Linear issue identifier (e.g. "ENG-123") or internal UUID.',
        },
        "file_path": {
            "type": "string",
            "description": (
                "Path to a local markdown file whose contents become the comment"
                " body. Required (unless the workpad_path alias is given)."
            ),
        },
        "workpad_path": {
            "type": "string",
            "description": "Alias for file_path; ignored when file_path is present.",
        },
        "comment_id": {
            "type": "string",
            "description": "Existing comment ID to update. Omit to create a new comment.",
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
    # Monotonic timestamp of the last forwarded `assistant_delta`, for throttling.
    stream_activity_monotonic: float = 0.0
    # Retry-after (seconds) recovered from the most recent api_error payload's
    # ``Retry-After`` header. SystemMessage api_error carries the header;
    # ResultMessage(api_error_status=…) that follows does not, so the orchestrator
    # would otherwise lose the upstream reset window. Pinned here so a 429
    # ResultMessage envelope inherits the value the SystemMessage saw first.
    last_api_retry_after_seconds: int | None = None


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


# Native tools whose execution can be long enough to matter for stall detection.
_TOOL_LIFECYCLE_MATCHER = "Bash|Read|Grep|Glob"


def _make_tool_lifecycle_hook(event_type: str):
    """Build a hook that emits a `tool_started`/`tool_finished` envelope.

    These let the orchestrator tell a long *native* tool call (e.g. a build) —
    which is silent on the wire while it runs — apart from a genuine stall, so
    it can apply the longer tool-stall window instead of restarting the
    session. The hook is a pure notification: it returns `{}` (no directive).
    """

    async def _hook(input_data: Any, tool_use_id: Any, _context: Any) -> dict[str, Any]:
        name = input_data.get("tool_name") if isinstance(input_data, dict) else None
        envelope: dict[str, Any] = {"type": event_type, "tool_use_id": tool_use_id}
        if name:
            envelope["name"] = name
        emit(envelope)
        return {}

    return _hook


def build_tool_lifecycle_hooks():
    """PreToolUse/PostToolUse hooks emitting native-tool lifecycle envelopes.
    Returns `None` when the SDK is unavailable."""

    if not _SDK_AVAILABLE:
        return None

    return {
        "PreToolUse": [
            HookMatcher(
                matcher=_TOOL_LIFECYCLE_MATCHER,
                hooks=[_make_tool_lifecycle_hook("tool_started")],
            )
        ],
        "PostToolUse": [
            HookMatcher(
                matcher=_TOOL_LIFECYCLE_MATCHER,
                hooks=[_make_tool_lifecycle_hook("tool_finished")],
            )
        ],
    }


def merge_hook_maps(*hook_maps):
    """Combine several `{event: [HookMatcher, …]}` maps into one, concatenating
    the matcher lists per event. Returns `None` when nothing is contributed."""

    merged: dict[str, list[Any]] = {}
    for hook_map in hook_maps:
        if not hook_map:
            continue
        for event, matchers in hook_map.items():
            merged.setdefault(event, []).extend(matchers)

    return merged or None


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

    # Force the sidecar CLI env overrides (keep the operator's personal claude.ai
    # MCP servers out of the deferred tool pool so sync_workpad isn't squeezed
    # out). An explicit `env` in the init envelope merges on top, letting an
    # operator re-tune without a code change.
    env: dict[str, str] = dict(_SIDECAR_CLI_ENV)
    caller_env = init_envelope.get("env")
    if isinstance(caller_env, dict):
        env.update({str(k): str(v) for k, v in caller_env.items()})
    payload["env"] = env

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

# asyncio.StreamReader defaults to a 64 KiB line limit; Symphony envelopes
# (e.g. a large linear_graphql tool_result relayed from the Elixir side,
# which does not cap it) can easily exceed that, so give ourselves headroom.
_STDIN_LINE_LIMIT = 16 * 1024 * 1024


async def _stdin_lines():
    """Async generator yielding stripped, non-empty stdin lines."""

    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(loop=loop, limit=_STDIN_LINE_LIMIT)
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


def build_symphony_mcp_servers(state: SessionState) -> dict[str, Any]:
    """Register Symphony's exposed tools as in-process MCP servers.

    Each tool function emits a `tool_call` envelope and awaits Symphony's
    `tool_result`, so all auth/transport stays on the Symphony side.

    `linear_graphql` and `sync_workpad` are deliberately split across *separate*
    sdk MCP servers rather than co-located under one `symphony` server. The
    bundled Claude CLI surfaces only the first tool of a single in-process (sdk)
    MCP server to the model, so co-locating them silently hid `sync_workpad`:
    agents only ever saw `mcp__symphony__linear_graphql` and fell back to raw
    `linear_graphql` for workpad syncs (0 `sync_workpad` calls across every
    instance). One tool per server sidesteps that. The tool the model sees is
    `mcp__symphony_workpad__sync_workpad`; the forwarded `tool_call` envelope
    still carries the bare name `sync_workpad`, so Symphony's routing is
    unchanged.
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

    sw_schema = state.tool_schemas.get("sync_workpad", _SYNC_WORKPAD_FALLBACK_SCHEMA)

    @tool(
        "sync_workpad",
        "Create or update a workpad comment on a Linear issue. Reads the body "
        "from a local file to keep the conversation context small.",
        sw_schema,
    )
    async def sync_workpad(args: dict[str, Any]) -> dict[str, Any]:
        result = await forward_tool_call_to_symphony(
            state.pending_tool_calls,
            name="sync_workpad",
            input=args,
        )

        return translate_symphony_tool_result(result)

    return {
        "symphony": create_sdk_mcp_server(
            name="symphony", version="0.1.0", tools=[linear_graphql]
        ),
        "symphony_workpad": create_sdk_mcp_server(
            name="symphony_workpad", version="0.1.0", tools=[sync_workpad]
        ),
    }


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
    payload["mcp_servers"] = build_symphony_mcp_servers(state)

    # R2b: cap oversized native-tool output (Read/Bash/Grep/Glob) so a single
    # large result isn't re-paid as cache_read on every subsequent turn.
    tool_output_limit = env.get("tool_output_limit", _NATIVE_TOOL_OUTPUT_LIMIT)
    # Always register native-tool lifecycle hooks (stall keepalive); add the
    # output-truncation hook on top when a positive limit is configured.
    hooks = merge_hook_maps(
        build_tool_lifecycle_hooks(),
        build_post_tool_use_hooks(tool_output_limit),
    )
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


def _stream_event_text(message: Any) -> str | None:
    """Best-effort incremental text from a StreamEvent.

    Returns delta text for `content_block_delta` text/thinking events, or `None`
    for structural events (message_start, ping, content_block_stop, …) — those
    still count as activity but carry no display text.
    """
    event = getattr(message, "event", None)
    if not isinstance(event, dict) or event.get("type") != "content_block_delta":
        return None
    delta = event.get("delta")
    if not isinstance(delta, dict):
        return None
    if delta.get("type") == "text_delta":
        return delta.get("text") or None
    if delta.get("type") == "thinking_delta":
        return delta.get("thinking") or None
    return None


def summarize_mcp_server_status(data: Any) -> str | None:
    """One-line ``name=status, …`` summary of the SDK init message's
    ``mcp_servers`` list, or ``None`` when the payload carries no server list.

    The SDK init handshake reports each MCP server's connection status; an
    in-process sdk MCP server that fails to register (e.g. ``symphony_workpad``,
    see claude-agent-sdk-python#207) shows up here as ``failed`` or is absent
    entirely. Surfacing it in the structured log turns a silently-missing tool
    into an observable fact instead of an inference from zero tool calls.
    """

    if not isinstance(data, dict):
        return None
    servers = data.get("mcp_servers")
    if not isinstance(servers, list):
        return None
    parts = [
        f"{s.get('name')}={s.get('status')}" for s in servers if isinstance(s, dict)
    ]
    return ", ".join(parts) if parts else "(none)"


def tool_visibility_diagnostic(text: str | None) -> str | None:
    """Extract the small ToolSearch/sync_workpad visibility signal from a
    rendered assistant message.

    The full assistant stream is too noisy for normal daemon logs, but this
    investigation needs a durable record of whether ``ToolSearch`` found or
    missed ``mcp__symphony_workpad__sync_workpad`` in real runs.
    """

    if not text:
        return None

    interesting = (
        "mcp__symphony_workpad__sync_workpad" in text
        or "No matching deferred tools found" in text
        or ("ToolSearch" in text and "symphony" in text)
    )
    if not interesting:
        return None

    return fold_text(text, limit=_TOOL_VISIBILITY_LOG_LIMIT)


def emit_tool_visibility_log(message: str) -> None:
    emit(
        {
            "type": "log",
            "level": "info",
            "source": _TOOL_VISIBILITY_LOG_SOURCE,
            "message": message,
        }
    )


def emit_assistant_message(state: SessionState, text: str) -> None:
    # Both AssistantMessage paths (the SDK-typed branch and the fallback render)
    # forward assistant prose the same way: surface a tool-visibility diagnostic
    # first if the text trips one, then emit the message. Keep that pairing in one
    # place so the diagnostic check can't drift between the two call sites.
    diagnostic = tool_visibility_diagnostic(text)
    if diagnostic is not None:
        emit_tool_visibility_log(diagnostic)
    emit({"type": "assistant_message", "text": text, "session_id": state.session_id})


async def _forward_message(state: SessionState, message: Any) -> None:
    # Partial-message streaming: forward a throttled `assistant_delta` so the
    # orchestrator sees continuous activity during long model generations.
    # Without it, Symphony only hears discrete message boundaries and the stall
    # watchdog can fire mid-turn. StreamEvents flow because
    # `include_partial_messages` is set in build_options_payload.
    # SCOPE: this covers model-generation silence only — a long *native tool*
    # call (e.g. a container build) emits no StreamEvents and still needs
    # separate tool-lifecycle forwarding.
    if _SDK_AVAILABLE and StreamEvent is not None and isinstance(message, StreamEvent):
        now = time.monotonic()
        if now - state.stream_activity_monotonic >= _STREAM_ACTIVITY_MIN_INTERVAL_S:
            state.stream_activity_monotonic = now
            envelope: dict[str, Any] = {
                "type": "assistant_delta",
                "session_id": state.session_id,
            }
            text = _stream_event_text(message)
            if text:
                envelope["text"] = text[:500]
            emit(envelope)
        return
    if _SDK_AVAILABLE and isinstance(message, SystemMessage):
        subtype = getattr(message, "subtype", None)
        data = getattr(message, "data", {}) or {}
        if subtype == "init":
            session_id = data.get("session_id") if isinstance(data, dict) else None
            if session_id:
                state.session_id = session_id
                emit({"type": "system_init", "session_id": session_id})
            # Surface the per-server MCP connection status from the init
            # handshake so a `failed`/missing in-process sdk MCP server (notably
            # symphony_workpad, see claude-agent-sdk-python#207) is observable in
            # the structured log instead of silently swallowing its tool. One
            # low-volume line per session.
            status = summarize_mcp_server_status(data)
            if status is not None:
                emit_tool_visibility_log(f"mcp_servers init status: {status}")
            return
        # The Claude CLI subprocess forwards upstream HTTP errors from
        # api.anthropic.com as ``{"type":"system","subtype":"api_error",
        # "error":{"status":401,"headers":{"retry-after":"42"},...}}``.
        # Silently dropping these makes Elixir re-prompt through the
        # continuation loop until ``agent.max_turns``; surface them as a
        # structured error so a session-wide auth/billing/rate-limit wall
        # escalates on the first occurrence, embedding the Retry-After header
        # as a ``retry-after <seconds>`` substring so Elixir's existing
        # parser (added in #64) honors the real reset window.
        if subtype == "api_error":
            data_dict = data if isinstance(data, dict) else {}
            status = _extract_api_error_status(data_dict)
            retry_after = _extract_retry_after_seconds(data_dict)
            # Pin the retry-after on the session so a subsequent
            # ResultMessage(api_error_status=…) — which carries no headers —
            # inherits the upstream reset window the SystemMessage saw first.
            if retry_after is not None:
                state.last_api_retry_after_seconds = retry_after
            # An api_error subtype is always a real upstream failure; even
            # when we cannot recover the status digit (alternate schema,
            # missing field), prefer a deterministic ``:invalid_request``
            # over ``:unknown`` so the IDE-73 pipeline picks it up instead of
            # the transient-retry path that runs out the ``agent.max_turns``
            # clock.
            code = _http_status_to_error_code(status) if status is not None else "invalid_request"
            message = (
                f"HTTP {status} from api.anthropic.com"
                if status is not None
                else "api_error from api.anthropic.com"
            )
            upstream_detail = _render_upstream_detail(data_dict)
            if upstream_detail:
                message = f"{message}: {upstream_detail}"
            if retry_after is not None:
                message = f"{message} retry-after {retry_after}"
            emit(
                {
                    "type": "error",
                    "error": message,
                    "error_code": code,
                    "session_id": state.session_id,
                }
            )
            return
        return

    if _SDK_AVAILABLE and isinstance(message, ResultMessage):
        # A budget (or other terminal) breach is *returned*, not raised: the SDK
        # sets is_error=True with an `error_*` subtype. Emitting a bare turn_end
        # for it makes Elixir treat the breach as a clean finish and relaunch
        # forever. Surface it as a structured error so the orchestrator can map
        # the subtype to a deterministic code and escalate instead.
        if getattr(message, "is_error", False):
            api_status = getattr(message, "api_error_status", None)
            subtype = getattr(message, "subtype", None) or "unknown"
            # An upstream API failure surfaces as ``is_error=True``,
            # ``subtype="success"``, and the HTTP status in ``api_error_status``
            # (claude-agent-sdk: emitted by the CLI since v2.1.110). Mapping
            # ``subtype`` here would yield the literal ``"success"`` which
            # Elixir's ``to_error_code/1`` treats as ``:unknown`` (transient,
            # retries forever). Map the status to the upstream error literal.
            # ResultMessage carries no Retry-After header; if the preceding
            # SystemMessage(api_error) surfaced one, inherit it from
            # SessionState so the orchestrator still sees the real reset.
            code = (
                _http_status_to_error_code(api_status)
                if api_status is not None
                else subtype
            )
            if api_status is not None:
                message_text = f"HTTP {api_status}"
            else:
                message_text = subtype
            if state.last_api_retry_after_seconds is not None:
                message_text = (
                    f"{message_text} retry-after "
                    f"{state.last_api_retry_after_seconds}"
                )
            emit(
                {
                    "type": "error",
                    "error": message_text,
                    "error_code": code,
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
        prose_error = _assistant_prose_error_code(text)
        if prose_error:
            emit(
                {
                    "type": "error",
                    "error": _embed_retry_after(text or prose_error),
                    "error_code": prose_error,
                    "session_id": state.session_id,
                }
            )
            return

        if text is not None:
            emit_assistant_message(state, text)

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
        emit_assistant_message(state, text)


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


def _assistant_prose_error_code(prose: str | None) -> str | None:
    """Classify SDK assistant prose that actually represents a terminal error.

    The SDK normally sets ``AssistantMessage.error`` for this, but observed
    Claude Code traces also show the same usage-limit notice arriving as plain
    text with ``error=None``. Returning the raw SDK-compatible literal lets the
    existing Elixir mapping and retry policy handle it as ``:rate_limited``.
    """

    if not prose:
        return None
    if _USAGE_LIMIT_PROSE_RE.search(prose):
        return "rate_limit"
    if _AUTH_FAILURE_PROSE_RE.search(prose):
        return "authentication_failed"
    return None


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
