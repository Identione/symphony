"""Background tasks (``Workflow``, backgrounded ``Agent``) must finish inside the
Symphony turn that launched them.

The ``Workflow`` tool always runs in the background: the model gets a
"launched" ack, ends its response ("I'll wait for the notification"), and the
CLI emits a ``ResultMessage``. When the task completes the CLI injects a
``task_notification`` and *auto-starts a follow-up response* with its own
``ResultMessage``. ``CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`` does not affect
this (measured on CLI bundled with SDK 0.2.159).

If ``_handle_turn`` stops at the first ``ResultMessage`` the turn ends having
done nothing, and the follow-up's traffic sits unread until the next turn,
whose ``receive_response()`` then stops on the stale ``ResultMessage`` — every
later turn is off by one. The sidecar must instead hold ``turn_end`` while
tasks are in flight and emit a single merged ``turn_end`` once the follow-up
response finishes.

Run with: ``uv run --project priv/claude_agent pytest priv/claude_agent/tests``.
"""

from __future__ import annotations

import asyncio
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
from symphony_claude_agent.sidecar import SessionState, _handle_turn  # noqa: E402


def _usage(n: int) -> dict[str, int]:
    return {
        "input_tokens": n,
        "output_tokens": n,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": n,
    }


def _result(n: int, *, is_error: bool = False, subtype: str = "success") -> ResultMessage:
    return ResultMessage(
        subtype=subtype,
        duration_ms=1,
        duration_api_ms=1,
        is_error=is_error,
        num_turns=n,
        session_id="sess-bg",
        stop_reason="end_turn",
        usage=_usage(n),
    )


def _sys(subtype: str, **data: Any) -> SystemMessage:
    return SystemMessage(subtype=subtype, data={"type": "system", "subtype": subtype, **data})


def _text(text: str) -> AssistantMessage:
    return AssistantMessage(content=[TextBlock(text=text)], model="m")


TASK = {"task_id": "wf1", "task_type": "local_workflow", "description": "two files"}

# The exact shape observed from a live Workflow call (see module docstring).
WORKFLOW_SEQUENCE = [
    _sys("background_tasks_changed", tasks=[TASK]),
    _sys("task_started", tool_use_id="toolu_wf", **TASK),
    _sys("task_progress", task_id="wf1", tool_use_id="toolu_wf", description="A"),
    _text("The workflow is running; I'll wait for its completion notification."),
    _result(4),
    _sys("task_progress", task_id="wf1", tool_use_id="toolu_wf", description="B"),
    _sys("background_tasks_changed", tasks=[]),
    _sys("task_updated", task_id="wf1", patch={"status": "completed"}),
    _sys("task_notification", task_id="wf1", tool_use_id="toolu_wf", status="completed"),
    _sys("init", session_id="sess-bg"),
    _text("FINAL: alpha beta"),
    _result(2),
]


class FakeClient:
    """Mimics ClaudeSDKClient's shared message stream across turns."""

    def __init__(self, messages: list[Any], *, hang_after: bool = False) -> None:
        self._queue: asyncio.Queue[Any] = asyncio.Queue()
        for m in messages:
            self._queue.put_nowait(m)
        self._hang_after = hang_after
        self.queries: list[str] = []

    async def query(self, prompt: str) -> None:
        self.queries.append(prompt)

    async def receive_messages(self):
        while True:
            if self._queue.empty() and not self._hang_after:
                return
            yield await self._queue.get()

    async def receive_response(self):
        async for m in self.receive_messages():
            yield m
            if isinstance(m, ResultMessage):
                return

    def pending(self) -> int:
        return self._queue.qsize()


def _record_emits():
    captured: list[dict[str, Any]] = []
    return captured, lambda env, stream=None: captured.append(env)


async def _run_turn(client: FakeClient, state: SessionState | None = None) -> list[dict[str, Any]]:
    state = state or SessionState(session_id="sess-bg")
    state.client = client
    captured, fake_emit = _record_emits()
    with patch.object(sidecar, "emit", side_effect=fake_emit):
        await asyncio.wait_for(_handle_turn(state, {"prompt": "go"}), timeout=5)
    return captured


@pytest.mark.asyncio
async def test_workflow_turn_waits_for_follow_up_and_emits_one_merged_turn_end() -> None:
    client = FakeClient(WORKFLOW_SEQUENCE)
    captured = await _run_turn(client)

    turn_ends = [e for e in captured if e["type"] == "turn_end"]
    assert len(turn_ends) == 1, f"expected exactly one turn_end, got {captured}"
    assert captured[-1]["type"] == "turn_end", "turn_end must be the last envelope of the turn"
    # Usage/num_turns span both responses so Symphony's token accounting stays exact.
    assert turn_ends[0]["num_turns"] == 6
    assert turn_ends[0]["usage"] == {
        "input_tokens": 6,
        "output_tokens": 6,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 6,
    }
    texts = [e["text"] for e in captured if e["type"] == "assistant_message"]
    assert "FINAL: alpha beta" in texts
    # Nothing left over to poison the next turn.
    assert client.pending() == 0


