# Investigation: Linear MCP path is always denied before falling back to `linear_graphql`

- **Status:** Resolved (2026-06-19) — root cause confirmed, prompt-only remedy applied. See "Resolution" below.
- **Date raised:** 2026-06-18
- **Area:** Claude adapter (`elixir/priv/claude_agent/`), orchestration prompt (`elixir/WORKFLOW.md`), tool/permission surface
- **Severity:** Low (cost/latency waste, not a correctness bug) — but it happens on **every** orchestration session, so it compounds.

## Problem statement

In every Claude-adapter orchestration session observed so far, the agent's **first**
attempt to talk to Linear is via the Linear MCP plugin tools
(`mcp__plugin_linear_linear__get_issue`, `…__list_comments`, sometimes
`…__save_comment` / `…__save_issue`). These calls are **denied/fail**, the agent
notes "The Linear MCP tools are denied," and then falls back to the
Symphony-injected `mcp__symphony__linear_graphql` tool, which works.

The fallback is reliable, so nothing breaks — but the failed first attempt costs a
`ToolSearch` round-trip plus 2–3 wasted tool calls **per session**, every session,
before any real work starts.

## Evidence (from session transcripts under `~/.claude-identione/projects/…ENG-*`)

Observed across ENG-1 (11 sessions), ENG-2 (3 sessions), ENG-3 (1 session). The
pattern is identical every time. Representative opening sequence (ENG-3,
`0e44e830`):

```
ToolSearch: select:mcp__plugin_linear_linear__get_issue, …__save_issue, …__save_comment, …__list_comments
-> mcp__plugin_linear_linear__get_issue    {"id": "ENG-3"}        # denied
-> mcp__plugin_linear_linear__list_comments {"issueId": "ENG-3"}  # denied
TXT: "The Linear MCP tools are denied. Let me try the Symphony `linear_graphql` tool instead."
-> ToolSearch: select:mcp__symphony__linear_graphql
-> mcp__symphony__linear_graphql  query { issue(id: "ENG-3") { … } }  # works
```

The same "MCP denied → fall back to graphql" detour also recurs **mid-session** for
writes: in ENG-1 `7a27d38a` the agent tried `linear_graphql commentUpdate` (failed —
sim not reachable that way), then MCP `save_comment` (blocked), then finally a raw
`curl` to the local simulator — ~18 turns spent on Linear plumbing rather than work.

Rough cost of the *opening* detour: ~1 `ToolSearch` + 2–3 denied tool calls per
session. Small per run, but it is paid unconditionally on every claim/retry across
all instances.

## Where the behavior originates (starting points, not conclusions)

1. **The prompt invites it.** `elixir/WORKFLOW.md` §"Prerequisite: Linear MCP or
   `linear_graphql` tool is available" (around line 314):

   > "The agent should be able to talk to Linear, either via a configured Linear MCP
   > server or injected `linear_graphql` tool."

   Linear MCP is named **first**, so the model reasonably reaches for it first.

2. **The permission/tool surface decides whether it works.** The Claude sidecar is
   configured via `permission_mode` + `allowed_tools` (`elixir/WORKFLOW.md` lines
   ~179–220; sidecar reads them in
   `elixir/priv/claude_agent/symphony_claude_agent/sidecar.py:529`). The shipped
   `WORKFLOW.md` sets `permission_mode: bypassPermissions` (allow-all), yet the
   plugin Linear tools still come back denied — so the denial is **not** simply the
   `allowed_tools` whitelist. The `mcp__plugin_linear_linear__*` tools are inherited
   from the host Claude Code environment (plugin marketplace), and something between
   that surface and the sidecar is rejecting or not wiring them.

## Open questions to investigate

### A. Why does the agent try the Linear MCP path at all?
- [ ] Is it purely the WORKFLOW.md wording (Linear MCP named first), the `linear`
      skill text (`.codex/skills/linear/SKILL.md`), model prior, or all three?
- [ ] Do the `mcp__plugin_linear_linear__*` tool *schemas* even get advertised to the
      sidecar session? If they're advertised but unusable, the model will keep
      reaching for them. (Check what tool list the sidecar/SDK exposes.)

### B. Why exactly are they denied/failing?
- [ ] Reproduce and capture the **exact** error the SDK returns for
      `mcp__plugin_linear_linear__get_issue` in an orchestration session — is it a
      permission denial, "tool not found / server not connected," an auth error, or a
      `PreToolUse` hook rejection?
- [ ] Is the `plugin:linear:linear` MCP server actually **connected** in the sidecar
      process, or only in interactive Claude Code? (CLAUDE.md note: interactively
      authenticated MCP servers may be absent in headless/cron runs — the same class
      of problem.)
- [ ] Under `bypassPermissions` the `allowed_tools` whitelist is ignored, so the
      denial must come from elsewhere — the workspace-boundary `PreToolUse` hook
      (`sidecar.py:8`), a `disallowed_tools` entry, or the server simply not being
      present. Determine which.
- [ ] Does this differ between `bypassPermissions` and `dontAsk` modes? (Under
      `dontAsk` with the documented `allowed_tools`, only `mcp__symphony__linear_graphql`
      is whitelisted — so MCP linear would be denied *by design* there.)

