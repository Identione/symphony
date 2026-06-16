"""Verify a ``max_budget_usd`` breach surfaces as an *error* envelope.

The SDK reports a budget breach by *returning* (not raising) a
``ResultMessage(subtype="error_max_budget_usd", is_error=True)``. The naive
``ResultMessage`` branch emits a bare ``turn_end`` that Elixir treats as a clean
success → relaunch forever. ``_forward_message`` must instead emit a structured
``error`` envelope so Elixir can map it to ``:budget_exhausted`` and escalate.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import os
import sys
from typing import Any
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from claude_agent_sdk.types import ResultMessage  # noqa: E402

from symphony_claude_agent import sidecar  # noqa: E402
from symphony_claude_agent.sidecar import SessionState, _forward_message  # noqa: E402


def _record_emits():
    captured: list[dict[str, Any]] = []
    return captured, lambda env, stream=None: captured.append(env)


@pytest.mark.asyncio
async def test_budget_breach_emits_error_envelope_not_turn_end() -> None:
    state = SessionState(session_id="sess-budget-1")
    msg = ResultMessage(
        subtype="error_max_budget_usd",
        duration_ms=100,
        duration_api_ms=80,
        is_error=True,
        num_turns=7,
        session_id="sess-budget-1",
        stop_reason=None,
        usage={
            "input_tokens": 1,
            "output_tokens": 1,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        },
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    assert not any(env["type"] == "turn_end" for env in captured)
    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "error_max_budget_usd"
    assert err["session_id"] == "sess-budget-1"


@pytest.mark.asyncio
async def test_successful_result_still_emits_turn_end() -> None:
    """Regression guard: a clean finish must remain a turn_end, not an error."""

    state = SessionState(session_id="sess-budget-2")
    msg = ResultMessage(
        subtype="success",
        duration_ms=100,
        duration_api_ms=80,
        is_error=False,
        num_turns=1,
        session_id="sess-budget-2",
        stop_reason="end_turn",
        usage={
            "input_tokens": 10,
            "output_tokens": 2,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
        },
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    assert any(env["type"] == "turn_end" for env in captured)
    assert not any(env["type"] == "error" for env in captured)
