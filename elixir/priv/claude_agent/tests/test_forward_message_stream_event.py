"""Verify ``_forward_message`` forwards partial-stream ``StreamEvent`` messages
as throttled ``assistant_delta`` envelopes.

These deltas are Symphony's continuous-activity signal during long model
generations: without them the orchestrator only hears discrete message
boundaries and the stall watchdog can fire mid-turn. The throttle coalesces
token-rate deltas down to at most one envelope per
``_STREAM_ACTIVITY_MIN_INTERVAL_S``.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import os
import sys
from typing import Any
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from claude_agent_sdk.types import StreamEvent  # noqa: E402

from symphony_claude_agent import sidecar  # noqa: E402
from symphony_claude_agent.sidecar import SessionState, _forward_message  # noqa: E402


def _record_emits():
    captured: list[dict[str, Any]] = []
    return captured, lambda env, stream=None: captured.append(env)


def _stream_event(session_id: str, event: dict[str, Any]) -> StreamEvent:
    return StreamEvent(
        uuid="evt-1",
        session_id=session_id,
        event=event,
        parent_tool_use_id=None,
    )


def _text_delta(text: str) -> dict[str, Any]:
    return {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}}


@pytest.mark.asyncio
async def test_text_delta_emits_assistant_delta_with_text() -> None:
    state = SessionState(session_id="sess-delta-1")
    captured, fake_emit = _record_emits()

    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, _stream_event("sess-delta-1", _text_delta("hi")))

    [delta] = [env for env in captured if env["type"] == "assistant_delta"]
    assert delta["session_id"] == "sess-delta-1"
    assert delta["text"] == "hi"


@pytest.mark.asyncio
async def test_second_delta_within_interval_is_throttled() -> None:
    state = SessionState(session_id="sess-delta-2")
    captured, fake_emit = _record_emits()

    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, _stream_event("sess-delta-2", _text_delta("a")))
        await _forward_message(state, _stream_event("sess-delta-2", _text_delta("b")))

    deltas = [env for env in captured if env["type"] == "assistant_delta"]
    assert len(deltas) == 1, f"expected the second delta to be throttled; got {deltas}"


@pytest.mark.asyncio
async def test_structural_event_emits_textless_activity() -> None:
    """A non-text stream event (ping, content_block_stop, …) still refreshes
    activity but carries no display text."""

    state = SessionState(session_id="sess-delta-3")
    captured, fake_emit = _record_emits()

    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, _stream_event("sess-delta-3", {"type": "ping"}))

    [delta] = [env for env in captured if env["type"] == "assistant_delta"]
    assert "text" not in delta
    assert delta["session_id"] == "sess-delta-3"
