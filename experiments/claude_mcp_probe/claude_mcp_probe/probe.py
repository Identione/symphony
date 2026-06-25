from __future__ import annotations

import argparse
import asyncio
import dataclasses
import json
import os
import sys
from pathlib import Path
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    SystemMessage,
    create_sdk_mcp_server,
    tool,
)


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

DUMMY_SCHEMA = {
    "type": "object",
    "properties": {"value": {"type": "string"}},
    "additionalProperties": False,
}

DEFAULT_PROMPT = """\
This is a tool visibility probe.

First call mcp__symphony_workpad__sync_workpad with:
- issue_id: IDE-PROBE
- file_path: /tmp/symphony-workpad-probe.md

Then call mcp__symphony__linear_graphql with:
- query: query Probe { viewer { id } }

If a required tool is not available, use ToolSearch to search for its exact full
name before giving up. In the final answer, say which tool calls succeeded.
"""

STANDARD_ALLOWED_TOOLS = [
    "Read",
    "Glob",
    "Grep",
    "Edit",
    "Write",
    "MultiEdit",
    "Bash",
    "BashOutput",
    "KillBash",
    "TodoWrite",
    "NotebookEdit",
    "Skill",
]


def emit(kind: str, payload: Any) -> None:
    print(json.dumps({"kind": kind, "payload": to_jsonable(payload)}, sort_keys=True), flush=True)