@pytest.mark.asyncio
async def test_background_task_is_bracketed_by_tool_lifecycle_envelopes() -> None:
    """tool_started/tool_finished put the orchestrator on the longer tool-stall
    window while the workflow runs silently."""
    captured = await _run_turn(FakeClient(WORKFLOW_SEQUENCE))

    started = [e for e in captured if e["type"] == "tool_started"]
    finished = [e for e in captured if e["type"] == "tool_finished"]
    assert [e["tool_use_id"] for e in started] == ["toolu_wf"]
    assert [e["tool_use_id"] for e in finished] == ["toolu_wf"]
    assert started[0]["name"] == "local_workflow"
    order = [e["type"] for e in captured]
    assert order.index("tool_started") < order.index("tool_finished") < order.index("turn_end")


@pytest.mark.asyncio
async def test_plain_turn_is_unchanged() -> None:
    client = FakeClient([_text("hi"), _result(1), _text("next turn"), _result(1)])
    captured = await _run_turn(client)

    assert [e["type"] for e in captured] == ["assistant_message", "turn_end"]
    assert captured[-1]["num_turns"] == 1
    # The following turn's traffic stays queued for the next turn.
    assert client.pending() == 2


@pytest.mark.asyncio
async def test_missing_follow_up_flushes_held_turn_end_after_grace() -> None:
    """If the CLI never auto-wakes after the task completes, don't hang: flush
    the held turn_end after the wake grace period."""
    seq = WORKFLOW_SEQUENCE[: WORKFLOW_SEQUENCE.index(_sys("init", session_id="sess-bg"))]
    client = FakeClient(seq, hang_after=True)
    with patch.object(sidecar, "_BACKGROUND_WAKE_GRACE_S", 0.05):
        captured = await _run_turn(client)

    turn_ends = [e for e in captured if e["type"] == "turn_end"]
    assert len(turn_ends) == 1
    assert turn_ends[0]["num_turns"] == 4


@pytest.mark.asyncio
async def test_error_result_while_task_in_flight_ends_turn_immediately() -> None:
    seq = [
        _sys("background_tasks_changed", tasks=[TASK]),
        _sys("task_started", tool_use_id="toolu_wf", **TASK),
        _result(3, is_error=True, subtype="error_max_budget_usd"),
    ]
    client = FakeClient(seq, hang_after=True)
    captured = await _run_turn(client)

    assert captured[-1]["type"] == "error"
    assert not [e for e in captured if e["type"] == "turn_end"]


@pytest.mark.asyncio
async def test_held_turn_is_bracketed_by_turn_held_and_turn_resumed() -> None:
    """Symphony pauses its turn_timeout clock while the turn is held for a
    background task, so the sidecar must say when the hold starts and when the
    last task finishes (IDE-1480: an 82-minute Workflow ate a 90-minute turn
    budget and the coordinator timed out mid-review)."""
    captured = await _run_turn(FakeClient(WORKFLOW_SEQUENCE))

    order = [e["type"] for e in captured]
    assert order.count("turn_held") == 1, captured
    assert order.count("turn_resumed") == 1, captured
    held = next(e for e in captured if e["type"] == "turn_held")
    assert held["background_tasks"] == ["wf1"]
    assert held["session_id"] == "sess-bg"
    # Held only once the model has ended its response; resumed when the last
    # task finishes, before the follow-up response and the merged turn_end.
    assert order.index("tool_started") < order.index("turn_held")
    assert order.index("turn_held") < order.index("turn_resumed") < order.index("turn_end")
    follow_up = next(i for i, e in enumerate(captured) if e.get("text") == "FINAL: alpha beta")
    assert order.index("turn_resumed") < follow_up


@pytest.mark.asyncio
async def test_missing_follow_up_still_resumes_before_flushed_turn_end() -> None:
    seq = WORKFLOW_SEQUENCE[: WORKFLOW_SEQUENCE.index(_sys("init", session_id="sess-bg"))]
    client = FakeClient(seq, hang_after=True)
    with patch.object(sidecar, "_BACKGROUND_WAKE_GRACE_S", 0.05):
        captured = await _run_turn(client)

    order = [e["type"] for e in captured]
    assert order.count("turn_held") == 1
    assert order.index("turn_held") < order.index("turn_resumed") < order.index("turn_end")


