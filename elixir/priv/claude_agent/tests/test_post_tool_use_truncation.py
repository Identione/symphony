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


# Regression (IDE-846 / IDE-851): a `Read` of a PNG screenshot returns the image
# as one long base64 leaf. Eliding its middle spliced the "[Symphony elided …]"
# marker into the base64, the API rejected the corrupted image ("an image in the
# conversation could not be processed") with a non-retryable invalid_request,
# and the issue halted. Binary payloads must pass through byte-for-byte.
_BIG_B64 = "iVBORw0KGgoAAAANSUhEUgAA" + "QUJD" * 25_000 + "AAAAAElFTkSuQmCC"


def test_read_image_response_base64_is_never_elided() -> None:
    response = {
        "type": "image",
        "file": {
            "base64": _BIG_B64,
            "type": "image/png",
            "originalSize": 75_630,
            "dimensions": {"originalWidth": 1265, "originalHeight": 784},
        },
    }
    value, changed = _truncate_tool_response(response, 8192)
    assert changed is False
    assert value["file"]["base64"] == _BIG_B64


def test_base64_source_block_data_is_never_elided() -> None:
    response = [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": _BIG_B64}},
        {"type": "text", "text": "T" * 20_000},
    ]
    value, changed = _truncate_tool_response(response, 8192)
    # The text sibling is still bounded; only the binary payload is exempt.
    assert changed is True
    assert value[0]["source"]["data"] == _BIG_B64
    assert len(value[1]["text"]) < 20_000


@pytest.mark.asyncio
async def test_hook_is_noop_for_large_image_read() -> None:
    truncate = _make_post_tool_use_truncator(8192)
    result = await truncate(
        {
            "hook_event_name": "PostToolUse",
            "tool_name": "Read",
            "tool_response": {"type": "image", "file": {"base64": _BIG_B64, "type": "image/png"}},
        },
        "tool-img",
        {"signal": None},
    )
    assert result == {}


# Two more image routes in the bundled CLI (behaviour read from its source):
# (1) A `Read` of a .ipynb returns `{type: "notebook", file: {cells: [...]}}`;
#     a code cell's display output carries `image: {image_data, media_type}`
#     (raw base64, later sent as a `source: {type: base64}` block). A whole-
#     notebook Read collapses a cell's outputs to an "Outputs are too large to
#     include" stub once text + image_data exceed 10_000 chars (`bOn=1e4`), so
#     an `image_data` leaf only ever reaches the cap when `tool_output_limit`
#     is configured below that — the fixtures below stay inside that bound.
# (2) A `Bash` whose stdout is an image sets `isImage: true` and `stdout` holds a
#     `data:image/<type>;base64,...` URI the CLI turns into an image block.
#     Eliding it splices a newline-bearing marker in, the CLI's `^data:...$`
#     parse fails, and the image silently degrades to a wall of base64 text.
_BIG_DATA_URI = "data:image/png;base64," + _BIG_B64

# Reachable notebook shape: one cell's outputs total < 10_000 chars.
_NB_IMAGE = "iVBORw0KGgoAAAANSUhEUgAA" + "QUJD" * 1_500 + "AAAAAElFTkSuQmCC"  # ~6KB
_NB_LIMIT = 2048  # an operator-tuned `tool_output_limit` below the CLI's 1e4 collapse


def _notebook_response(image_data: str, text: str = "<Figure size 640x480>") -> dict:
    return {
        "type": "notebook",
        "file": {
            "filePath": "/ws/analysis.ipynb",
            "cells": [
                {
                    "cellType": "code",
                    "source": "plt.plot(xs)",
                    "execution_count": 3,
                    "cell_id": "cell-0",
                    "language": "python",
                    "outputs": [
                        {
                            "output_type": "display_data",
                            "text": text,
                            "image": {"image_data": image_data, "media_type": "image/png"},
                        }
                    ],
                }
            ],
        },
    }


def _cell_outputs_chars(response: dict) -> int:
    output = response["file"]["cells"][0]["outputs"][0]
    return len(output["text"]) + len(output["image"]["image_data"])


