"""Repro + regression test for the sidecar `_serve` concurrency bug.

Symptom: Symphony's stall watchdog fires after ~5 minutes whenever Claude
calls a Symphony-provided tool (e.g. ``linear_graphql``).

Root cause (before this test passed): ``_serve`` did
``await _drive(state, envelope)`` *synchronously*, so while a `turn` was in
flight the main loop was suspended inside that one await. Symphony's
`tool_result` envelopes — which are the only thing that can resolve the
future the @tool function is awaiting — never got read from stdin. The
@tool blocked forever, the SDK iteration hung, the turn never ended.

These tests substitute `_handle_turn` with a fake that registers a future
on the shared ``PendingToolCalls`` and awaits it. If `_serve` fails to
process subsequent `tool_result` envelopes concurrently, the futures never
resolve and the tests time out.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import sys
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from symphony_claude_agent import sidecar  # noqa: E402


@pytest_asyncio.fixture
async def serve_loop(
    monkeypatch: pytest.MonkeyPatch,
) -> AsyncIterator[asyncio.Queue[str | None]]:
    """Run `_serve` against a queue-backed fake stdin; clean up on teardown.

    Tests push envelopes onto the yielded queue. The fixture cancels the
    serve task and drains its exception on exit so a leaking turn doesn't
    pollute the next test.
    """

    queue: asyncio.Queue[str | None] = asyncio.Queue()

    async def fake_stdin_lines():
        while True:
            item = await queue.get()
            if item is None:
                return
            yield item

    monkeypatch.setattr(sidecar, "_stdin_lines", fake_stdin_lines)

    serve_task = asyncio.create_task(sidecar._serve())
    try:
        yield queue
    finally:
        await queue.put(None)
        serve_task.cancel()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await serve_task


@pytest.mark.asyncio
async def test_serve_processes_tool_result_envelope_during_running_turn(
    monkeypatch: pytest.MonkeyPatch,
    serve_loop: asyncio.Queue[str | None],
) -> None:
    """A `tool_result` envelope must resolve the future even while `turn`
    handling is mid-flight inside `client.receive_response`."""

    received_result: dict = {}
    registered = asyncio.Event()
    turn_done = asyncio.Event()

    async def fake_handle_turn(state: sidecar.SessionState, env: dict) -> None:
        future = state.pending_tool_calls.register("u-stall-test")
        registered.set()
        result = await future
        received_result["value"] = result
        turn_done.set()

    monkeypatch.setattr(sidecar, "_handle_turn", fake_handle_turn)

    await serve_loop.put('{"type":"turn","prompt":"go"}')

    # Wait for the (concurrently scheduled) turn task to register its future
    # before we push the tool_result; otherwise PendingToolCalls has nothing
    # to resolve and the call is a silent no-op.
    await asyncio.wait_for(registered.wait(), timeout=1.0)

    await serve_loop.put(
        '{"type":"tool_result","tool_use_id":"u-stall-test","result":{"ok":true}}'
    )

    # Without the fix this times out: `_serve` is blocked inside
    # `await _drive(turn_envelope)` and never reads the tool_result envelope.
    await asyncio.wait_for(turn_done.wait(), timeout=1.0)

    assert received_result == {"value": {"ok": True}}


@pytest.mark.asyncio
async def test_serve_handles_two_tool_results_in_a_row_during_one_turn(
    monkeypatch: pytest.MonkeyPatch,
    serve_loop: asyncio.Queue[str | None],
) -> None:
    """A turn that issues multiple tool calls must see each result, in order."""

    results: list = []
    registered_one = asyncio.Event()
    registered_two = asyncio.Event()
    turn_done = asyncio.Event()

    async def fake_handle_turn(state: sidecar.SessionState, env: dict) -> None:
        f1 = state.pending_tool_calls.register("u-1")
        registered_one.set()
        results.append(await f1)
        f2 = state.pending_tool_calls.register("u-2")
        registered_two.set()
        results.append(await f2)
        turn_done.set()

    monkeypatch.setattr(sidecar, "_handle_turn", fake_handle_turn)

    await serve_loop.put('{"type":"turn","prompt":"go"}')

    await asyncio.wait_for(registered_one.wait(), timeout=1.0)
    await serve_loop.put(
        '{"type":"tool_result","tool_use_id":"u-1","result":{"step":1}}'
    )

    await asyncio.wait_for(registered_two.wait(), timeout=1.0)
    await serve_loop.put(
        '{"type":"tool_result","tool_use_id":"u-2","result":{"step":2}}'
    )

    await asyncio.wait_for(turn_done.wait(), timeout=1.0)

    assert results == [{"step": 1}, {"step": 2}]


@pytest.mark.asyncio
async def test_serve_rejects_concurrent_turn_envelope(
    monkeypatch: pytest.MonkeyPatch,
    serve_loop: asyncio.Queue[str | None],
) -> None:
    """A second `turn` arriving while the first is still running must be
    rejected with an `error` envelope rather than silently queued."""

    started = asyncio.Event()
    rejected = asyncio.Event()
    proceed = asyncio.Event()

    async def fake_handle_turn(state: sidecar.SessionState, env: dict) -> None:
        started.set()
        await proceed.wait()

    emitted: list[dict] = []

    def fake_emit(event: dict, stream=None) -> None:
        emitted.append(event)
        if event.get("type") == "error" and "turn already in progress" in event.get("error", ""):
            rejected.set()

    monkeypatch.setattr(sidecar, "_handle_turn", fake_handle_turn)
    monkeypatch.setattr(sidecar, "emit", fake_emit)

    try:
        await serve_loop.put('{"type":"turn","prompt":"first"}')
        await asyncio.wait_for(started.wait(), timeout=1.0)

        await serve_loop.put('{"type":"turn","prompt":"second"}')
        await asyncio.wait_for(rejected.wait(), timeout=1.0)
    finally:
        proceed.set()
