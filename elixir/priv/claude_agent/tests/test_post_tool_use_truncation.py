"""Verify the PostToolUse truncation hook (R2b) bounds native-tool cache-read cost.

A tool result, once returned, stays in the conversation and is re-sent
(`cache_read`) on every subsequent turn — so a single large `Read`/`Bash`
output is paid for ~Σ(turns) times. The sidecar registers a PostToolUse hook
that shrinks oversized string leaves in the tool response *in place* (preserving
the built-in tool's output schema so the SDK accepts the replacement) and tells
the model it can re-read a narrower slice.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from symphony_claude_agent import sidecar  # noqa: E402
from symphony_claude_agent.sidecar import (  # noqa: E402
    _make_post_tool_use_truncator,
    _truncate_tool_response,
    build_post_tool_use_hooks,
)


def test_short_string_is_left_unchanged() -> None:
    value, changed = _truncate_tool_response("hello", 100)
    assert value == "hello"
    assert changed is False


def test_long_string_is_elided_head_and_tail() -> None:
    text = "A" * 5_000 + "ZZZ"
    value, changed = _truncate_tool_response(text, 1_000)
    assert changed is True
    assert len(value) < len(text)
    assert value.startswith("A")
    assert value.endswith("ZZZ")  # tail is preserved
    assert "elided" in value


def test_nested_structure_is_preserved_and_only_long_leaves_shrink() -> None:
    # Mimics a Bash tool response shape; structure/keys must survive so the
    # SDK accepts the replacement.
    response = {
        "stdout": "X" * 4_000,
        "stderr": "short",
        "interrupted": False,
        "items": ["ok", "Y" * 4_000],
    }
    value, changed = _truncate_tool_response(response, 500)

    assert changed is True
    assert set(value.keys()) == {"stdout", "stderr", "interrupted", "items"}
    assert value["interrupted"] is False
    assert value["stderr"] == "short"
    assert len(value["stdout"]) < 4_000
    assert value["items"][0] == "ok"
    assert len(value["items"][1]) < 4_000


@pytest.mark.asyncio
async def test_hook_returns_updated_output_only_when_truncated() -> None:
    truncate = _make_post_tool_use_truncator(500)

    big = await truncate(
        {"hook_event_name": "PostToolUse", "tool_name": "Read", "tool_response": "B" * 5_000},
        "tool-1",
        {"signal": None},
    )
    assert big["hookSpecificOutput"]["hookEventName"] == "PostToolUse"
    assert "updatedToolOutput" in big["hookSpecificOutput"]
    assert len(big["hookSpecificOutput"]["updatedToolOutput"]) < 5_000

    # A small result is a no-op — no replacement, so the original is kept.
    small = await truncate(
        {"hook_event_name": "PostToolUse", "tool_name": "Read", "tool_response": "tiny"},
        "tool-2",
        {"signal": None},
    )
    assert small == {}


def test_build_hooks_disabled_when_limit_non_positive() -> None:
    assert build_post_tool_use_hooks(0) is None
    assert build_post_tool_use_hooks(-1) is None


def test_build_hooks_registers_post_tool_use_matcher_when_enabled() -> None:
    hooks = build_post_tool_use_hooks(8192)
    assert hooks is not None
    assert "PostToolUse" in hooks
    [matcher] = hooks["PostToolUse"]
    # The dominant native cost is Read/Bash; the matcher also covers the other
    # bulk-output readers. Truncation is conditional, so matching more is safe.
    for tool in ("Bash", "Read", "Grep", "Glob"):
        assert tool in matcher.matcher
    assert len(matcher.hooks) == 1