def test_notebook_read_image_data_is_never_elided() -> None:
    response = _notebook_response(_NB_IMAGE)
    assert _cell_outputs_chars(response) <= 10_000  # a shape the CLI's Read can emit
    value, changed = _truncate_tool_response(response, _NB_LIMIT)
    assert changed is False
    assert value == response


def test_notebook_read_long_text_output_is_still_elided() -> None:
    response = _notebook_response(_NB_IMAGE, text="row\n" * 800)
    assert _cell_outputs_chars(response) <= 10_000
    value, changed = _truncate_tool_response(response, _NB_LIMIT)
    output = value["file"]["cells"][0]["outputs"][0]
    assert changed is True
    assert len(output["text"]) < 3_200
    assert "Symphony elided" in output["text"]
    assert output["image"]["image_data"] == _NB_IMAGE


def test_bash_image_stdout_is_never_elided() -> None:
    response = {"stdout": _BIG_DATA_URI, "stderr": "", "interrupted": False, "isImage": True}
    value, changed = _truncate_tool_response(response, 16384)
    assert changed is False
    assert value["stdout"] == _BIG_DATA_URI


def test_bash_image_flag_does_not_exempt_long_stderr() -> None:
    response = {"stdout": _BIG_DATA_URI, "stderr": "E" * 40_000, "interrupted": False, "isImage": True}
    value, changed = _truncate_tool_response(response, 16384)
    assert changed is True
    assert value["stdout"] == _BIG_DATA_URI
    assert len(value["stderr"]) < 40_000


@pytest.mark.parametrize("is_image", [False, None])
def test_bash_long_text_stdout_is_still_elided(is_image) -> None:
    response = {"stdout": "line\n" * 10_000, "stderr": "", "interrupted": False}
    if is_image is not None:
        response["isImage"] = is_image
    value, changed = _truncate_tool_response(response, 16384)
    assert changed is True
    assert len(value["stdout"]) < 50_000
    assert "Symphony elided" in value["stdout"]


# Only the CLI's own signals (a binary key, or `isImage: true`) mark a payload
# as an image. Text that merely *starts* with a data URI is sent to the model as
# text (the CLI's `^data:([^;]+);base64,(.+)$` parse fails on multi-line text),
# so it must stay bounded like any other text leaf.
_DATA_URI_PREFIXED_TEXT = "data:image/png;base64," + "QUJD" * 20 + "\n" + "plain log line\n" * 20_000


def test_read_text_starting_with_data_image_uri_is_still_elided() -> None:
    response = {"type": "text", "file": {"filePath": "/ws/fixture.datauri", "content": _DATA_URI_PREFIXED_TEXT}}
    value, changed = _truncate_tool_response(response, 16384)
    assert changed is True
    assert len(value["file"]["content"]) < 20_000
    assert "Symphony elided" in value["file"]["content"]


def test_bash_text_stdout_starting_with_data_image_uri_is_still_elided() -> None:
    response = {"stdout": _DATA_URI_PREFIXED_TEXT, "stderr": "", "interrupted": False, "isImage": False}
    value, changed = _truncate_tool_response(response, 16384)
    assert changed is True
    assert len(value["stdout"]) < 20_000
    assert "Symphony elided" in value["stdout"]


@pytest.mark.asyncio
async def test_hook_is_noop_for_bash_image_and_notebook_image() -> None:
    bash = await _make_post_tool_use_truncator(16384)(
        {
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_response": {"stdout": _BIG_DATA_URI, "stderr": "", "interrupted": False, "isImage": True},
        },
        "tool-bash-img",
        {"signal": None},
    )
    assert bash == {}
    notebook = await _make_post_tool_use_truncator(_NB_LIMIT)(
        {"hook_event_name": "PostToolUse", "tool_name": "Read", "tool_response": _notebook_response(_NB_IMAGE)},
        "tool-nb-img",
        {"signal": None},
    )
    assert notebook == {}
