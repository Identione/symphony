"""Verify a Claude auth-failure (HTTP 401) surfaces as an *error* envelope.

A subscription/billing/authentication failure can arrive two ways:

1. The SDK delivers an ``AssistantMessage`` with ``error="authentication_failed"``
   set (see ``AssistantMessageError`` in ``claude_agent_sdk.types``) followed by
   a normal ``ResultMessage``. This is the same shape as the rate-limit wall
   handled by `_forward_message_rate_limit`'s tests.
2. Observed Claude Code traces also show the same 401 surfacing as plain
   assistant prose -- ``Failed to authenticate. API Error: 401 Invalid
   authentication credentials`` -- with ``AssistantMessage.error`` unset, mirroring
   the usage-limit prose path. The naive ``AssistantMessage`` branch renders
   the prose as ``assistant_message`` and Elixir's continuation loop
   re-prompts it up to ``agent.max_turns`` times, exiting with
   ``:max_turns_reached`` instead of surfacing the auth failure.

Both forms must produce a structured ``error`` envelope carrying
``error_code: "authentication_failed"`` (Elixir
``to_error_code("authentication_failed") -> :invalid_request`` already maps it).

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import os
import sys
from typing import Any
from unittest.mock import patch

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from claude_agent_sdk.types import (  # noqa: E402
    AssistantMessage,
    ResultMessage,
    SystemMessage,
    TextBlock,
)

from symphony_claude_agent import sidecar  # noqa: E402
from symphony_claude_agent.sidecar import SessionState, _forward_message  # noqa: E402


_AUTH_401_PROSE = "Failed to authenticate. API Error: 401 Invalid authentication credentials"


def _record_emits():
    captured: list[dict[str, Any]] = []
    return captured, lambda env, stream=None: captured.append(env)


@pytest.mark.asyncio
async def test_sdk_authentication_failed_emits_error_envelope() -> None:
    state = SessionState(session_id="sess-auth-1")
    msg = AssistantMessage(
        content=[TextBlock(text=_AUTH_401_PROSE)],
        model="claude-opus-4-8",
        error="authentication_failed",
        stop_reason="stop_sequence",
        session_id="sess-auth-1",
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "authentication_failed"
    assert err["session_id"] == "sess-auth-1"
    assert not any(env["type"] == "assistant_message" for env in captured)


@pytest.mark.asyncio
async def test_auth_failure_prose_without_sdk_error_still_emits_error_envelope() -> None:
    """Claude Code traces sometimes carry the 401 wall as plain prose with
    ``AssistantMessage.error`` unset; the prose classifier must still catch it."""

    state = SessionState(session_id="sess-auth-prose")
    msg = AssistantMessage(
        content=[TextBlock(text=_AUTH_401_PROSE)],
        model="claude-opus-4-8",
        error=None,
        stop_reason="stop_sequence",
        session_id="sess-auth-prose",
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "authentication_failed"
    assert err["session_id"] == "sess-auth-prose"
    assert not any(env["type"] == "assistant_message" for env in captured)


@pytest.mark.asyncio
async def test_system_api_error_401_emits_error_envelope() -> None:
    """The Claude CLI subprocess writes ``{"type":"system","subtype":"api_error",
    "error":{"status":401,...}}`` for a 401 from api.anthropic.com. The SDK
    parses that as ``SystemMessage(subtype="api_error", data=...)`` and the
    sidecar must surface it as a structured error so Elixir terminates the run
    on the first occurrence instead of re-prompting through ``agent.max_turns``.
    """

    state = SessionState(session_id="sess-auth-sys")
    msg = SystemMessage(
        subtype="api_error",
        data={
            "type": "system",
            "subtype": "api_error",
            "level": "error",
            "error": {
                "status": 401,
                "requestID": "req_011CcJ8TNugp3qrMXbtngfAc",
                "error": {
                    "type": "error",
                    "error": {
                        "type": "authentication_error",
                        "message": "Invalid authentication credentials",
                    },
                },
            },
            "session_id": "sess-auth-sys",
        },
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "authentication_failed"
    assert err["session_id"] == "sess-auth-sys"


@pytest.mark.asyncio
async def test_result_message_api_error_status_401_emits_error_envelope() -> None:
    """Per ``ResultMessage.api_error_status`` (claude-agent-sdk: emitted by the
    CLI since v2.1.110), a failing API call is also surfaced as a ResultMessage
    with ``is_error=True``, ``subtype="success"``, and the HTTP status in
    ``api_error_status``. The naive ``ResultMessage`` branch emits an error
    envelope with ``error_code: "success"`` (wrong: Elixir treats unknown codes
    as transient and re-prompts). Map the HTTP status to the correct literal.
    """

    state = SessionState(session_id="sess-auth-result")
    msg = ResultMessage(
        subtype="success",
        duration_ms=120,
        duration_api_ms=110,
        is_error=True,
        num_turns=1,
        session_id="sess-auth-result",
        stop_reason=None,
        api_error_status=401,
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "authentication_failed"
    assert err["session_id"] == "sess-auth-result"


@pytest.mark.asyncio
async def test_result_message_api_error_status_429_maps_to_rate_limit() -> None:
    """Other HTTP statuses map per the existing error-code vocabulary."""

    state = SessionState(session_id="sess-rl-result")
    msg = ResultMessage(
        subtype="success",
        duration_ms=120,
        duration_api_ms=110,
        is_error=True,
        num_turns=1,
        session_id="sess-rl-result",
        api_error_status=429,
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "rate_limit"


@pytest.mark.asyncio
async def test_system_api_error_429_embeds_retry_after_from_headers() -> None:
    """A 429 wall from api.anthropic.com carries the real reset window in its
    ``Retry-After`` header. The SystemMessage api_error envelope must surface
    that value as an embedded ``retry-after <seconds>`` substring so Elixir's
    existing retry-after parser (added in #64) honors it instead of falling
    back to ``RetryPolicy``'s default exponential schedule."""

    state = SessionState(session_id="sess-rl-sys")
    msg = SystemMessage(
        subtype="api_error",
        data={
            "type": "system",
            "subtype": "api_error",
            "level": "error",
            "error": {
                "status": 429,
                "headers": {"retry-after": "42"},
                "error": {"type": "rate_limit_error", "message": "Too many requests"},
            },
            "session_id": "sess-rl-sys",
        },
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "rate_limit"
    assert "retry-after 42" in err["error"]


@pytest.mark.asyncio
async def test_result_message_429_without_status_falls_back_to_rate_limit_code() -> None:
    """A 429 ResultMessage carries no headers, so retry-after cannot be
    embedded from this path; the test pins the documented limitation (Elixir
    falls back to RetryPolicy(:rate_limited) defaults) and ensures the code
    still classifies as ``rate_limit`` rather than ``unknown`` or ``success``."""

    state = SessionState(session_id="sess-rl-result")
    msg = ResultMessage(
        subtype="success",
        duration_ms=120,
        duration_api_ms=110,
        is_error=True,
        num_turns=1,
        session_id="sess-rl-result",
        api_error_status=429,
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "rate_limit"


@pytest.mark.asyncio
async def test_result_message_429_after_system_api_error_inherits_retry_after() -> None:
    """When a 429 arrives as a SystemMessage(api_error) with a Retry-After
    header followed by a ResultMessage(api_error_status=429), the ResultMessage
    envelope must carry the previously-seen retry-after so the orchestrator
    has the real wait time even if it processes the result envelope first."""

    state = SessionState(session_id="sess-rl-pair")

    sys_msg = SystemMessage(
        subtype="api_error",
        data={
            "subtype": "api_error",
            "error": {
                "status": 429,
                "headers": {"retry-after": "37"},
            },
            "session_id": "sess-rl-pair",
        },
    )
    result_msg = ResultMessage(
        subtype="success",
        duration_ms=120,
        duration_api_ms=110,
        is_error=True,
        num_turns=1,
        session_id="sess-rl-pair",
        api_error_status=429,
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, sys_msg)
        await _forward_message(state, result_msg)

    errs = [env for env in captured if env["type"] == "error"]
    assert errs, "expected at least one error envelope"
    assert all("retry-after 37" in e["error"] for e in errs)


@pytest.mark.asyncio
async def test_system_api_error_with_string_status_still_classifies() -> None:
    """Some upstream frames serialize the HTTP status as a JSON string. The
    extractor must coerce ``\"401\"`` to ``401`` rather than fall through to
    ``unknown`` (which Elixir treats as transient and re-prompts)."""

    state = SessionState(session_id="sess-auth-str")
    msg = SystemMessage(
        subtype="api_error",
        data={
            "subtype": "api_error",
            "error": {
                "status": "401",
                "error": {"type": "authentication_error"},
            },
            "session_id": "sess-auth-str",
        },
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] == "authentication_failed"


@pytest.mark.asyncio
async def test_system_api_error_with_unextractable_status_falls_back_to_deterministic_code() -> None:
    """When the status sits in an alternate key or is unparseable, the
    sidecar must NOT emit ``error_code: "unknown"`` (Elixir treats that as
    transient and the run loops to :max_turns_reached). Treat a known
    api_error subtype as a deterministic failure even when the status digit
    cannot be recovered."""

    state = SessionState(session_id="sess-auth-unparse")
    msg = SystemMessage(
        subtype="api_error",
        data={
            "subtype": "api_error",
            "error": {
                # status lives at an unanticipated key; the walker can't reach it.
                "response": {"status": 401},
                "message": "Invalid authentication credentials",
            },
            "session_id": "sess-auth-unparse",
        },
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    [err] = [env for env in captured if env["type"] == "error"]
    assert err["error_code"] != "unknown"
    assert err["error_code"] in {"invalid_request", "authentication_failed"}


@pytest.mark.asyncio
async def test_normal_prose_mentioning_authentication_does_not_trigger_error() -> None:
    """Narrow match: text mentioning auth in a product context must not become
    a synthetic failure. The classifier requires the literal upstream wall."""

    state = SessionState(session_id="sess-auth-control")
    msg = AssistantMessage(
        content=[
            TextBlock(
                text="The user is asking how authentication works in the new flow."
            )
        ],
        model="claude-opus-4-8",
        error=None,
        stop_reason="end_turn",
        session_id="sess-auth-control",
    )

    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await _forward_message(state, msg)

    assert any(env["type"] == "assistant_message" for env in captured)
    assert not any(env["type"] == "error" for env in captured)
