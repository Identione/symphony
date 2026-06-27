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
    _classify_from_message,
    _classify_sdk_error,
    build_options_payload,
    emit,
    fold_text,
    parse_line,
    render_message_text,
    tool_visibility_diagnostic,
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
    assert payload["system_prompt"] == {"type": "preset", "preset": "claude_code"}


def test_build_options_payload_omits_setting_sources_when_absent() -> None:
    """Absent setting_sources -> key left off so ClaudeAgentOptions defaults to
    None, i.e. the CLI loads all filesystem settings (.claude/settings.json,
    project .mcp.json, CLAUDE.md) — parity with an interactive `claude` run."""

    payload = build_options_payload({"type": "init", "cwd": "/tmp/ws"})
    assert "setting_sources" not in payload


def test_build_options_payload_forwards_empty_setting_sources_for_isolation() -> None:
    """An explicit [] is passed through verbatim (SDK isolation: load no
    host-level settings) — it must NOT be conflated with "absent"."""

    payload = build_options_payload(
        {"type": "init", "cwd": "/tmp/ws", "setting_sources": []}
    )
    assert payload["setting_sources"] == []


def test_build_options_payload_forwards_setting_sources_subset() -> None:
    payload = build_options_payload(
        {"type": "init", "cwd": "/tmp/ws", "setting_sources": ["project"]}
    )
    assert payload["setting_sources"] == ["project"]


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


def test_build_options_payload_forwards_effort_when_set() -> None:
    payload = build_options_payload(
        {"type": "init", "cwd": "/tmp/ws", "effort": "xhigh"}
    )
    assert payload["effort"] == "xhigh"


def test_build_options_payload_omits_effort_when_unset() -> None:
    payload = build_options_payload({"type": "init", "cwd": "/tmp/ws"})
    assert "effort" not in payload


def test_build_options_payload_drops_claudeai_mcp_servers_by_default() -> None:
    """The operator's personal claude.ai MCP servers (Google Drive, the Linear
    plugin) bloat the CLI's tool-search deferred pool and squeeze the
    alphabetically-last in-process tool (``mcp__symphony_workpad__sync_workpad``)
    out of it, so the agent's ToolSearch can no longer find it. Force
    ``ENABLE_CLAUDEAI_MCP_SERVERS=0`` to keep them out. ``options.env`` overrides
    the spawned CLI's inherited env."""

    payload = build_options_payload({"type": "init", "cwd": "/tmp/ws"})
    assert payload["env"]["ENABLE_CLAUDEAI_MCP_SERVERS"] == "0"


def test_build_options_payload_env_caller_override_wins() -> None:
    """An explicit ``env`` in the init envelope merges over the defaults so an
    operator can re-tune the spawned CLI's env without a code change."""

    payload = build_options_payload(
        {
            "type": "init",
            "cwd": "/tmp/ws",
            "env": {"ENABLE_CLAUDEAI_MCP_SERVERS": "1", "FOO": "bar"},
        }
    )
    assert payload["env"]["ENABLE_CLAUDEAI_MCP_SERVERS"] == "1"
    assert payload["env"]["FOO"] == "bar"


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


def test_build_options_payload_verbose_logging_enables_partial_and_hook_streams() -> None:
    """`init.verbose_logging=true` flips on the SDK's noisier event streams."""

    payload = build_options_payload(
        {"type": "init", "cwd": "/tmp/ws", "verbose_logging": True}
    )
    assert payload["include_partial_messages"] is True
    assert payload["include_hook_events"] is True


def test_build_options_payload_default_omits_verbose_streams() -> None:
    """Without `verbose_logging`, the noisy streams stay off."""

    payload = build_options_payload({"type": "init", "cwd": "/tmp/ws"})
    assert "include_partial_messages" not in payload
    assert "include_hook_events" not in payload


def test_build_options_payload_legacy_verbose_key_does_not_enable_streams() -> None:
    """The pre-IDE-62 `verbose` field is no longer honored — only `verbose_logging` flips streams.

    Guards against silently regressing back to the narrow SDK-only knob if a
    stale Symphony build keeps sending the old key.
    """

    payload = build_options_payload(
        {"type": "init", "cwd": "/tmp/ws", "verbose": True}
    )
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


def test_tool_visibility_diagnostic_matches_sync_workpad_toolsearch() -> None:
    text = (
        "[tool_result tu1] "
        '[{"type":"tool_reference","tool_name":"mcp__symphony_workpad__sync_workpad"}]'
    )

    assert tool_visibility_diagnostic(text) == text


def test_tool_visibility_diagnostic_ignores_unrelated_text() -> None:
    assert tool_visibility_diagnostic("[tool_use Read(tu1)] {}") is None


# ---- _classify_from_message ------------------------------------------------


def test_classify_from_message_context_window() -> None:
    assert _classify_from_message("context window exceeded") == "context_window_exhausted"
    assert _classify_from_message("context length too long") == "context_window_exhausted"
    assert _classify_from_message("token limit reached") == "context_window_exhausted"


def test_classify_from_message_rate_limited() -> None:
    assert _classify_from_message("rate limit exceeded (429)") == "rate_limited"
    assert _classify_from_message("rate_limit error") == "rate_limited"
    assert _classify_from_message("ratelimited by upstream") == "rate_limited"


def test_classify_from_message_overloaded() -> None:
    assert _classify_from_message("API is overloaded") == "overloaded"
    assert _classify_from_message("overload detected") == "overloaded"


def test_classify_from_message_quota_exceeded() -> None:
    assert _classify_from_message("credit balance is too low") == "quota_exceeded"
    assert _classify_from_message("quota exceeded for this period") == "quota_exceeded"
    assert _classify_from_message("quota_exceeded: monthly cap hit") == "quota_exceeded"


def test_classify_from_message_invalid_request() -> None:
    assert _classify_from_message("invalid request: missing field") == "invalid_request"
    assert _classify_from_message("invalid_request error") == "invalid_request"


def test_classify_from_message_unknown() -> None:
    assert _classify_from_message("something unexpected happened") == "unknown"
    assert _classify_from_message("") == "unknown"


# ---- _classify_sdk_error ---------------------------------------------------


def test_classify_sdk_error_generic_exception_falls_back_to_message() -> None:
    exc = RuntimeError("rate limit exceeded")
    assert _classify_sdk_error(exc) == "rate_limited"


def test_classify_sdk_error_unknown_for_unrecognised_message() -> None:
    exc = ValueError("some unknown condition")
    assert _classify_sdk_error(exc) == "unknown"


def test_classify_sdk_error_context_window_via_message() -> None:
    exc = Exception("context window exceeded, please shorten your prompt")
    assert _classify_sdk_error(exc) == "context_window_exhausted"


def test_classify_sdk_error_overloaded_via_message() -> None:
    exc = Exception("The API is currently overloaded")
    assert _classify_sdk_error(exc) == "overloaded"
