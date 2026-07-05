"""Repro + regression test for the `_stdin_lines` 64 KiB limit bug.

Symptom: ``asyncio.StreamReader(loop=loop)`` in ``_stdin_lines`` is constructed
without an explicit ``limit=``, so asyncio's default 64 KiB line limit
applies. Any single stdin envelope over ~65536 bytes (e.g. a large
``linear_graphql`` tool_result relayed from the Elixir side, which does not
cap it) makes ``reader.readline()`` raise ``ValueError`` ("Separator is
found, but chunk is longer than limit"). Nothing catches that error, so the
whole sidecar process — and the in-flight Claude session with it — dies.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import asyncio
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from symphony_claude_agent import sidecar  # noqa: E402

# Comfortably past asyncio's default 64 KiB StreamReader limit.
_OVERSIZED_PAYLOAD_BYTES = 100 * 1024


@pytest.mark.asyncio
async def test_stdin_lines_yields_line_larger_than_64kib(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A single stdin line over 64 KiB must be yielded intact, not raise."""

    read_fd, write_fd = os.pipe()
    read_file = os.fdopen(read_fd, "r")
    monkeypatch.setattr(sys, "stdin", read_file)

    payload = "x" * _OVERSIZED_PAYLOAD_BYTES
    line_bytes = (payload + "\n").encode("utf-8")

    def _write_oversized_line() -> None:
        # Writing >64 KiB into a pipe can block until a reader drains it, so
        # this runs on a worker thread concurrently with the async reader
        # below rather than blocking the test before it starts reading.
        with os.fdopen(write_fd, "wb") as write_file:
            write_file.write(line_bytes)

    loop = asyncio.get_running_loop()
    writer = loop.run_in_executor(None, _write_oversized_line)

    lines = []
    async for text in sidecar._stdin_lines():
        lines.append(text)

    await writer

    assert lines == [payload]
