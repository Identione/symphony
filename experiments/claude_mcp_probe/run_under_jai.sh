#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT:-experiments/claude_mcp_probe/logs/jai-sidecar-probe-$STAMP.jsonl}"
MODE="${MODE:-bloated}"
PY="${PY:-elixir/priv/claude_agent/.venv/bin/python}"

mkdir -p "$(dirname "$OUT")"

case "$MODE" in
  bloated)
    # Closest to the pre-mitigation production surface: settings default, personal
    # claude.ai MCP servers enabled, bypassPermissions.
    SETTING_ARGS=(--setting-sources unset --env ENABLE_CLAUDEAI_MCP_SERVERS=1)
    ;;
  trimmed)
    # Current mitigation surface: project settings only and personal claude.ai MCP
    # servers disabled.
    SETTING_ARGS=(--setting-sources project --env ENABLE_CLAUDEAI_MCP_SERVERS=0)
    ;;
  isolated)
    # Deterministic settings isolation: no user/project/local settings.
    SETTING_ARGS=(--setting-sources none --env ENABLE_CLAUDEAI_MCP_SERVERS=0)
    ;;
  *)
    echo "MODE must be one of: bloated, trimmed, isolated" >&2
    exit 2
    ;;
esac

echo "writing $OUT" >&2
echo "mode=$MODE python=$PY" >&2

jai "$PY" experiments/claude_mcp_probe/run_sidecar_probe.py \
  --prompt-file elixir/WORKFLOW.md \
  --permission-mode bypassPermissions \
  "${SETTING_ARGS[@]}" \
  "$@" | tee "$OUT"

echo >&2
echo "summary:" >&2
grep -E '"type":"system_init"|"mcp_servers init status|ToolSearch|tool_call_seen|turn_end|error' "$OUT" >&2 || true
