# Claude MCP Tool-Search Probe

Small standalone reproducer for Claude CLI deferred-tool behavior with in-process
SDK MCP servers.

It registers:

- `mcp__symphony__linear_graphql`
- `mcp__symphony_workpad__sync_workpad`
- optional dummy MCP tools to push the CLI over its tool-search threshold

The probe is intentionally outside the Symphony runtime path. Use it to compare
tool visibility under different CLI options before changing the production
sidecar.

## Run

From the repo root:

```bash
uv run --project experiments/claude_mcp_probe python -m claude_mcp_probe --dry-list
```

Live run using the SDK-bundled CLI and the same in-process MCP split:

```bash
uv run --project experiments/claude_mcp_probe python -m claude_mcp_probe \
  --permission-mode bypassPermissions \
  --setting-sources project \
  --disable-claudeai-mcp \
  --dummy-tools 80
```

Compare against the intended low-tool-count posture:

```bash
uv run --project experiments/claude_mcp_probe python -m claude_mcp_probe \
  --permission-mode dontAsk \
  --allowed-standard-tools \
  --setting-sources project \
  --disable-claudeai-mcp \
  --dummy-tools 0
```

Useful flags:

- `--dummy-tools N` adds N one-tool in-process MCP servers.
- `--setting-sources unset|project|none|all` controls SDK `setting_sources`.
- `--disable-claudeai-mcp` sets `ENABLE_CLAUDEAI_MCP_SERVERS=0`.
- `--env KEY=VALUE` passes arbitrary CLI env overrides.
- `--cli-path PATH` pins a specific `claude` binary.
- `--prompt TEXT` overrides the default probe prompt.

The live output prints SDK system init data, assistant text, tool-use blocks,
tool results, permission denials, and final result metadata as JSON lines.

## Actual Sidecar Harness

To exercise Symphony's Python sidecar wire protocol instead of calling the SDK
directly:

```bash
PYTHONPATH=experiments/claude_mcp_probe \
  elixir/priv/claude_agent/.venv/bin/python \
  experiments/claude_mcp_probe/run_sidecar_probe.py \
  --prompt-file elixir/WORKFLOW.md
```

This starts `python -m symphony_claude_agent`, sends the same kind of `init`
envelope that `Claude.AppServer` writes, responds to `tool_call` envelopes with
stub results, and prints every sidecar envelope as JSON lines.

## Run Under Jai

On a host/shell where `jai` can enter its sandbox:

```bash
experiments/claude_mcp_probe/run_under_jai.sh
```

That defaults to `MODE=bloated`, the closest pre-mitigation shape:

- `permission_mode: bypassPermissions`
- `setting_sources` unset
- `ENABLE_CLAUDEAI_MCP_SERVERS=1`
- full `elixir/WORKFLOW.md` prompt
- real `symphony_claude_agent` sidecar

Other modes:

```bash
MODE=trimmed experiments/claude_mcp_probe/run_under_jai.sh
MODE=isolated experiments/claude_mcp_probe/run_under_jai.sh
```

Logs are written to `experiments/claude_mcp_probe/logs/*.jsonl`. Summarize one:

```bash
elixir/priv/claude_agent/.venv/bin/python \
  experiments/claude_mcp_probe/summarize_probe.py \
  experiments/claude_mcp_probe/logs/jai-sidecar-probe-YYYYMMDDTHHMMSSZ.jsonl
```

The failure signature to look for is a `ToolSearch` result containing
`No matching deferred tools found` for `mcp__symphony_workpad__sync_workpad`, and
no subsequent `tool_call_seen` entry for `sync_workpad`.
