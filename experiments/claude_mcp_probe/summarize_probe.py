from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def iter_records(path: Path):
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def payload_text(payload: Any) -> str:
    if isinstance(payload, dict):
        return str(payload.get("text") or payload.get("message") or "")
    return ""


def collect_toolsearch_from_payload(payload: dict[str, Any], out: list[str]) -> None:
    text = payload_text(payload)
    if "ToolSearch" in text or "tool_reference" in text or "No matching deferred tools found" in text:
        out.append(text)

    content = payload.get("content")
    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            name = block.get("name")
            if name == "ToolSearch":
                out.append(f"ToolSearch input={block.get('input')}")
            block_content = block.get("content")
            if isinstance(block_content, list):
                refs = [
                    item.get("tool_name")
                    for item in block_content
                    if isinstance(item, dict) and item.get("type") == "tool_reference"
                ]
                if refs:
                    out.append(f"ToolSearch refs={refs}")
            elif isinstance(block_content, str) and (
                "No matching deferred tools found" in block_content or "tool_reference" in block_content
            ):
                out.append(block_content)

    result = payload.get("tool_use_result")
    if isinstance(result, dict):
        out.append(f"ToolSearch result={result}")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: summarize_probe.py path/to/probe.jsonl", file=sys.stderr)
        return 2

    path = Path(argv[1])
    toolsearch_results: list[str] = []
    tool_calls: list[str] = []
    server_status: list[str] = []
    turn_end: dict[str, Any] | None = None
    errors: list[Any] = []

    for record in iter_records(path):
        payload = record.get("payload")
        kind = record.get("kind")
        if kind == "sidecar" and isinstance(payload, dict):
            typ = payload.get("type")
            text = payload_text(payload)
            if "mcp_servers init status:" in text:
                server_status.append(text)
            collect_toolsearch_from_payload(payload, toolsearch_results)
            if typ == "turn_end":
                turn_end = payload
            if typ == "error":
                errors.append(payload)
        elif kind == "system" and isinstance(payload, dict):
            data = payload.get("data")
            if isinstance(data, dict):
                servers = data.get("mcp_servers")
                if isinstance(servers, list):
                    server_status.append(
                        ", ".join(
                            f"{s.get('name')}={s.get('status')}"
                            for s in servers
                            if isinstance(s, dict)
                        )
                    )
        elif kind in {"assistant", "message"} and isinstance(payload, dict):
            collect_toolsearch_from_payload(payload, toolsearch_results)
        elif kind == "result" and isinstance(payload, dict):
            turn_end = payload
            if payload.get("errors"):
                errors.append(payload)
        if kind in {"tool_call_seen", "tool_called"} and isinstance(payload, dict):
            tool_calls.append(str(payload.get("name")))

    print(f"file: {path}")
    print("server_status:")
    for item in server_status or ["(none)"]:
        print(f"  {item}")
    print("toolsearch:")
    for item in toolsearch_results or ["(none)"]:
        print(f"  {item}")
    print(f"tool_calls: {tool_calls or '(none)'}")
    print(f"turn_end: {turn_end or '(none)'}")
    print(f"errors: {errors or '(none)'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
