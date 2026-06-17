"""Verify the native-tool lifecycle hooks emit ``tool_started``/``tool_finished``
envelopes and compose with the output-truncation hook.

These envelopes let Symphony's orchestrator tell a long native tool call (e.g. a
build) — silent on the wire while it runs — apart from a genuine stall, so it
applies the longer tool-stall window instead of restarting the session.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import os
import sys
from typing import Any
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from symphony_claude_agent import sidecar  # noqa: E402
from symphony_claude_agent.sidecar import (  # noqa: E402
    build_post_tool_use_hooks,
    build_tool_lifecycle_hooks,
    merge_hook_maps,
)


def _record_emits():
    captured: list[dict[str, Any]] = []
    return captured, lambda env, stream=None: captured.append(env)


def test_lifecycle_hooks_register_pre_and_post() -> None:
    hooks = build_tool_lifecycle_hooks()
    assert hooks is not None
    assert set(hooks) == {"PreToolUse", "PostToolUse"}


@pytest.mark.asyncio
async def test_pre_tool_use_emits_tool_started() -> None:
    hook = build_tool_lifecycle_hooks()["PreToolUse"][0].hooks[0]
    captured, fake_emit = _record_emits()

    with patch.object(sidecar, "emit", side_effect=fake_emit):
        result = await hook({"tool_name": "Bash"}, "tu-1", None)

    assert result == {}
    [env] = captured
    assert env["type"] == "tool_started"
    assert env["name"] == "Bash"
    assert env["tool_use_id"] == "tu-1"


@pytest.mark.asyncio
async def test_post_tool_use_emits_tool_finished() -> None:
    hook = build_tool_lifecycle_hooks()["PostToolUse"][0].hooks[0]
    captured, fake_emit = _record_emits()

    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await hook({"tool_name": "Bash"}, "tu-2", None)

    [env] = captured
    assert env["type"] == "tool_finished"
    assert env["tool_use_id"] == "tu-2"


def test_merge_keeps_lifecycle_and_truncation_on_post_tool_use() -> None:
    merged = merge_hook_maps(build_tool_lifecycle_hooks(), build_post_tool_use_hooks(8192))

    assert "PreToolUse" in merged
    # PostToolUse carries both the lifecycle matcher and the truncation matcher.
    assert len(merged["PostToolUse"]) == 2


def test_merge_drops_none_truncation_when_limit_disabled() -> None:
    merged = merge_hook_maps(build_tool_lifecycle_hooks(), build_post_tool_use_hooks(0))

    # Lifecycle hooks still register even when truncation is disabled.
    assert len(merged["PostToolUse"]) == 1
    assert "PreToolUse" in merged
