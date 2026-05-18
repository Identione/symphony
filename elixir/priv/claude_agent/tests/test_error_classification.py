"""Unit tests for the sidecar's structured error taxonomy (IDE-71).

The sidecar maps Anthropic SDK exceptions and CLI-side ``ResultMessage``
errors into a closed taxonomy that Symphony's orchestrator can branch on.
These tests pin one case per taxonomy code so a refactor cannot silently
drop a mapping.
"""

from __future__ import annotations

import io
import json
import os
import sys
from types import SimpleNamespace

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from symphony_claude_agent import sidecar  # noqa: E402
from symphony_claude_agent.sidecar import (  # noqa: E402
    ERROR_CODE_CONTEXT_WINDOW_EXHAUSTED,
    ERROR_CODE_INVALID_REQUEST,
    ERROR_CODE_OVERLOADED,
    ERROR_CODE_QUOTA_EXCEEDED,
    ERROR_CODE_RATE_LIMITED,
    ERROR_CODE_UNKNOWN,
    build_error_envelope,
    classify_error_code,
    emit,
)


# ---- classify_error_code: HTTP-status path ---------------------------------


def test_classify_rate_limited_by_http_429() -> None:
    assert classify_error_code(http_status=429) == ERROR_CODE_RATE_LIMITED


def test_classify_overloaded_by_http_529() -> None:
    assert classify_error_code(http_status=529) == ERROR_CODE_OVERLOADED


def test_classify_overloaded_by_http_503() -> None:
    assert classify_error_code(http_status=503) == ERROR_CODE_OVERLOADED


def test_classify_context_window_by_http_413() -> None:
    assert classify_error_code(http_status=413) == ERROR_CODE_CONTEXT_WINDOW_EXHAUSTED


def test_classify_invalid_request_by_other_4xx() -> None:
    assert classify_error_code(http_status=400) == ERROR_CODE_INVALID_REQUEST
    assert classify_error_code(http_status=401) == ERROR_CODE_INVALID_REQUEST
    assert classify_error_code(http_status=403) == ERROR_CODE_INVALID_REQUEST


# ---- classify_error_code: exception-class path -----------------------------


def test_classify_rate_limited_by_exception_class() -> None:
    assert (
        classify_error_code(exception_class="RateLimitError", message="429 Too Many")
        == ERROR_CODE_RATE_LIMITED
    )


def test_classify_overloaded_by_exception_class() -> None:
    assert (
        classify_error_code(exception_class="OverloadedError", message="529")
        == ERROR_CODE_OVERLOADED
    )
    assert (
        classify_error_code(exception_class="InternalServerError")
        == ERROR_CODE_OVERLOADED
    )


def test_classify_invalid_request_by_exception_class() -> None:
    for klass in (
        "BadRequestError",
        "AuthenticationError",
        "PermissionDeniedError",
        "NotFoundError",
        "UnprocessableEntityError",
    ):
        assert classify_error_code(exception_class=klass) == ERROR_CODE_INVALID_REQUEST


# ---- classify_error_code: message-body heuristics --------------------------


def test_classify_quota_by_credit_balance_message() -> None:
    """A 400 with a `credit_balance_too_low` body is deterministic, not
    transient — must map to quota_exceeded even though the class is BadRequest."""
    assert (
        classify_error_code(
            exception_class="BadRequestError",
            message="Your credit balance is too low to access the Anthropic API.",
            http_status=400,
        )
        == ERROR_CODE_QUOTA_EXCEEDED
    )


def test_classify_context_window_by_prompt_too_long_message() -> None:
    assert (
        classify_error_code(
            exception_class="BadRequestError",
            message="prompt is too long: 250000 tokens > 200000 maximum",
            http_status=400,
        )
        == ERROR_CODE_CONTEXT_WINDOW_EXHAUSTED
    )


def test_classify_context_window_by_context_length_message() -> None:
    assert (
        classify_error_code(
            exception_class="BadRequestError",
            message="context length exceeded",
        )
        == ERROR_CODE_CONTEXT_WINDOW_EXHAUSTED
    )


def test_classify_unknown_for_unrecognised_input() -> None:
    assert classify_error_code() == ERROR_CODE_UNKNOWN
    assert (
        classify_error_code(exception_class="NameError", message="x not defined")
        == ERROR_CODE_UNKNOWN
    )


def test_classify_message_overrides_http_status() -> None:
    """A 429 carrying a quota body classifies as quota_exceeded, not rate_limited.

    `quota_exceeded` is deterministic (won't recover on retry); rate_limited
    is transient. Misclassifying would have the orchestrator hammer the API
    indefinitely.
    """
    assert (
        classify_error_code(
            http_status=429,
            message="credit balance too low",
        )
        == ERROR_CODE_QUOTA_EXCEEDED
    )