### C. Is the Linear MCP path ever supposed to work here?
- [ ] Is `linear_graphql` the intended **sole** Linear interface for orchestration
      (it round-trips through Symphony, which owns auth + the sim/live routing), with
      the plugin Linear MCP being an accident of inherited environment?
- [ ] Or do we actually want the richer plugin Linear MCP available and the denial is
      a misconfiguration to fix?

### D. Impact quantification (decide if it's worth fixing)
- [ ] Aggregate the wasted `ToolSearch` + denied-call tokens across a representative
      day of runs (the transcripts make this measurable) to size the fix.

## Hypotheses (to confirm or kill)

1. **Most likely:** the plugin Linear MCP server is *not connected* in the headless
   sidecar (auth/marketplace not available outside interactive Claude Code), so the
   calls fail; the agent tries them only because WORKFLOW.md/skill prose names "Linear
   MCP" first. → Fix is mostly **prompt/guidance**, not permissions.
2. The server *is* connected but blocked by `disallowed_tools` or the `PreToolUse`
   boundary hook. → Fix is **config**.
3. It's intended (graphql-only) and we just want the model to stop trying. → Fix is
   **prompt-only**.

## Candidate remedies (evaluate after the questions above are answered — do not implement yet)

- **Prompt-first (cheapest):** reword the WORKFLOW.md prerequisite + `linear` skill to
  instruct "use `linear_graphql` for all Linear operations; do not attempt
  `mcp__plugin_linear_linear__*`." Removes the detour without touching config.
- **Suppress the tools:** add `mcp__plugin_linear_linear__*` to `disallowed_tools` (or
  don't advertise the plugin server to the sidecar) so the model never sees them.
- **Make it work:** if the plugin Linear MCP is genuinely wanted, ensure the server is
  connected + authenticated in the sidecar and whitelisted — then drop `linear_graphql`
  duplication, or keep it as fallback.
- **Do nothing:** if measured waste is negligible, document the behavior as expected
  and close.

## How to verify a fix

1. Run a fresh orchestration session (e.g. a throwaway ENG-N "create a file" ticket
   against the local simulator, mirroring ENG-3).
2. Confirm in the transcript that the **first** Linear call is `linear_graphql` (or
   the plugin MCP, if remedy = "make it work") with **no** preceding denied attempt.
3. Confirm the ToolSearch for `mcp__plugin_linear_linear__*` is gone.
4. Confirm end-to-end behavior is unchanged: issue claimed, workpad written, PR
   opened, issue moved to Human Review.

## Resolution (2026-06-19)

**Root cause confirmed** against code + SDK + live config:

- The prompt named "Linear MCP" before `linear_graphql` (`elixir/WORKFLOW.md:314`
  and template `elixir/priv/templates/workflow.md.eex:72`), so the model reached for
  the plugin tools first.
- Symphony exposes exactly one Linear tool, the dynamic `linear_graphql`
  (`DynamicTool.tool_specs/0` → init envelope `app_server.ex:349` → sidecar
  `symphony` MCP server `sidecar.py:645-686`), surfaced as
  `mcp__symphony__linear_graphql`. **This is the call that succeeds.**
- The `mcp__plugin_linear_linear__*` tools are *not* Symphony tools. They leak in
  because the Claude adapter defaults `setting_sources: nil` (`config/schema.ex:326`),
  so the SDK loads the workspace's `.claude/settings.json`, whose `enabledPlugins`
  turns on `linear@claude-plugins-official`. Under the `dontAsk` whitelist they are
  then denied.

**`setting_sources` rejected as a lever.** SDK `types.py:1787-1797`: `"project"` =
`.claude/settings.json`, `"local"` = `.claude/settings.local.json`, `"user"` =
`~/.claude/settings.json`; `[]` = none; *"Must include `project` to load CLAUDE.md
files."* The Linear plugin is enabled only in the project + local files (verified —
not at user level), so `["project"]` keeps it, and the only values that drop it
(`["user"]`/`[]`) also strip the repo's CLAUDE.md + project hooks/permissions from
agent runs. No value removes just the plugin.

**Remedy applied (prompt-only):** reworded the WORKFLOW prerequisite + the instance
template to name `linear_graphql` (`mcp__symphony__linear_graphql`) as the sole Linear
interface and to explicitly forbid `mcp__plugin_linear_linear__*`; added a matching
one-liner to `.codex/skills/linear/SKILL.md`. No code/config changes. Verify per the
"How to verify a fix" section: a fresh session's first Linear call should be
`mcp__symphony__linear_graphql` with no preceding plugin-MCP ToolSearch/denied call.

**Deferred:** the missing `PreToolUse` workspace-boundary hook (SPEC §10.8) is a
separate sandbox-compliance gap — track independently.

## Appendix: relevant code/prompt locations

- `elixir/WORKFLOW.md` — Linear prerequisite (~line 314); `permission_mode` /
  `allowed_tools` docs (~lines 179–220).
- `elixir/priv/claude_agent/symphony_claude_agent/sidecar.py` — `permission_mode`,
  `allowed_tools`, `disallowed_tools` handling (~lines 529–531); `PreToolUse`
  workspace boundary (~line 8); `linear_graphql` wiring (~line 648).
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` — `linear_graphql` input schema
  (mirrored by the sidecar fallback schema).
- `.codex/skills/linear/SKILL.md` — the `linear` skill prose the agent may follow.