def to_jsonable(value: Any) -> Any:
    if dataclasses.is_dataclass(value):
        return to_jsonable(dataclasses.asdict(value))
    if isinstance(value, dict):
        return {str(k): to_jsonable(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [to_jsonable(v) for v in value]
    if isinstance(value, Path):
        return str(value)
    if hasattr(value, "__dict__"):
        return {
            k: to_jsonable(v)
            for k, v in vars(value).items()
            if not k.startswith("_")
        }
    return value


def build_mcp_servers(dummy_tools: int) -> dict[str, Any]:
    @tool(
        "linear_graphql",
        "Probe Linear GraphQL tool. Returns a small marker payload.",
        LINEAR_SCHEMA,
    )
    async def linear_graphql(args: dict[str, Any]) -> dict[str, Any]:
        emit("tool_called", {"name": "linear_graphql", "args": args})
        return {"ok": True, "tool": "linear_graphql", "marker": "LINEAR_GRAPHQL_CALLED"}

    @tool(
        "sync_workpad",
        "Probe workpad sync tool. Reads a local file path in production; this probe returns a marker.",
        SYNC_WORKPAD_SCHEMA,
    )
    async def sync_workpad(args: dict[str, Any]) -> dict[str, Any]:
        emit("tool_called", {"name": "sync_workpad", "args": args})
        return {"ok": True, "tool": "sync_workpad", "marker": "SYNC_WORKPAD_CALLED"}

    servers = {
        "symphony": create_sdk_mcp_server(
            name="symphony",
            version="0.1.0",
            tools=[linear_graphql],
        ),
        "symphony_workpad": create_sdk_mcp_server(
            name="symphony_workpad",
            version="0.1.0",
            tools=[sync_workpad],
        ),
    }

    for index in range(dummy_tools):
        name = f"dummy_{index:03d}"

        @tool(
            name,
            f"Dummy probe tool {index}.",
            DUMMY_SCHEMA,
        )
        async def dummy(args: dict[str, Any], *, _name: str = name) -> dict[str, Any]:
            emit("tool_called", {"name": _name, "args": args})
            return {"ok": True, "tool": _name}

        servers[f"dummy_server_{index:03d}"] = create_sdk_mcp_server(
            name=f"dummy_server_{index:03d}",
            version="0.1.0",
            tools=[dummy],
        )

    return servers


async def dry_list_servers(servers: dict[str, Any]) -> None:
    from mcp.types import ListToolsRequest

    for server_name, server in servers.items():
        handler = server["instance"].request_handlers[ListToolsRequest]
        result = await handler(ListToolsRequest(method="tools/list"))
        emit(
            "dry_server_tools",
            {
                "server": server_name,
                "tools": [t.name for t in result.root.tools],
            },
        )


def parse_setting_sources(value: str) -> list[str] | None | object:
    if value == "unset":
        return _UNSET
    if value == "none":
        return []
    if value == "all":
        return ["user", "project", "local"]
    if value == "project":
        return ["project"]
    raise ValueError(f"unsupported setting sources: {value}")


_UNSET = object()


def build_allowed_tools(args: argparse.Namespace) -> list[str]:
    allowed = list(args.allowed_tool)
    if args.allowed_standard_tools:
        allowed.extend(STANDARD_ALLOWED_TOOLS)
    if args.allow_probe_tools:
        allowed.extend(
            [
                "mcp__symphony__linear_graphql",
                "mcp__symphony_workpad__sync_workpad",
            ]
        )
    if args.allow_dummy_tools:
        allowed.extend(
            f"mcp__dummy_server_{index:03d}__dummy_{index:03d}"
            for index in range(args.dummy_tools)
        )
    return allowed


def load_prompt(args: argparse.Namespace) -> str:
    if args.prompt_file:
        prompt = Path(args.prompt_file).read_text(encoding="utf-8")
    else:
        prompt = args.prompt
    if args.append_prompt:
        prompt = prompt.rstrip() + "\n\n" + args.append_prompt
    return prompt


def build_options(args: argparse.Namespace, servers: dict[str, Any]) -> ClaudeAgentOptions:
    env = {}
    if args.disable_claudeai_mcp:
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "0"
    for item in args.env:
        key, sep, value = item.partition("=")
        if not sep or not key:
            raise SystemExit(f"--env must be KEY=VALUE, got: {item}")
        env[key] = value

    kwargs: dict[str, Any] = {
        "cwd": str(Path(args.cwd).resolve()),
        "mcp_servers": servers,
        "permission_mode": args.permission_mode,
        "allowed_tools": build_allowed_tools(args),
        "disallowed_tools": list(args.disallowed_tool),
        "system_prompt": {"type": "preset", "preset": "claude_code"},
        "max_turns": args.max_turns,
        "stderr": lambda line: emit("stderr", line.rstrip()),
    }
    if env:
        kwargs["env"] = env
    if args.cli_path:
        kwargs["cli_path"] = args.cli_path
    if args.model:
        kwargs["model"] = args.model
    setting_sources = parse_setting_sources(args.setting_sources)
    if setting_sources is not _UNSET:
        kwargs["setting_sources"] = setting_sources

    emit("options", {k: v for k, v in kwargs.items() if k not in {"mcp_servers", "stderr"}})
    return ClaudeAgentOptions(**kwargs)


async def run_live(args: argparse.Namespace) -> int:
    probe_file = Path("/tmp/symphony-workpad-probe.md")
    probe_file.write_text("## Symphony Workpad\n\nProbe body.\n", encoding="utf-8")

    servers = build_mcp_servers(args.dummy_tools)
    if args.dry_list:
        await dry_list_servers(servers)
        return 0

    options = build_options(args, servers)
    prompt = load_prompt(args)
    emit("prompt", {"chars": len(prompt), "source": args.prompt_file or "inline"})
    async with ClaudeSDKClient(options=options) as client:
        await client.query(prompt)
        async for message in client.receive_response():
            if isinstance(message, SystemMessage):
                emit("system", {"subtype": message.subtype, "data": message.data})
            elif isinstance(message, AssistantMessage):
                emit(
                    "assistant",
                    {
                        "model": message.model,
                        "error": message.error,
                        "stop_reason": message.stop_reason,
                        "content": message.content,
                    },
                )
            elif isinstance(message, ResultMessage):
                emit(
                    "result",
                    {
                        "subtype": message.subtype,
                        "is_error": message.is_error,
                        "num_turns": message.num_turns,
                        "stop_reason": message.stop_reason,
                        "result": message.result,
                        "permission_denials": message.permission_denials,
                        "deferred_tool_use": message.deferred_tool_use,
                        "errors": message.errors,
                    },
                )
            else:
                emit("message", message)
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cwd", default=os.getcwd())
    p.add_argument("--cli-path")
    p.add_argument("--model")
    p.add_argument("--prompt", default=DEFAULT_PROMPT)
    p.add_argument("--prompt-file")
    p.add_argument("--append-prompt", default="")
    p.add_argument("--permission-mode", default="bypassPermissions")
    p.add_argument("--setting-sources", default="unset", choices=["unset", "project", "none", "all"])
    p.add_argument("--max-turns", type=int, default=8)
    p.add_argument("--dummy-tools", type=int, default=0)
    p.add_argument("--dry-list", action="store_true")
    p.add_argument("--disable-claudeai-mcp", action="store_true")
    p.add_argument("--allowed-standard-tools", action="store_true")
    p.add_argument("--allow-probe-tools", action=argparse.BooleanOptionalAction, default=True)
    p.add_argument("--allow-dummy-tools", action="store_true")
    p.add_argument("--allowed-tool", action="append", default=[])
    p.add_argument("--disallowed-tool", action="append", default=[])
    p.add_argument("--env", action="append", default=[])
    return p


def main() -> int:
    args = parser().parse_args()
    try:
        return asyncio.run(run_live(args))
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        emit("probe_error", {"type": type(exc).__name__, "message": str(exc)})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
