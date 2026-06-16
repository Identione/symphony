"""Verify a Claude subscription usage-limit surfaces as an *error* envelope.

The SDK does **not** raise on a usage-limit hit — it delivers an
``AssistantMessage`` with ``error="rate_limit"`` set (see
``AssistantMessageError`` in ``claude_agent_sdk.types``) followed by a normal
``ResultMessage``. The naive ``AssistantMessage`` branch renders the prose and
returns, so Elixir sees a clean ``assistant_message`` + ``turn_end`` and
re-prompts the continuation loop up to ``agent.max_turns`` times, burning the
whole rate-limit window. ``_forward_message`` must instead emit a structured
``error`` envelope carrying the *raw SDK literal* as ``error_code`` (atom
mapping lives in Elixir ``to_error_code``) and suppress the plain
``assistant_message``.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from typing import Any
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from claude_agent_sdk.types import AssistantMessage, TextBlock  # noqa: E402

from symphony_claude_agent import sidecar  # noqa: E402
from symphony_claude_agent.sidecar import (  # noqa: E402
    SessionState,
    _forward_message,
    _parse_reset_seconds,
)

try:
    from zoneinfo import ZoneInfo  # noqa: E402
except ImportError:  # pragma: no cover - py<3.9 only
    ZoneInfo = None  # type: ignore[assignment]


def _record_emits():
    captured: list[dict[str, Any]] = []
    return captured, lambda env, stream=None: captured.append(env)


def _rate_limit_message(session_id: str) -> AssistantMessage:
    return AssistantMessage(
        content=[
            TextBlock(text="You've hit your limit · resets 11:20am (Europe/Stockholm)")
        ],
        model="claude-opus-4-8",
        error="rate_limit",
        stop_reason="stop_sequence",
        session_id=session_id,
    )


@pytest.mark.asyncio
async def test_rate_limit_emits_error_envelope_not_assistant_message() -> None:
    state = SessionState(session_id="sess-rl-1")
    msg = _rate_limit_message("sess-rl-1")

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    # The error must be surfaced with the raw SDK literal as error_code.
    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "rate_limit"
    assert err["session_id"] == "sess-rl-1"

    # The plain assistant_message (and its token_usage echo) must be suppressed
    # so the prose can't be mistaken for a clean turn.
    assert not any(env["type"] == "assistant_message" for env in captured)


@pytest.mark.asyncio
async def test_assistant_message_without_error_still_renders_normally() -> None:
    """Control case: a normal turn keeps emitting assistant_message, no error."""

    state = SessionState(session_id="sess-rl-2")
    msg = AssistantMessage(
        content=[TextBlock(text="Working on it.")],
        model="claude-opus-4-8",
        error=None,
        stop_reason="end_turn",
        session_id="sess-rl-2",
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    assert any(env["type"] == "assistant_message" for env in captured)
    assert not any(env["type"] == "error" for env in captured)


@pytest.mark.asyncio
async def test_rate_limit_error_embeds_retry_after_seconds() -> None:
    """The reset wall-clock is parsed into an embedded ``retry-after <seconds>``
    hint so the existing Elixir parser (agent_runner) picks it up unchanged."""

    state = SessionState(session_id="sess-rl-3")
    msg = _rate_limit_message("sess-rl-3")

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    import re

    assert re.search(r"retry[\s_-]?after[^\d]{0,8}\d+", err["error"], re.IGNORECASE)


@pytest.mark.skipif(ZoneInfo is None, reason="zoneinfo unavailable")
class TestParseResetSeconds:
    def test_parses_next_future_occurrence_same_day(self) -> None:
        # now = 09:00 Stockholm; resets 11:20am same day → 2h20m = 8400s.
        now = datetime(2026, 6, 17, 9, 0, tzinfo=ZoneInfo("Europe/Stockholm"))
        secs = _parse_reset_seconds(
            "resets 11:20am (Europe/Stockholm)", now=now
        )
        assert secs == 2 * 3600 + 20 * 60

    def test_rolls_over_to_next_day_when_reset_already_passed(self) -> None:
        # now = 14:00; resets 11:20am → already passed today, so next day.
        now = datetime(2026, 6, 17, 14, 0, tzinfo=ZoneInfo("Europe/Stockholm"))
        secs = _parse_reset_seconds(
            "resets 11:20am (Europe/Stockholm)", now=now
        )
        assert secs == (24 - 14) * 3600 + 11 * 3600 + 20 * 60

    def test_unparseable_or_absent_reset_returns_none(self) -> None:
        now = datetime(2026, 6, 17, 9, 0, tzinfo=timezone.utc)
        assert _parse_reset_seconds("no reset info here", now=now) is None
        assert _parse_reset_seconds("resets soon (Mars/Olympus)", now=now) is None
