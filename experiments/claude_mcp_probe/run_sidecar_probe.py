from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import sys
from pathlib import Path
from typing import Any


LINEAR_SCHEMA = {
    "type": "object",
    "properties": {
        "query": {"type": "string"},
        "variables": {"type": "object"},
    },
    "required": ["query"],
    "additionalProperties": False,
}

SYNC_WORKPAD_SCHEMA = {
    "type": "object",
    "properties": {
        "issue_id": {"type": "string"},
        "file_path": {"type": "string"},
        "comment_id": {"type": "string"},
    },
    "required": ["issue_id", "file_path"],
    "additionalProperties": False,
}

DEFAULT_APPEND = """\
## Probe directive

Ignore unresolved template placeholders in the workflow text above. This is a
tool visibility probe, not a real Linear issue.

First use ToolSearch with query
select:mcp__symphony_workpad__sync_workpad,mcp__symphony__linear_graphql. Then
call mcp__symphony_workpad__sync_workpad with issue_id IDE-PROBE and file_path
/tmp/symphony-workpad-probe.md. Then call mcp__symphony__linear_graphql with
query: query Probe { viewer { id } }. End with one sentence saying which calls
succeeded.
"""


def emit(kind: str, payload: Any) -> None:
    print(json.dumps({"kind": kind, "payload": payload}, sort_keys=True), flush=True)


def tool_specs() -> list[dict[str, Any]]:
    return [
        {
            "name": "linear_graphql",
            "description": "Execute a raw GraphQL query or mutation against Linear using Symphony auth.",
            "inputSchema": LINEAR_SCHEMA,
        },
        {
            "name": "sync_workpad",
            "description": "Create or update a workpad comment on a Linear issue. Reads the body from a local file.",
            "inputSchema": SYNC_WORKPAD_SCHEMA,
        },
    ]


def load_prompt(args: argparse.Namespace) -> str:
    if args.prompt_file:
        prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    else:
        prompt = args.prompt
    if args.append_prompt:
        prompt = prompt.rstrip() + "\n\n" + args.append_prompt
    return prompt


def init_payload(args: argparse.Namespace) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "type": "init",
        "cwd": str(Path(args.cwd).resolve()),
        "permission_mode": args.permission_mode,
        "allowed_tools": list(args.allowed_tool),
        "disallowed_tools": list(args.disallowed_tool),
        "system_prompt_preset": "claude_code",
        "max_turns": args.max_turns,
        "verbose_logging": args.verbose_logging,
        "tool_specs": tool_specs(),
    }
    if args.setting_sources != "unset":
        payload["setting_sources"] = [] if args.setting_sources == "none" else [args.setting_sources]
    if args.env:
        env = {}
        for item in args.env:
            key, sep, value = item.partition("=")
            if not sep or not key:
                raise SystemExit(f"--env must be KEY=VALUE, got: {item}")
            env[key] = value
        payload["env"] = env
    return payload


async def write_json(proc: asyncio.subprocess.Process, payload: dict[str, Any]) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload).encode("utf-8") + b"\n")
    await proc.stdin.drain()


async def stderr_pump(proc: asyncio.subprocess.Process) -> None:
    assert proc.stderr is not None
    while True:
        line = await proc.stderr.readline()
        if not line:
            return
        emit("sidecar_stderr", line.decode("utf-8", errors="replace").rstrip())


async def handle_tool_call(proc: asyncio.subprocess.Process, env: dict[str, Any]) -> None:
    name = env.get("name")
    tool_use_id = env.get("tool_use_id")
    emit("tool_call_seen", {"name": name, "input": env.get("input"), "tool_use_id": tool_use_id})
    result = {
        "type": "tool_result",
        "tool_use_id": tool_use_id,
        "result": {
            "ok": True,
            "tool": name,
            "data": {"marker": f"{name}_CALLED"},
        },
    }
    await write_json(proc, result)


async def run(args: argparse.Namespace) -> int:
    Path("/tmp/symphony-workpad-probe.md").write_text("## Symphony Workpad\n\nProbe body.\n", encoding="utf-8")

    env = os.environ.copy()
    env["PYTHONPATH"] = "elixir/priv/claude_agent"
    cmd = args.command or [sys.executable, "-m", "symphony_claude_agent"]
    emit("launch", {"cmd": cmd, "cwd": str(Path(args.cwd).resolve())})
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        cwd=args.cwd,
        env=env,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stderr_task = asyncio.create_task(stderr_pump(proc))

    await write_json(proc, init_payload(args))
    prompt = load_prompt(args)
    emit("prompt", {"chars": len(prompt), "source": args.prompt_file or "inline"})

    assert proc.stdout is not None
    ready = False
    turn_sent = False
    while True:
        line = await asyncio.wait_for(proc.stdout.readline(), timeout=args.timeout)
        if not line:
            break
        try:
            env_out = json.loads(line)
        except json.JSONDecodeError:
            emit("sidecar_stdout_raw", line.decode("utf-8", errors="replace").rstrip())
            continue
        emit("sidecar", env_out)
        typ = env_out.get("type")
        if typ == "ready" and not ready:
            ready = True
            await write_json(proc, {"type": "turn", "prompt": prompt})
            turn_sent = True
        elif typ == "tool_call":
            await handle_tool_call(proc, env_out)
        elif typ in {"turn_end", "error"}:
            await write_json(proc, {"type": "shutdown"})
            break

    if not turn_sent:
        emit("probe_error", {"message": "sidecar exited before ready"})
    try:
        await asyncio.wait_for(proc.wait(), timeout=10)
    except asyncio.TimeoutError:
        proc.send_signal(signal.SIGTERM)
        await proc.wait()
    await stderr_task
    return proc.returncode or 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("--cwd", default=os.getcwd())
    p.add_argument("--prompt", default=DEFAULT_APPEND)
    p.add_argument("--prompt-file")
    p.add_argument("--append-prompt", default=DEFAULT_APPEND)
    p.add_argument("--permission-mode", default="bypassPermissions")
    p.add_argument("--setting-sources", default="project", choices=["unset", "project", "none"])
    p.add_argument("--max-turns", type=int, default=8)
    p.add_argument("--verbose-logging", action="store_true")
    p.add_argument("--allowed-tool", action="append", default=[])
    p.add_argument("--disallowed-tool", action="append", default=[])
    p.add_argument("--env", action="append", default=[])
    p.add_argument("--timeout", type=float, default=180)
    p.add_argument("command", nargs=argparse.REMAINDER)
    return p


def main() -> int:
    try:
        return asyncio.run(run(parser().parse_args()))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
