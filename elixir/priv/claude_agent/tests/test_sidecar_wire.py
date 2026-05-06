"""Pure-Python tests for the sidecar wire helpers.

These do not require ``claude-agent-sdk`` to be installed — they only exercise
the JSON envelope encoding/decoding helpers in
:mod:`symphony_claude_agent.sidecar`.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import io
import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from symphony_claude_agent.sidecar import (  # noqa: E402
    build_options_payload,
    emit,
    fold_text,
    parse_line,
    render_message_text,
    usage_to_envelope,
)


def test_emit_writes_one_json_line() -> None:
    buf = io.StringIO()
    emit({"type": "ready"}, stream=buf)
    line = buf.getvalue()
    assert line.endswith("\n")
    assert json.loads(line) == {"type": "ready"}


def test_parse_line_round_trips() -> None:
    assert parse_line('{"type":"turn","prompt":"hello"}') == {
        "type": "turn",
        "prompt": "hello",
    }


def test_parse_line_rejects_non_object() -> None:
    with pytest.raises(ValueError):
        parse_line("[1, 2, 3]")


def test_parse_line_rejects_missing_type() -> None:
    with pytest.raises(ValueError):
        parse_line('{"hello":"world"}')


def test_build_options_payload_defaults() -> None:
    payload = build_options_payload({"type": "init", "cwd": "/tmp/ws"})
    assert payload["cwd"] == "/tmp/ws"
    assert payload["permission_mode"] == "dontAsk"
    assert payload["allowed_tools"] == []
    assert payload["disallowed_tools"] == []
    assert payload["setting_sources"] == []
    assert payload["system_prompt"] == {"type": "preset", "preset": "claude_code"}


def test_build_options_payload_minimal_preset() -> None:
    payload = build_options_payload(
        {
            "type": "init",
            "cwd": "/tmp/ws",
            "system_prompt_preset": "minimal",
            "model": "claude-sonnet-4-6",
            "max_turns": 7,
        }
    )
    assert payload["system_prompt"] == ""
    assert payload["model"] == "claude-sonnet-4-6"
    assert payload["max_turns"] == 7


def test_build_options_payload_requires_cwd() -> None:
    with pytest.raises(ValueError):
        build_options_payload({"type": "init"})


def test_usage_to_envelope_handles_dict() -> None:
    out = usage_to_envelope(
        {
            "input_tokens": 10,
            "output_tokens": 5,
            "cache_creation_input_tokens": 2,
            "cache_read_input_tokens": 1,
        }
    )
    assert out == {
        "input_tokens": 10,
        "output_tokens": 5,
        "cache_creation_input_tokens": 2,
        "cache_read_input_tokens": 1,
    }


def test_usage_to_envelope_handles_object() -> None:
    class FakeUsage:
        input_tokens = 4
        output_tokens = 1
        cache_creation_input_tokens = 0
        cache_read_input_tokens = 0

    assert usage_to_envelope(FakeUsage()) == {
        "input_tokens": 4,
        "output_tokens": 1,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
    }


def test_usage_to_envelope_handles_none() -> None:
    assert usage_to_envelope(None) == {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
    }


def test_build_options_payload_verbose_enables_partial_and_hook_streams() -> None:
    """`init.verbose=true` flips on the SDK's noisier event streams."""

    payload = build_options_payload(
        {"type": "init", "cwd": "/tmp/ws", "verbose": True}
    )
    assert payload["include_partial_messages"] is True
    assert payload["include_hook_events"] is True


def test_build_options_payload_default_omits_verbose_streams() -> None:
    """Without `verbose`, the noisy streams stay off."""

    payload = build_options_payload({"type": "init", "cwd": "/tmp/ws"})
    assert "include_partial_messages" not in payload
    assert "include_hook_events" not in payload


# ---- fold_text -------------------------------------------------------------


def test_fold_text_passes_short_strings_through() -> None:
    assert fold_text("hello") == "hello"


def test_fold_text_truncates_long_strings_with_suffix() -> None:
    long = "x" * 1500
    folded = fold_text(long, limit=100)
    assert folded.startswith("x" * 100)
    assert "more chars" in folded
    assert "1400" in folded  # 1500 − 100 = 1400 omitted


def test_fold_text_json_encodes_non_strings() -> None:
    assert fold_text({"a": 1, "b": [2, 3]}) == '{"a":1,"b":[2,3]}'


def test_fold_text_handles_none() -> None:
    assert fold_text(None) == ""


# ---- render_message_text (block-walking) -----------------------------------
#
# We use simple namespaces with the same attribute shape as the SDK block
# classes so these tests don't require claude-agent-sdk to be installed.


from types import SimpleNamespace  # noqa: E402


def _msg(*blocks):
    return SimpleNamespace(content=list(blocks))


def test_render_message_text_returns_none_for_empty_content() -> None:
    assert render_message_text(SimpleNamespace(content=None)) is None
    assert render_message_text(SimpleNamespace(content=[])) is None


def test_render_message_text_text_block() -> None:
    block = SimpleNamespace(text="hello world")
    assert render_message_text(_msg(block)) == "hello world"


def test_render_message_text_tool_use_block() -> None:
    """ToolUseBlock surfaces as `[tool_use Name(id)] {json input}`."""

    block = SimpleNamespace(name="Read", id="tu1", input={"file_path": "/x"})
    rendered = render_message_text(_msg(block))
    assert rendered is not None
    assert "[tool_use Read(tu1)]" in rendered
    assert '"file_path":"/x"' in rendered


def test_render_message_text_tool_result_block_with_error_flag() -> None:
    block = SimpleNamespace(
        tool_use_id="tu1",
        content="boom",
        is_error=True,
    )
    rendered = render_message_text(_msg(block))
    assert rendered is not None
    assert "[tool_result tu1 is_error]" in rendered
    assert "boom" in rendered


def test_render_message_text_tool_result_block_caps_long_content() -> None:
    block = SimpleNamespace(
        tool_use_id="tu2",
        content="x" * 5000,
        is_error=False,
    )
    rendered = render_message_text(_msg(block))
    assert rendered is not None
    assert "[tool_result tu2]" in rendered
    assert "more chars" in rendered  # truncation suffix from fold_text


def test_render_message_text_thinking_block() -> None:
    block = SimpleNamespace(thinking="step-by-step reasoning")
    rendered = render_message_text(_msg(block))
    assert rendered is not None
    assert "[thinking]" in rendered
    assert "step-by-step reasoning" in rendered


def test_render_message_text_joins_multiple_blocks_with_newlines() -> None:
    blocks = [
        SimpleNamespace(text="here is a tool call:"),
        SimpleNamespace(name="Read", id="tu1", input={"path": "/a"}),
    ]
    rendered = render_message_text(_msg(*blocks))
    assert rendered is not None
    assert rendered.startswith("here is a tool call:")
    assert "[tool_use Read(tu1)]" in rendered
    assert "\n" in rendered