def test_classify_uses_api_error_type_field() -> None:
    assert (
        classify_error_code(api_error_type="rate_limit_error")
        == ERROR_CODE_RATE_LIMITED
    )
    assert (
        classify_error_code(api_error_type="overloaded_error")
        == ERROR_CODE_OVERLOADED
    )


def test_classify_max_turns_result_subtype_is_invalid_request() -> None:
    assert (
        classify_error_code(result_subtype="error_max_turns")
        == ERROR_CODE_INVALID_REQUEST
    )


# ---- build_error_envelope shape -------------------------------------------


def test_build_error_envelope_includes_taxonomy_fields() -> None:
    env = build_error_envelope("boom", error_code=ERROR_CODE_RATE_LIMITED)
    assert env == {
        "type": "error",
        "error": "boom",
        "category": "claude_sdk_error",
        "error_code": "rate_limited",
    }


def test_build_error_envelope_preserves_category_and_extra() -> None:
    env = build_error_envelope(
        "missing",
        category="claude_sidecar_not_found",
        error_code=ERROR_CODE_INVALID_REQUEST,
        extra={"subtype": "error_during_execution", "session_id": "s1"},
    )
    assert env["category"] == "claude_sidecar_not_found"
    assert env["error_code"] == "invalid_request"
    assert env["subtype"] == "error_during_execution"
    assert env["session_id"] == "s1"


# ---- ResultMessage(is_error=True) interception in _forward_message --------


@pytest.mark.asyncio
async def test_forward_message_emits_error_for_result_message_with_is_error(monkeypatch) -> None:
    """When the CLI flags a ResultMessage as an error, the sidecar must emit an
    `error` envelope (not `turn_end`) so Symphony's adapter classifies it.
    """

    # Pretend the SDK is installed and treat `SimpleNamespace` as a
    # `ResultMessage` — `_forward_message`'s `isinstance` checks gate on
    # `_SDK_AVAILABLE`, so flip both for the duration of the test.
    monkeypatch.setattr(sidecar, "_SDK_AVAILABLE", True)
    monkeypatch.setattr(sidecar, "ResultMessage", SimpleNamespace)
    monkeypatch.setattr(sidecar, "SystemMessage", type("_Sys", (), {}))
    monkeypatch.setattr(sidecar, "AssistantMessage", type("_Asst", (), {}))

    captured: list[str] = []
    monkeypatch.setattr(
        sidecar.sys, "stdout", io.StringIO()
    )  # avoid actually writing to test process stdout

    def fake_emit(event, stream=None):  # noqa: ARG001
        captured.append(json.dumps(event))

    monkeypatch.setattr(sidecar, "emit", fake_emit)

    state = sidecar.SessionState(session_id="s-test")
    result = SimpleNamespace(
        subtype="error_during_execution",
        is_error=True,
        stop_reason="error",
        num_turns=2,
        usage={"input_tokens": 1, "output_tokens": 0},
        result="rate_limit_error: too many requests",
        api_error_status=429,
        errors=None,
    )

    await sidecar._forward_message(state, result)

    assert len(captured) == 1
    env = json.loads(captured[0])
    assert env["type"] == "error"
    assert env["error_code"] == "rate_limited"
    assert env["category"] == "claude_sdk_error"
    assert env["http_status"] == 429
    assert env["session_id"] == "s-test"
    assert env["subtype"] == "error_during_execution"


@pytest.mark.asyncio
async def test_forward_message_keeps_turn_end_for_success_result_message(monkeypatch) -> None:
    monkeypatch.setattr(sidecar, "_SDK_AVAILABLE", True)
    monkeypatch.setattr(sidecar, "ResultMessage", SimpleNamespace)
    monkeypatch.setattr(sidecar, "SystemMessage", type("_Sys", (), {}))
    monkeypatch.setattr(sidecar, "AssistantMessage", type("_Asst", (), {}))

    captured: list[dict] = []
    monkeypatch.setattr(sidecar, "emit", lambda event, stream=None: captured.append(event))

    state = sidecar.SessionState(session_id="s-ok")
    result = SimpleNamespace(
        subtype="success",
        is_error=False,
        stop_reason="end_turn",
        num_turns=3,
        usage={"input_tokens": 4, "output_tokens": 2},
        result="ok",
        api_error_status=None,
        errors=None,
    )

    await sidecar._forward_message(state, result)

    assert len(captured) == 1
    env = captured[0]
    assert env["type"] == "turn_end"
    assert env["stop_reason"] == "end_turn"
    assert env["session_id"] == "s-ok"


# ---- emit + envelope shape — round-trip via JSON ---------------------------


def test_emit_serialises_error_envelope() -> None:
    buf = io.StringIO()
    emit(build_error_envelope("oops", error_code=ERROR_CODE_OVERLOADED), stream=buf)
    line = buf.getvalue().rstrip("\n")
    parsed = json.loads(line)
    assert parsed["type"] == "error"
    assert parsed["error_code"] == "overloaded"
    assert parsed["category"] == "claude_sdk_error"
