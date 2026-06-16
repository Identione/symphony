"""Tests for the Symphony↔sidecar tool-call bridge.

The sidecar exposes Symphony tools (notably ``linear_graphql``) to Claude as
in-process MCP tools. When Claude calls one, the sidecar emits a ``tool_call``
envelope, blocks until Symphony writes back a ``tool_result``, and returns the
result to Claude. These tests cover that bridge in isolation — no SDK or
running event loop required beyond ``asyncio.run``.
"""

from __future__ import annotations

import asyncio
import io
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from symphony_claude_agent.sidecar import (  # noqa: E402
    PendingToolCalls,
    extract_tool_schemas,
    forward_tool_call_to_symphony,
    translate_symphony_tool_result,
)


def test_pending_tool_calls_register_and_resolve() -> None:
    pending = PendingToolCalls()

    async def scenario():
        future = pending.register("u-1")
        assert pending.has("u-1")

        pending.resolve("u-1", {"success": True, "data": "ok"})
        return await future

    result = asyncio.run(scenario())
    assert result == {"success": True, "data": "ok"}
    assert not pending.has("u-1")


def test_pending_tool_calls_resolve_unknown_id_is_noop() -> None:
    pending = PendingToolCalls()
    # Should silently no-op rather than raising — Symphony might race-send a
    # tool_result for a tool_use_id we never registered (out-of-band reply).
    pending.resolve("unknown", {"success": True})


def test_extract_tool_schemas_indexes_specs_by_name() -> None:
    """`init.tool_specs` is indexed by `name` so the MCP registrar can look schemas up."""

    env = {
        "type": "init",
        "tool_specs": [
            {
                "name": "linear_graphql",
                "description": "...",
                "inputSchema": {"type": "object", "required": ["query"]},
            },
            {
                "name": "other_tool",
                "inputSchema": {"type": "object"},
            },
        ],
    }

    assert extract_tool_schemas(env) == {
        "linear_graphql": {"type": "object", "required": ["query"]},
        "other_tool": {"type": "object"},
    }


def test_extract_tool_schemas_returns_empty_when_specs_missing() -> None:
    """No `tool_specs` field → empty dict so callers fall back to a default."""

    assert extract_tool_schemas({"type": "init"}) == {}


def test_extract_tool_schemas_skips_malformed_entries() -> None:
    """Defensive: a non-list `tool_specs` or non-dict entries are dropped silently."""

    assert extract_tool_schemas({"tool_specs": "not a list"}) == {}
    assert extract_tool_schemas({"tool_specs": [None, 1, "x"]}) == {}
    assert extract_tool_schemas({"tool_specs": [{"missing_name": True}]}) == {}


def test_translate_success_unwraps_output_field() -> None:
    """A success result forwards the inner GraphQL JSON, drops the wrapper."""

    inner = '{"data":{"viewer":{"id":"abc"}}}'
    result = {
        "success": True,
        "output": inner,
        "contentItems": [{"type": "inputText", "text": inner}],
    }

    translated = translate_symphony_tool_result(result)

    assert translated == {
        "content": [{"type": "text", "text": inner}],
        "is_error": False,
    }


def test_translate_failure_sets_is_error() -> None:
    """A failure result surfaces is_error=True so Claude can recover."""

    inner = '{"error":{"message":"GraphQL: bad query"}}'
    result = {
        "success": False,
        "output": inner,
        "contentItems": [{"type": "inputText", "text": inner}],
    }

    translated = translate_symphony_tool_result(result)

    assert translated == {
        "content": [{"type": "text", "text": inner}],
        "is_error": True,
    }


def test_translate_none_result_is_error() -> None:
    """A None result (Symphony port closed mid-call) surfaces as an error."""

    translated = translate_symphony_tool_result(None)

    assert translated == {
        "content": [{"type": "text", "text": ""}],
        "is_error": True,
    }


def test_translate_missing_output_field_falls_back() -> None:
    """Defensive: a dict without `output` is forwarded as JSON, not silently lost."""

    translated = translate_symphony_tool_result({"success": True, "answer": 42})

    assert translated["is_error"] is False
    assert len(translated["content"]) == 1
    assert translated["content"][0]["type"] == "text"
    # Body falls back to a JSON dump of the whole map so nothing is silently dropped.
    assert json.loads(translated["content"][0]["text"]) == {"success": True, "answer": 42}


def test_translate_caps_oversized_output_head_and_tail() -> None:
    """An oversized linear_graphql result is elided head+tail with a marker so
    it does not enter (and get re-read across) the conversation uncapped.

    Distinct from the log-only ``fold_text``: this caps what Claude actually
    sees, not just what gets logged.
    """

    from symphony_claude_agent.sidecar import _TOOL_RESULT_LIMIT

    body = "A" * 5000 + "Z" * 5000  # well over the cap
    result = {"success": True, "output": body}

    translated = translate_symphony_tool_result(result)
    text = translated["content"][0]["text"]

    assert translated["is_error"] is False
    assert len(text) < len(body)
    assert len(text) <= _TOOL_RESULT_LIMIT + 200  # cap + marker headroom
    assert text.startswith("A")  # head preserved
    assert text.endswith("Z")  # tail preserved
    assert "elided" in text  # omission is visible, not silent


def test_translate_leaves_small_output_verbatim() -> None:
    """An under-cap result is forwarded byte-for-byte (no marker injected)."""

    inner = '{"data":{"viewer":{"id":"abc"}}}'
    translated = translate_symphony_tool_result({"success": True, "output": inner})

    assert translated == {"content": [{"type": "text", "text": inner}], "is_error": False}


def test_translate_non_dict_result_is_error() -> None:
    """Defensive: a non-dict result is treated as a malformed reply."""

    translated = translate_symphony_tool_result("raw string")

    assert translated["is_error"] is True
    assert translated["content"][0]["type"] == "text"
    assert json.loads(translated["content"][0]["text"]) == "raw string"


def test_forward_tool_call_emits_envelope_and_waits() -> None:
    pending = PendingToolCalls()
    buf = io.StringIO()

    async def scenario():
        # Race: kick off the forward, then resolve the pending future.
        forward_task = asyncio.create_task(
            forward_tool_call_to_symphony(
                pending,
                name="linear_graphql",
                input={"query": "query { viewer { id } }"},
                emit_stream=buf,
                tool_use_id="u-fixed",
            )
        )

        # Give the forwarder a tick to emit and register.
        await asyncio.sleep(0)

        emitted = json.loads(buf.getvalue().strip())
        assert emitted == {
            "type": "tool_call",
            "tool_use_id": "u-fixed",
            "name": "linear_graphql",
            "input": {"query": "query { viewer { id } }"},
        }

        pending.resolve("u-fixed", {"success": True, "data": "viewer"})
        return await forward_task

    result = asyncio.run(scenario())
    assert result == {"success": True, "data": "viewer"}
