"""Verify ``_forward_message`` emits a ``token_usage`` envelope from each
``AssistantMessage`` carrying live per-API-call billing.

This is the live signal that drives Symphony's mid-turn token counters; the
authoritative ``turn_end`` envelope from ``ResultMessage.usage`` arrives only
when the whole turn finishes.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import os
import sys
from typing import Any
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from claude_agent_sdk.types import AssistantMessage, ResultMessage  # noqa: E402

from symphony_claude_agent import sidecar  # noqa: E402
from symphony_claude_agent.sidecar import SessionState, _forward_message  # noqa: E402


def _record_emits():
    captured: list[dict[str, Any]] = []
    return captured, lambda env, stream=None: captured.append(env)


@pytest.mark.asyncio
async def test_forward_message_assistant_emits_token_usage_envelope() -> None:
    state = SessionState(session_id="sess-token-usage-1")
    msg = AssistantMessage(
        content=[],
        model="claude-sonnet-4-6",
        usage={
            "input_tokens": 1234,
            "output_tokens": 56,
            "cache_creation_input_tokens": 7,
            "cache_read_input_tokens": 89,
        },
    )

    captured, fake_emit = _record_emits()

    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    types = [env["type"] for env in captured]
    assert "token_usage" in types, (
        f"expected a token_usage envelope alongside assistant_message; got {types}"
    )

    [token_envelope] = [env for env in captured if env["type"] == "token_usage"]
    assert token_envelope["session_id"] == "sess-token-usage-1"
    assert token_envelope["usage"] == {
        "input_tokens": 1234,
        "output_tokens": 56,
        "cache_creation_input_tokens": 7,
        "cache_read_input_tokens": 89,
    }


@pytest.mark.asyncio
async def test_forward_message_assistant_without_usage_does_not_emit_token_usage() -> None:
    """AssistantMessage with usage=None (legacy SDK / sub-message variants)
    must not emit a zero-valued token_usage envelope — that would lie about
    a real billing event having happened."""

    state = SessionState(session_id="sess-token-usage-2")
    msg = AssistantMessage(content=[], model="claude-sonnet-4-6", usage=None)

    captured, fake_emit = _record_emits()

    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    types = [env["type"] for env in captured]
    assert "token_usage" not in types, (
        f"unexpected token_usage envelope when AssistantMessage.usage is None: {types}"
    )


@pytest.mark.asyncio
async def test_forward_message_result_still_emits_turn_end_with_usage() -> None:
    """Reconciliation depends on the rollup still arriving — guard against
    a regression that drops turn_end usage when adding the live stream."""

    state = SessionState(session_id="sess-token-usage-3")
    msg = ResultMessage(
        subtype="success",
        duration_ms=100,
        duration_api_ms=80,
        is_error=False,
        num_turns=1,
        session_id="sess-token-usage-3",
        stop_reason="end_turn",
        usage={
            "input_tokens": 2000,
            "output_tokens": 200,
            "cache_creation_input_tokens": 10,
            "cache_read_input_tokens": 100,
        },
    )

    captured, fake_emit = _record_emits()

    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [turn_envelope] = [env for env in captured if env["type"] == "turn_end"]
    assert turn_envelope["usage"] == {
        "input_tokens": 2000,
        "output_tokens": 200,
        "cache_creation_input_tokens": 10,
        "cache_read_input_tokens": 100,
    }