@pytest.mark.asyncio
async def test_task_finishing_before_the_response_ends_never_holds() -> None:
    seq = [
        _sys("background_tasks_changed", tasks=[TASK]),
        _sys("task_started", tool_use_id="toolu_wf", **TASK),
        _sys("background_tasks_changed", tasks=[]),
        _text("done already"),
        _result(2),
    ]
    captured = await _run_turn(FakeClient(seq))

    order = [e["type"] for e in captured]
    assert "turn_held" not in order
    assert "turn_resumed" not in order
    assert order[-1] == "turn_end"


@pytest.mark.asyncio
async def test_second_hold_in_one_turn_emits_a_second_pair() -> None:
    task2 = {"task_id": "wf2", "task_type": "local_workflow", "description": "fix"}
    seq = WORKFLOW_SEQUENCE[:-1] + [
        _sys("background_tasks_changed", tasks=[task2]),
        _sys("task_started", tool_use_id="toolu_wf2", **task2),
        _result(1),
        _sys("background_tasks_changed", tasks=[]),
        _sys("init", session_id="sess-bg"),
        _text("FINAL 2"),
        _result(1),
    ]
    captured = await _run_turn(FakeClient(seq))

    order = [e["type"] for e in captured]
    pauses = [t for t in order if t in ("turn_held", "turn_resumed")]
    assert pauses == ["turn_held", "turn_resumed", "turn_held", "turn_resumed"]
    assert order.count("turn_end") == 1 and order[-1] == "turn_end"


@pytest.mark.asyncio
async def test_follow_up_while_another_task_runs_is_active_time() -> None:
    """With two tasks in flight, the CLI auto-starts a follow-up when the first
    one completes. That response is model work, so it must resume the clock,
    and the next held ResultMessage must pause it again (code-review finding)."""
    task_b = {"task_id": "agB", "task_type": "local_agent", "description": "side"}
    seq = [
        _sys("background_tasks_changed", tasks=[TASK, task_b]),
        _sys("task_started", tool_use_id="toolu_wf", **TASK),
        _sys("task_started", tool_use_id="toolu_b", **task_b),
        _text("both launched; waiting"),
        _result(1),
        _sys("background_tasks_changed", tasks=[task_b]),
        _sys("task_notification", task_id="wf1", tool_use_id="toolu_wf", status="completed"),
        _sys("init", session_id="sess-bg"),
        _text("reviewing A while B runs"),
        _result(1),
        _sys("background_tasks_changed", tasks=[]),
        _sys("task_notification", task_id="agB", tool_use_id="toolu_b", status="completed"),
        _sys("init", session_id="sess-bg"),
        _text("FINAL"),
        _result(1),
    ]
    captured = await _run_turn(FakeClient(seq))

    marks = [
        e["type"] if e["type"] in ("turn_held", "turn_resumed", "turn_end") else e.get("text")
        for e in captured
        if e["type"] in ("turn_held", "turn_resumed", "turn_end") or e.get("text") in ("reviewing A while B runs", "FINAL")
    ]
    assert marks == [
        "turn_held",
        "turn_resumed",
        "reviewing A while B runs",
        "turn_held",
        "turn_resumed",
        "FINAL",
        "turn_end",
    ], captured


@pytest.mark.asyncio
async def test_task_progress_during_hold_does_not_resume() -> None:
    seq = [
        _sys("background_tasks_changed", tasks=[TASK]),
        _sys("task_started", tool_use_id="toolu_wf", **TASK),
        _result(1),
        _sys("task_progress", task_id="wf1", tool_use_id="toolu_wf", description="A"),
        _sys("task_updated", task_id="wf1", patch={"status": "running"}),
    ]
    captured = await _run_turn(FakeClient(seq))

    order = [e["type"] for e in captured]
    # Progress keepalives are not model work: the only resume is the flush at
    # stream end, right before the turn_end.
    assert order.count("turn_held") == 1
    assert order.count("turn_resumed") == 1
    assert order[-2:] == ["turn_resumed", "turn_end"]


@pytest.mark.asyncio
async def test_stale_pause_from_a_failed_turn_does_not_leak_into_the_next() -> None:
    """A turn that raised mid-hold leaves turn_paused/held_turn_ends set; the
    next turn must still announce its own hold (code-review finding)."""
    state = SessionState(session_id="sess-bg", turn_paused=True, held_turn_ends=[{"type": "turn_end"}])
    captured = await _run_turn(FakeClient(WORKFLOW_SEQUENCE), state)

    order = [e["type"] for e in captured]
    assert order.count("turn_held") == 1
    assert order.index("turn_held") < order.index("turn_resumed") < order.index("turn_end")
    assert captured[-1]["num_turns"] == 6
