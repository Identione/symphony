#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMMY_TOOLS="${DUMMY_TOOLS:-120}"
OUT="${OUT:-experiments/claude_mcp_probe/logs/jai-sdk-probe-dummy-${DUMMY_TOOLS}-$STAMP.jsonl}"
MODE="${MODE:-bloated}"
PY="${PY:-elixir/priv/claude_agent/.venv/bin/python}"

mkdir -p "$(dirname "$OUT")"

case "$MODE" in
  bloated)
    SETTING_ARGS=(--setting-sources unset --env ENABLE_CLAUDEAI_MCP_SERVERS=1)
    ;;
  trimmed)
    SETTING_ARGS=(--setting-sources project --disable-claudeai-mcp)
    ;;
  isolated)
    SETTING_ARGS=(--setting-sources none --disable-claudeai-mcp)
    ;;
  *)
    echo "MODE must be one of: bloated, trimmed, isolated" >&2
    exit 2
    ;;
esac

echo "writing $OUT" >&2
echo "mode=$MODE python=$PY dummy_tools=$DUMMY_TOOLS" >&2

PYTHONPATH=experiments/claude_mcp_probe \
  jai "$PY" -m claude_mcp_probe \
    --permission-mode bypassPermissions \
    --no-allow-probe-tools \
    --dummy-tools "$DUMMY_TOOLS" \
    --prompt-file elixir/WORKFLOW.md \
    --append-prompt '## Probe directive

Ignore unresolved template placeholders in the workflow text above. This is a tool visibility probe, not a real Linear issue.

First use ToolSearch with query select:mcp__symphony_workpad__sync_workpad,mcp__symphony__linear_graphql. Then call mcp__symphony_workpad__sync_workpad with issue_id IDE-PROBE and file_path /tmp/symphony-workpad-probe.md. Then call mcp__symphony__linear_graphql with query: query Probe { viewer { id } }. End with a one-sentence report of which calls succeeded.' \
    "${SETTING_ARGS[@]}" \
    "$@" | tee "$OUT"

echo >&2
echo "summary:" >&2
"$PY" experiments/claude_mcp_probe/summarize_probe.py "$OUT" >&2 || true
