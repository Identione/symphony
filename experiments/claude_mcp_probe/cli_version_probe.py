from __future__ import annotations

import asyncio
import json
import os
import sys

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    SystemMessage,
    TextBlock,
    ToolUseBlock,
    create_sdk_mcp_server,
    tool,
)

CALLED: list[str] = []

LINEAR_SCHEMA = {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}
WP_SCHEMA = {
    "type": "object",
    "properties": {"issue_id": {"type": "string"}, "file_path": {"type": "string"}},
    "required": ["issue_id", "file_path"],
}


@tool("linear_graphql", "Run a raw GraphQL query against Linear.", LINEAR_SCHEMA)
async def linear_graphql(args):  # noqa: ANN001
    CALLED.append("linear_graphql")
    return {"content": [{"type": "text", "text": json.dumps({"ok": True, "marker": "LINEAR_CALLED"})}]}


@tool("sync_workpad", "Create/update a workpad comment on a Linear issue from a local file.", WP_SCHEMA)
async def sync_workpad(args):  # noqa: ANN001
    CALLED.append("sync_workpad")
    return {"content": [{"type": "text", "text": json.dumps({"ok": True, "marker": "SYNC_WORKPAD_CALLED"})}]}


def build_prompt(wp_tool: str) -> str:
    if os.environ.get("PROBE_NO_TOOLSEARCH_STEP"):
        return f"""This is a tool-visibility probe. Ignore everything else.

You have two Symphony tools available: {wp_tool} (for workpad syncs) and
mcp__symphony__linear_graphql (for Linear GraphQL).

Step 1: call {wp_tool} with issue_id "IDE-PROBE" and file_path "/tmp/x.md".
Step 2: call mcp__symphony__linear_graphql with query "query {{ viewer {{ id }} }}".

If a tool is not available, say so explicitly. Then reply with one sentence
listing which of the two tools you successfully called.
"""
    return f"""This is a tool-visibility probe. Ignore everything else.

Step 1: call ToolSearch with query
select:{wp_tool},mcp__symphony__linear_graphql

Step 2: call {wp_tool} with issue_id "IDE-PROBE" and file_path "/tmp/x.md".

Step 3: call mcp__symphony__linear_graphql with query "query {{ viewer {{ id }} }}".

Then reply with one sentence listing which of the two tools you successfully called.
"""


async def main() -> int:
    cwd = sys.argv[1]
    cli_path = os.environ.get("PROBE_CLI_PATH") or None

    mode = os.environ.get("PROBE_MODE", "one")
    if mode == "two":
        # Mirror the live sidecar: two SEPARATE in-process servers.
        s_main = create_sdk_mcp_server("symphony", tools=[linear_graphql])
        s_wp = create_sdk_mcp_server("symphony_workpad", tools=[sync_workpad])
        mcp_servers = {"symphony": s_main, "symphony_workpad": s_wp}
        wp_tool = "mcp__symphony_workpad__sync_workpad"
    else:
        server = create_sdk_mcp_server("symphony", tools=[linear_graphql, sync_workpad])
        mcp_servers = {"symphony": server}
        wp_tool = "mcp__symphony__sync_workpad"

    default_allowed = ["ToolSearch", wp_tool, "mcp__symphony__linear_graphql"]
    allowed_env = os.environ.get("PROBE_ALLOWED")
    allowed_tools = allowed_env.split(",") if allowed_env else default_allowed
    perm = os.environ.get("PROBE_PERMISSION_MODE", "bypassPermissions")
    model = os.environ.get("PROBE_MODEL")

    opts = ClaudeAgentOptions(
        cwd=cwd,
        mcp_servers=mcp_servers,
        allowed_tools=allowed_tools,
        permission_mode=perm,
        setting_sources=["project"],
        system_prompt={"type": "preset", "preset": "claude_code"},
        max_turns=8,
    )
    if model:
        opts.model = model
    sdk_env = {}
    if os.environ.get("PROBE_SDK_ENV"):
        for pair in os.environ["PROBE_SDK_ENV"].split(","):
            k, _, v = pair.partition("=")
            sdk_env[k] = v
        opts.env = sdk_env
    print(json.dumps({"permission_mode": perm, "allowed_tools": allowed_tools, "model": model, "sdk_env": sdk_env}), flush=True)
    if cli_path:
        opts.cli_path = cli_path

    print(json.dumps({"cwd": cwd, "cli_path": cli_path or "<bundled default>"}), flush=True)

    tool_uses: list[str] = []
    init_seen = {}
    async with ClaudeSDKClient(options=opts) as client:
        await client.query(build_prompt(wp_tool))
        async for msg in client.receive_response():
            if isinstance(msg, SystemMessage) and msg.subtype == "init":
                data = msg.data or {}
                init_seen["mcp_servers"] = data.get("mcp_servers")
                tools = data.get("tools") or []
                init_seen["symphony_tools_in_init"] = [t for t in tools if "symphony" in str(t)]
            elif isinstance(msg, AssistantMessage):
                for b in msg.content:
                    if isinstance(b, ToolUseBlock):
                        tool_uses.append(b.name)
            elif isinstance(msg, ResultMessage):
                break

    print(json.dumps({"init_mcp_servers": init_seen.get("mcp_servers")}, default=str), flush=True)
    print(json.dumps({"init_symphony_tools": init_seen.get("symphony_tools_in_init")}, default=str), flush=True)
    print(json.dumps({"tool_use_blocks": tool_uses}), flush=True)
    print(json.dumps({"HANDLERS_ACTUALLY_RAN": CALLED}), flush=True)
    ok = "sync_workpad" in CALLED
    print(json.dumps({"RESULT": "PASS sync_workpad reachable" if ok else "FAIL sync_workpad NOT reachable"}), flush=True)
    return 0 if ok else 3


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
