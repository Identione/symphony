# Symphony Service Specification

Status: Draft v1 (language-agnostic)

Purpose: Define a service that orchestrates coding agents to get project work done.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this
specification does not prescribe one universal policy. Implementations MUST document the selected
behavior.

## 1. Problem Statement

Symphony is a long-running automation service that continuously reads work from an issue tracker
(Linear in this specification version), creates an isolated workspace for each issue, and runs a
coding agent session for that issue inside the workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable daemon workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps the workflow policy in-repo (`WORKFLOW.md`) so teams version the agent prompt and runtime
  settings with their code.
- It provides enough observability to operate and debug multiple concurrent agent runs.

Implementations are expected to document their trust and safety posture explicitly. This
specification does not require a single approval, sandbox, or operator-confirmation policy; some
implementations target trusted environments with a high-trust configuration, while others require
stricter approvals or sandboxing.

Important boundary:

- Symphony is a scheduler/runner and tracker reader.
- Ticket writes (state transitions, comments, PR links) are typically performed by the coding agent
  using tools available in the workflow/runtime environment.
- A successful run can end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from a repository-owned `WORKFLOW.md` contract.
- Expose operator-visible observability (at minimum structured logs).
- Support tracker/filesystem-driven restart recovery without requiring a persistent database; exact
  in-memory scheduler state is not restored.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to edit tickets, PRs, or comments. (That logic lives in the
  workflow prompt and agent tooling.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`.
   - Parses YAML front matter and prompt body.
   - Returns `{config, prompt_template}`.

2. `Config Layer`
   - Exposes typed getters for workflow config values.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the coding agent app-server client.
   - Streams agent updates back to the orchestrator.

7. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

8. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Symphony is easiest to port when kept in these layers:

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` prompt body.
   - Team-specific rules for ticket handling, validation, and handoff.

2. `Configuration Layer` (typed getters)
   - Parses front matter into typed runtime settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (Linear adapter)
   - API calls and normalization for tracker data.

6. `Observability Layer` (logs + OPTIONAL status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (Linear for `tracker.kind: linear` in this specification version).
- Local filesystem for workspaces and logs.
- OPTIONAL workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that conforms to one of Section 10's adapter implementations
  (Codex App-Server in §10.7 or Claude Agent SDK in §10.8).
- Host environment authentication for the issue tracker and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `state_type` (string or null)
  - Tracker workflow-state *type* (for Linear: `triage | backlog | unstarted | started | completed |
    canceled`). State names are operator-customizable; `state_type` is the stable bucket downstream
    consumers (dashboards, icon mappings) SHOULD key off when they need to act on the lifecycle
    stage rather than the display name.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `has_children` (boolean)
  - True when the issue has sub-issues (children). Parent/umbrella issues are
    excluded from candidate selection (see §8.2).
- `parent_id` (string or null)
  - The id of this issue's parent (umbrella) issue, when it is itself a sub-issue.
- `parent` (issue or null)
  - The parent issue, normalized, carrying its own `children` (this issue's
    siblings). Populated inline by the poll query so the dashboard can build a
    sub-issue container from any one managed child without a second fetch
    (see §11 dependency graph).
- `children` (list of issues)
  - This issue's sub-issues, each normalized with `parent_id` backfilled. Bounded
    per parent by a fetch cap.
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
  - YAML front matter root object.
- `prompt_template` (string)
  - Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- coding-agent executable/args/timeouts
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `agent_kind` (string enum, `codex | claude`)
- `session_id` (string)
  - For `agent_kind == codex`: composed as `<thread_id>-<turn_id>`.
  - For `agent_kind == claude`: the Claude Agent SDK `init.session_id` (UUID).
- `thread_id` (string or null; populated when the adapter exposes a thread identity)
- `turn_id` (string or null; populated when the adapter exposes a turn identity)
- `agent_pid` (string or null)
- `last_agent_event` (string/enum or null)
- `last_agent_timestamp` (timestamp or null)
- `last_agent_message` (summarized payload)
- `agent_input_tokens` (integer)
- `agent_output_tokens` (integer)
- `agent_total_tokens` (integer)
  - For `agent_kind == claude`: defined as `agent_input_tokens + agent_output_tokens` (codex
    parity); cache fields below are exposed as siblings, not folded into the total.
- `last_reported_input_tokens` (integer; codex-only — claude `usage` is per-turn additive)
- `last_reported_output_tokens` (integer; codex-only)
- `last_reported_total_tokens` (integer; codex-only)
- `cache_creation_input_tokens` (integer; claude-only — running sum of Anthropic
  `cache_creation_input_tokens` across turns)
- `cache_read_input_tokens` (integer; claude-only — running sum of Anthropic
  `cache_read_input_tokens` across turns)
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying/blocked)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `blocked` (map `issue_id -> blocked entry`; issues paused because the agent reported it needs
  operator input/approval/MCP elicitation. Blocked issues stay `claimed` and are excluded from
  dispatch until reconciliation observes a Linear state change. In-memory only; cleared on restart.
  Surfaced by the Codex adapter only — the Claude sidecar runs unattended and does not report
  input-required blockers.)
- `dependency_blocked` (map `issue_id -> dependency-blocked entry`; observability-only mirror of
  active candidates currently held back by the §8.2 blocker rule — an active issue whose
  `blocked_by` list still contains a non-terminal blocker. Dispatch never consults this map; it is
  rebuilt wholesale on every successful candidate fetch so it self-heals once the upstream blocker
  reaches a terminal state. Last-known-good is kept on candidate-fetch failure / rate limit.
  In-memory only; cleared on restart.)
- `rebase_pending` (map `issue_id -> %{blockers: [identifier]}`; issues that were paused mid-run
  because they gained a non-terminal blocker per §8.2. When such an issue is later re-dispatched —
  its blockers having landed — this entry is consumed to prepend a rebase-on-resume directive to the
  turn-1 prompt, instructing the resuming agent to integrate the now-landed base branch (via the
  `pull` skill) before continuing the ticket work, so it does not build on a stale base. The entry
  is set when the running issue is paused and cleared when it is dispatched. In-memory only; cleared
  on restart.)
- `dependency_graph` (map `issue_id -> graph node projection`; observability-only node set for the
  dashboard dependency graph — managed candidates plus their transitive blockers (`blockers of
  blockers`). Roots are the issues this instance would actually dispatch (the candidate predicate),
  not every issue the active-state poll returns, so an active parent or a leaf failing the
  assignee/label filters does not appear merely because Linear returned it. Rebuilt per successful
  candidate fetch with last-known-good retained on failure. Expansion is bounded by a per-refresh
  round cap and a hard node cap so a deep blocker chain cannot drive unbounded Linear API usage;
  truncated ids surface as placeholder nodes. Never consulted by dispatch. Sub-issue containers are
  overlaid on this set: a node carries `kind` (`:container` for a parent/umbrella node, `:issue`
  otherwise), `parent` (the container id a sub-issue belongs to, or null), and — for sub-issues —
  `managed` (false when this instance would not pick the issue up) with `requirements` (the inverse
  of the dispatch rules: what must change to manage it). Container nodes also carry
  `child_total`/`child_done`. Containers are anchored on managed work: a container is built only for
  the parent of a managed (candidate) issue the poll returned — never for an arbitrary polled parent
  — then *every* sub-issue of that parent is surfaced (managed or not) so the operator sees the full
  family. Container expansion is subject to the same node cap.)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `agent_totals` (aggregate tokens + runtime seconds; tracked per active adapter — codex totals
  and claude totals are stored separately so adapter-specific cache fields stay typed correctly)
- `agent_rate_limits` (latest rate-limit snapshot from agent events; MAY be `null` for adapters that
  do not surface rate-limit data — the Claude adapter does not surface in-band rate limits)
- `provider_quotas` (latest normalized account-quota snapshot per provider, keyed `codex` and
  `claude`; see §5.3.5.3 and §8.3). Each entry MAY be `null` when no snapshot has been collected
  yet. The `codex` entry is derived from the app-server rate-limit stream; the `claude` entry comes
  from the OPTIONAL OAuth usage poller. Used for dashboard display and, when
  `agent.<provider>.quota.enabled`, the dispatch-pause gate.

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the workspace directory name.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - For `agent_kind == codex`: compose from coding-agent `thread_id` and `turn_id` as
    `<thread_id>-<turn_id>`.
  - For `agent_kind == claude`: use the Claude Agent SDK session UUID as reported in the first
    `system_init` event.

## 5. Workflow Specification (Repository Contract)

### 5.1 File Discovery and Path Resolution

Workflow file path precedence:

1. Explicit application/runtime setting (set by CLI startup path).
2. Default: `WORKFLOW.md` in the current process working directory.

Loader behavior:

- If the file cannot be read, return `missing_workflow_file` error.
- The workflow file is expected to be repository-owned and version-controlled.

### 5.2 File Format

`WORKFLOW.md` is a Markdown file with OPTIONAL YAML front matter.

Design note:

- `WORKFLOW.md` SHOULD be self-contained enough to describe and run different workflows (prompt,
  runtime settings, hooks, and tracker selection/config) without requiring out-of-band
  service-specific configuration.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter MUST decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config`: front matter root object (not nested under a `config` key).
- `prompt_template`: trimmed Markdown body.

### 5.3 Front Matter Schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`

Unknown keys SHOULD be ignored for forward compatibility.

Note:

- The workflow front matter is extensible. Extensions MAY define additional top-level keys without
  changing the core schema above.
- Extensions SHOULD document their field schema, defaults, validation rules, and whether changes
  apply dynamically or require restart.

#### 5.3.1 `tracker` (object)

Fields:

- `kind` (string)
  - REQUIRED for dispatch.
  - Current supported value: `linear`
- `endpoint` (string)
  - Default for `tracker.kind == "linear"`: `https://api.linear.app/graphql`
- `api_key` (string)
  - MAY be a literal token or `$VAR_NAME`.
  - Canonical environment variable for `tracker.kind == "linear"`: `LINEAR_API_KEY`.
  - If `$VAR_NAME` resolves to an empty string, treat the key as missing.
- `project_slug` (string)
  - REQUIRED for dispatch when `tracker.kind == "linear"`.
- `active_states` (list of strings)
  - Default: `Todo`, `In Progress`
- `terminal_states` (list of strings)
  - Default: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`
- `required_labels` (list of strings)
  - Default: empty (no gating).
  - When non-empty, an issue is dispatch-eligible only if it carries *all*
    of these labels. Matching is case-insensitive.
- `excluded_labels` (list of strings)
  - Default: empty (no gating).
  - When non-empty, an issue is *not* dispatch-eligible if it carries *any*
    of these labels. Matching is case-insensitive. An excluded label always
    disqualifies, regardless of `required_labels`.

#### 5.3.2 `polling` (object)

Fields:

- `interval_ms` (integer)
  - Default: `30000`
  - Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/symphony_workspaces`
  - `~` is expanded.
  - Relative paths are resolved relative to the directory containing `WORKFLOW.md`.
  - The effective workspace root is normalized to an absolute path before use.

#### 5.3.4 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, OPTIONAL)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, OPTIONAL)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, OPTIONAL)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, OPTIONAL)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Invalid values fail configuration validation.
  - Changes SHOULD be re-applied at runtime for future hook executions.

#### 5.3.5 `agent` (object)

Fields:

- `max_concurrent_agents` (integer)
  - Default: `10`
  - Changes SHOULD be re-applied at runtime and affect subsequent dispatch decisions.
- `max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `max_retry_backoff_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `max_concurrent_agents_by_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (non-positive or non-numeric) are ignored.
- `kind` (string enum)
  - Allowed values: `codex`, `claude`.
  - Default: `codex`.
  - Selects which coding-agent adapter implementation Symphony launches per session
    (see Section 10).
  - Adapter selection is fixed at the moment a session starts; reload of `agent.kind` affects
    only future agent launches and does not migrate in-flight sessions.

##### 5.3.5.1 `agent.codex` (object)

Configures the Codex App-Server adapter (Section 10.7).

For Codex-owned config values such as `approval_policy`, `thread_sandbox`, and
`turn_sandbox_policy`, supported values are defined by the targeted Codex app-server version.
Implementors SHOULD treat them as pass-through Codex config values rather than relying on a
hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `command` (string shell command)
  - Default: `codex app-server`
  - The runtime launches this command via `bash -lc` in the workspace directory.
  - The launched process MUST speak a compatible app-server protocol over stdio.
- `approval_policy` (Codex `AskForApproval` value)
  - Default: implementation-defined.
- `thread_sandbox` (Codex `SandboxMode` value)
  - Default: implementation-defined.
- `turn_sandbox_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined.
  - Runtime note: when the policy type is `workspaceWrite`, implementations should ensure the
    current issue workspace remains writable even when callers supply additional `writableRoots`.
- `use_configured_permissions` (boolean)
  - Default: `false`.
  - When `true`, the runtime MUST NOT send `sandbox` or `sandboxPolicy` fields on `thread/start`
    or `turn/start`. The Codex process retains its own permission/sandbox settings as configured
    via its CLI/config (or as imposed by an external wrapper around `command`, e.g. an OS-level
    sandbox launcher). Operators using this mode are responsible for ensuring the wrapper
    constrains writes to the per-issue workspace; the runtime continues to enforce that the
    Codex process cwd lives under `workspace.root`, but does not enforce filesystem/network
    policy itself.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `5000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.
- `quota` (object, OPTIONAL)
  - Account-quota tracking + dispatch-pause config; see §5.3.5.3. For Codex the snapshot is derived
    from the app-server rate-limit stream (no polling), so only `enabled`, `stale_after_ms`, and
    `dispatch_pause_percent` are meaningful; the Claude OAuth poller fields are ignored.

##### 5.3.5.2 `agent.claude` (object)

Configures the Claude Agent SDK adapter (Section 10.8). The Claude adapter is implemented as a
long-lived subprocess (the "sidecar") that hosts the Claude Agent SDK and exposes a JSON-line
protocol to Symphony shaped like the Codex app-server client.

- `command` (string shell command)
  - Default: `jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent`
  - `$SYMPHONY_CLAUDE_PRIV_DIR` is injected by the implementation at sidecar launch and points
    at the Python sidecar's `priv` directory (`<priv-claude-agent>`); `bash` expands it at exec.
  - The default ships with `jai` so the recommended outer-sandbox containment (Linux 6.13+) works
    out of the box; hosts without jai MUST override this to drop the prefix
    (`uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent`).
  - Mirrors `agent.codex.command` semantics: launched via `bash -lc` in the workspace directory.
- `model` (string)
  - Default: implementation-defined; SHOULD be a current Anthropic model id.
- `permission_mode` (string enum)
  - Allowed values mirror the Claude Agent SDK's `permission_mode`: `default`, `acceptEdits`,
    `plan`, `dontAsk`, `bypassPermissions`. (The TypeScript-only `auto` value is intentionally
    not listed here; Symphony targets the Python SDK.)
  - Schema default (when omitted): `dontAsk`. Note this differs from what generated instances
    *ship*: `make init` and the maintainer `WORKFLOW.md` write an explicit
    `permission_mode: bypassPermissions` because they run under the `jai` outer sandbox. See the
    two postures in §10.8 sandbox mapping.
  - **NOTE**: `bypassPermissions` causes the SDK to skip the `can_use_tool` callback entirely, so
    it MUST NOT be combined with `can_use_tool` policy enforcement, and the deployment MUST supply
    external isolation (the `jai` sandbox, a container, or a VM) as the containment boundary
    (Posture A in §10.8). For an unattended deployment *without* an outer sandbox, use `dontAsk`
    with an explicit `allowed_tools` whitelist (see `agent.claude.allowed_tools` below) plus
    `PreToolUse` hooks (Posture B). An empty/absent `allowed_tools` under `dontAsk` denies every
    tool and is rejected at boot.
- `allowed_tools` (list of strings)
  - Default: `[]` (empty list — no tools permitted; conservative).
  - Whitelist of SDK tool names the agent may invoke when `permission_mode == "dontAsk"`.
    Custom in-process MCP tools registered via §10.8 use the `mcp__<server_name>__<tool_name>`
    naming convention.
- `disallowed_tools` (list of strings)
  - Default: `[]`.
  - Explicit deny list applied before `allowed_tools`.
- `system_prompt_preset` (string enum)
  - Allowed values: `claude_code`, `minimal`.
  - Default: `claude_code`.
- `setting_sources` (list of strings or null)
  - Default: unset/null — load the Claude Agent SDK's default sources (`user`, `project`,
    `local`), matching an interactive `claude` run in the workspace. The sidecar MUST omit
    `setting_sources` from the SDK options when unset so the SDK applies its own all-sources
    default; consequently the agent inherits the target repo's `.claude/settings.json`
    (including `enableAllProjectMcpServers`), project `.mcp.json` MCP servers (e.g. an `lsp`
    code-intelligence server), and `CLAUDE.md`.
  - An explicit `[]` restores deterministic isolation: the sidecar MUST NOT inherit
    `.claude/settings.json`, home settings, or other host-level Claude Code configuration. A
    subset such as `["project"]` loads only the named layers.
  - Safety for the inherited surface (repo-supplied hooks and permission rules) rests on the
    outer sandbox (jai, §15.5) plus the workspace-cwd invariant (§15.2), NOT on settings
    isolation. Deployments without an outer sandbox SHOULD set `setting_sources: []`.
  - Project `.mcp.json` server tools must additionally be permitted to be callable under
    `dontAsk`: either the repo's loaded `.claude/settings.json` `permissions.allow` covers
    them, or `agent.claude.allowed_tools` lists `mcp__<server>` (e.g. `mcp__lsp`).
- `max_turns` (positive integer or null)
  - Default: implementation-defined.
  - When set, caps the SDK-internal turn budget for one Symphony turn (separate from
    `agent.max_turns` which caps Symphony's continuation loop).
- `max_budget_usd` (number or null)
  - Default: `null`.
  - Optional SDK-side cost ceiling.
- `tool_output_limit` (non-negative integer)
  - Default: implementation-defined (`16384` in the reference implementation).
  - Per-call byte cap on native-tool output (e.g. `Read`/`Bash`/`Grep`/`Glob`). The sidecar
    SHOULD register a `PostToolUse` hook that shrinks oversized string leaves of the tool
    response head+tail — preserving the tool's output schema — so a large result is not re-sent
    as `cache_read` on every subsequent turn. `0` disables the hook.
- `extra_env` (map)
  - Default: `{}`.
  - Additional environment variables forwarded to the sidecar process.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour).
- `read_timeout_ms` (integer)
  - Default: `5000`.
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes).
  - If `<= 0`, stall detection is disabled.
- `quota` (object, OPTIONAL)
  - Account-quota tracking + dispatch-pause config; see §5.3.5.3. For Claude, when `enabled` the
    runtime polls the OAuth usage endpoint (`endpoint`, `anthropic_beta`, `refresh_ms`,
    `token_source`) to populate the snapshot.

Authentication note:

- `ANTHROPIC_API_KEY` is the canonical environment variable, resolved via the same `$VAR`
  indirection rules used elsewhere (for example `tracker.api_key`).
- Provider-routing environment variables — currently `CLAUDE_CODE_USE_BEDROCK` (Amazon Bedrock),
  `CLAUDE_CODE_USE_VERTEX` (Google Vertex AI), and `CLAUDE_CODE_USE_FOUNDRY` (Microsoft Azure AI
  Foundry) — are forwarded to the sidecar when present in the host environment so deployments can
  run against an alternative provider without touching Symphony config. Provider credentials
  (e.g. AWS / GCP / Azure auth) are forwarded the same way.

##### 5.3.5.3 `agent.<provider>.quota` (object, OPTIONAL)

Account-level quota tracking and an OPTIONAL quota-aware dispatch-pause gate. The same object shape
is accepted under both `agent.codex.quota` and `agent.claude.quota` (Codex config may equivalently
be placed at the canonical top-level `codex.quota`, which the runtime keeps in sync with
`agent.codex.quota`). Quota *tracking and display* are independent of `enabled` — only the
dispatch-pause action is gated — so turning the gate on never changes how usage is surfaced.

When `enabled` and the active provider's freshest (non-stale) snapshot reports any bucket at or
above `dispatch_pause_percent`, the orchestrator stops dispatching *new* work for that tick (running
agents and reconciliation are unaffected); see §8.3. Bucket usage is a 0–100 percentage for both
providers (Codex `usedPercent`, Claude `utilization`).

Fields:

- `enabled` (boolean)
  - Default: `false`. Opt in to the dispatch-pause gate for this provider. For Claude this also
    starts the OAuth usage poller (without it there is no Claude snapshot to gate on).
- `dispatch_pause_percent` (number, 0–100)
  - Default: `95.0`. Pause new dispatch when any bucket's usage is `>=` this value.
- `stale_after_ms` (integer > 0)
  - Default: `180000` (3 minutes). Snapshots older than this are ignored by the gate (fail-open:
    when usage is unknown, dispatch is allowed).
- `endpoint` (string) — Claude only
  - Default: `https://api.anthropic.com/api/oauth/usage`.
- `anthropic_beta` (string) — Claude only
  - Default: `oauth-2025-04-20`. Value sent in the `anthropic-beta` request header.
- `refresh_ms` (integer > 0) — Claude only
  - Default: `60000` (1 minute). Poll cadence for the OAuth usage endpoint.
- `token_source` (enum) — Claude only
  - Allowed values: `credentials_file`, `claude_cli_refresh`. Default: `credentials_file`. The OAuth
    token is read from `$CLAUDE_CODE_OAUTH_TOKEN` when set, otherwise from
    `<config_dir>/.credentials.json` (`agent.claude.config_dir`, else `$CLAUDE_CONFIG_DIR`, else
    `~/.claude`).
  - `claude_cli_refresh` additionally renews the cached OAuth access token in place: when it is
    within `cli_refresh_margin_ms` of expiry, the poller runs `cli_refresh_command` — a
    zero-inference `claude` CLI startup that performs the OAuth refresh-token grant and rewrites the
    credentials file — before reading the token. This keeps an otherwise-idle deployment's token
    alive without re-implementing OAuth. Only the credentials-file path is eligible; a set
    `$CLAUDE_CODE_OAUTH_TOKEN` (or API-key/cloud-provider auth) skips it. Refresh failures are
    non-fatal (the poller falls back to the on-disk token).
- `cli_refresh_command` (string) — Claude only
  - Default: `claude -p /exit`. The command run (via `bash -lc`, from a scratch cwd, with
    `CLAUDE_CONFIG_DIR` pinned to the resolved credentials dir) to trigger a CLI-side token refresh.
    Only used when `token_source == claude_cli_refresh`.
- `cli_refresh_margin_ms` (integer > 0) — Claude only
  - Default: `300000` (5 minutes). Run `cli_refresh_command` only when the cached token expires
    within this window (so it fires roughly once per token lifetime, not every poll).

#### 5.3.6 `repo` (object, OPTIONAL)

Declarative metadata about the source repository the workflow targets. Both fields are OPTIONAL
so legacy workflows that hardcode the clone URL inside `hooks.after_create` keep parsing.

Fields:

- `url` (string, OPTIONAL)
  - Canonical clone URL Symphony hands to `hooks.after_create` for fresh per-issue workspaces.
  - Implementations MAY consult `url` from a project-bootstrap preflight that performs an
    unauthenticated reachability probe (e.g. `git ls-remote`) without spawning the coding agent.
  - When absent, preflight reachability checks SHOULD be reported as skipped, not failed.
- `path` (path string or `$VAR`, OPTIONAL)
  - Optional pointer to a local working copy of the repo.
  - Symphony itself MUST NOT read or write through `repo.path`; it exists so repo-local skills
    can find a stable on-disk copy outside the per-issue workspace.
  - `~` and `$VAR` are expanded under the same rules as other path fields.

### 5.4 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime MAY use a minimal default prompt
  (`You are working on an issue from Linear.`).
- Workflow file read/parse failures are configuration/validation errors and SHOULD NOT silently fall
  back to a prompt.

### 5.5 Workflow Validation and Error Surface

Error classes:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Configuration is resolved in this order:

1. Select the workflow file path (explicit runtime setting, otherwise cwd default).
2. Parse YAML front matter into a raw config map.
3. Apply built-in defaults for missing OPTIONAL fields.
4. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
5. Coerce and validate typed values.

Environment variables do not globally override YAML values. They are used only when a config value
explicitly references them.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.
- Relative `workspace.root` values resolve relative to the directory containing the selected
  `WORKFLOW.md`.

### 6.2 Dynamic Reload Semantics

Dynamic reload is REQUIRED:

- The software MUST detect `WORKFLOW.md` changes.
- On change, it MUST re-read and re-apply workflow config and prompt template without restart.
- The software MUST attempt to adjust live behavior to the new config (for example polling
  cadence, concurrency limits, active/terminal states, agent settings, workspace paths/hooks, and
  prompt content for future runs).
- `agent.kind` reload affects only future agent launches; in-flight sessions keep the adapter
  kind they were started with.
- Reloaded config applies to future dispatch, retry scheduling, reconciliation decisions, hook
  execution, and agent launches.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) MAY
  require restart unless the implementation explicitly supports live rebind.
- Implementations SHOULD also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads MUST NOT crash the service; keep operating with the last known good effective
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- Workflow file can be loaded and parsed.
- `tracker.kind` is present and supported.
- `tracker.api_key` is present after `$` resolution.
- `tracker.project_slug` is present when REQUIRED by the selected tracker kind.
- `agent.kind` is one of the supported values (`codex`, `claude`).
- The selected adapter's required keys are present and non-empty:
  - `agent.kind == codex`: `agent.codex.command` is present and non-empty.
  - `agent.kind == claude`: `agent.claude.command` is present and non-empty AND the resolved
    value of `ANTHROPIC_API_KEY` (or the equivalent provider-auth environment variable the
    adapter implementation documents, e.g. for Bedrock/Vertex/Foundry routing) is non-empty.

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

- `tracker.kind`: string, REQUIRED, currently `linear`
- `tracker.endpoint`: string, default `https://api.linear.app/graphql` when `tracker.kind=linear`
- `tracker.api_key`: string or `$VAR`, canonical env `LINEAR_API_KEY` when `tracker.kind=linear`
- `tracker.project_slug`: string, REQUIRED when `tracker.kind=linear`
- `tracker.active_states`: list of strings, default `["Todo", "In Progress"]`
- `tracker.terminal_states`: list of strings, default `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`
- `tracker.required_labels`: list of strings, default `[]` (empty = no gating; case-insensitive, issue must carry *all* listed labels)
- `tracker.excluded_labels`: list of strings, default `[]` (empty = no gating; case-insensitive, issue must carry *none* of the listed labels)
- `polling.interval_ms`: integer, default `30000`
- `workspace.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `repo.url`: string or null, default `null` (consumed by `hooks.after_create` and project-bootstrap preflight)
- `repo.path`: path or null, default `null` (operator-facing only; Symphony never reads/writes through it)
- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.max_concurrent_agents`: integer, default `10`
- `agent.max_turns`: integer, default `20`
- `agent.max_retry_backoff_ms`: integer, default `300000` (5m)
- `agent.max_concurrent_agents_by_state`: map of positive integers, default `{}`
- `agent.budget_pressure_turns`: non-negative integer, default `2` — inject budget-pressure
  steering into continuation prompts when within this many turns of `agent.max_turns`; must leave
  >=1 actionable turn, `0` disables (see §6 continuation loop)
- `agent.preserve_uncommitted_work`: boolean, default `true` — snapshot a dirty working tree to a
  `refs/symphony/wip/<id>` commit before any session stop or `max_turns` cutoff (see §9.4)
- `agent.preserve_uncommitted_work_branch`: boolean, default `false` — also create a visible
  `symphony/wip/<id>` branch alongside the ref
- `agent.cutoff_timeout_ms`: positive integer, default `60000` — timeout for the preservation
  git-shell invocation
- `agent.progress_signal_enabled`: boolean, default `true` — compute deterministic per-turn
  progress signals (see §13.5)
- `agent.progress_signal_window_k`: integer `>= 2`, default `4` — consecutive-turn window `K`
  before `:stuck_state`/`:repeated_error` fire and the turn floor for `at_risk_no_commits`
- `agent.progress_signal_git_timeout_ms`: positive integer, default `2000` — timeout for the
  per-turn progress git probe; a slow/locked repo degrades to "unknown" (assessment unchanged)
- `agent.progress_trigger_min_turns`: integer `>= 1`, default `4` — turn floor for the
  `at_risk_no_commits` arm of the Layer-2 trigger predicate
- `agent.overseer`: object, OPTIONAL — the Layer-2 AI overseer (§13.6). Disabled by default; never
  changes the turn budget; fails open. Fields:
  - `agent.overseer.enabled`: boolean, default `false` — master switch. An absent/empty resolved
    `api_key` also disables it regardless of this flag.
  - `agent.overseer.engine`: enum (`api` | `sidecar`), default `api` — only `api` (read-only
    Anthropic Messages call) is implemented; `sidecar` is reserved and fails open.
  - `agent.overseer.model`: string, default `claude-sonnet-4-6`
  - `agent.overseer.effort`: string, default `low` — carried for adapter parity; not forwarded on
    the direct Messages API path today
  - `agent.overseer.api_key`: string, default `$ANTHROPIC_API_KEY` — resolved like
    `tracker.api_key`/`$LINEAR_API_KEY`
  - `agent.overseer.budget_threshold_k`: non-negative integer, default `4` — fire when
    `turn >= agent.max_turns - k`
  - `agent.overseer.min_turns_between`: non-negative integer, default `3` — cooldown between calls
  - `agent.overseer.max_calls_per_session`: non-negative integer, default `2` — per-run call cap
  - `agent.overseer.transcript_window`: non-negative integer, default `40` — bounded transcript
    ring-buffer size fed as evidence
  - `agent.overseer.log_globs`: array of strings, default
    `["tmp/*build*.log", "tmp/*test*.log", "tmp/*validate*.log"]` — workspace-relative globs whose
    tails are read as build/test evidence
  - `agent.overseer.input_byte_limit`: non-negative integer, default `16384` — per-evidence-section
    byte cap
  - `agent.overseer.confidence_floor`: float `0.0..1.0`, default `0.6` — below this the verdict is
    downgraded to a comment-only `continue`
  - `agent.overseer.allow_abort`: boolean, default `false` — when false an `abort` verdict is
    treated as `escalate`
  - `agent.overseer.timeout_ms`: positive integer, default `30000` — overseer request timeout
- `agent.kind`: enum (`codex` | `claude`), default `codex`
- `agent.codex.command`: shell command string, default `codex app-server`
- `agent.codex.approval_policy`: Codex `AskForApproval` value, default implementation-defined
- `agent.codex.thread_sandbox`: Codex `SandboxMode` value, default implementation-defined
- `agent.codex.turn_sandbox_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `agent.codex.turn_timeout_ms`: integer, default `3600000`
- `agent.codex.read_timeout_ms`: integer, default `5000`
- `agent.codex.stall_timeout_ms`: integer, default `300000`
- `agent.codex.quota`: object, OPTIONAL — see §5.3.5.3 (Codex honors `enabled`, `stale_after_ms`,
  `dispatch_pause_percent`)
- `agent.claude.command`: shell command string, default
  `jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent`
  (see §10.8 for the `jai` default and the `SYMPHONY_CLAUDE_PRIV_DIR` env-var indirection)
- `agent.claude.model`: string, default implementation-defined
- `agent.claude.permission_mode`: enum
  (`default` | `acceptEdits` | `plan` | `dontAsk` | `bypassPermissions`), default `dontAsk`
- `agent.claude.allowed_tools`: list of strings, default `[]`
- `agent.claude.disallowed_tools`: list of strings, default `[]`
- `agent.claude.system_prompt_preset`: enum (`claude_code` | `minimal`), default `claude_code`
- `agent.claude.setting_sources`: list of strings or null, default null (load the SDK's default
  sources — CLI parity; inherits the repo's `.claude/settings.json`, `.mcp.json`, `CLAUDE.md`).
  Set `[]` for deterministic isolation.
- `agent.claude.max_turns`: positive integer or null, default implementation-defined
- `agent.claude.max_budget_usd`: number or null, default `null`
- `agent.claude.effort`: enum (`low` | `medium` | `high` | `xhigh` | `max`) or null,
  default `null` (SDK default, `high`). Reasoning-effort level forwarded to the Claude Agent
  SDK; `xhigh` requires Opus 4.7 and falls back to `high` on other models.
- `agent.claude.extra_env`: map, default `{}`
- `agent.claude.turn_timeout_ms`: integer, default `3600000`
- `agent.claude.read_timeout_ms`: integer, default `5000`
- `agent.claude.stall_timeout_ms`: integer, default `300000`
- `agent.claude.tool_stall_timeout_ms`: integer, default `1800000`. While a
  native Claude tool call (e.g. a long `Bash` build) is in flight the agent is
  silent on the wire, so the idle `stall_timeout_ms` would misread it as a hang.
  This longer window applies instead whenever ≥1 native tool is executing,
  tracked via the sidecar's `tool_started`/`tool_finished` lifecycle hooks.
  Bounded in practice by `turn_timeout_ms`. Codex needs no analogue — it streams
  exec output natively, keeping the idle timer fresh. See §10.8 / §5.3.5.
- `agent.claude.verbose_logging`: boolean, default `false`. When `true`, opt
  into the Claude debug feed (SDK partial-message + hook-event streams, the
  underlying `claude` CLI's stderr forwarded as `log` envelopes, and the
  orchestrator's per-envelope `tool_call`/`assistant_message`/`turn_completed`/
  `permission_request`/`system_init` log lines). Off by default so normal
  operation stays quiet — see §10.8.
- `agent.claude.quota`: object, OPTIONAL — see §5.3.5.3 (Claude additionally polls the OAuth usage
  endpoint via `endpoint`, `anthropic_beta`, `refresh_ms`, `token_source` when `enabled`)

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Issue Orchestration States

This is not the same as tracker states (`Todo`, `In Progress`, etc.). This is the service's internal
claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- The worker MAY continue through multiple back-to-back coding-agent turns before it exits.
- After each normal turn completion, the worker re-checks the tracker issue state.
- If the issue is still in an active state, the worker SHOULD start another turn on the same live
  coding-agent thread in the same workspace, up to `agent.max_turns`.
- The first turn SHOULD use the full rendered task prompt.
- Continuation turns SHOULD send only continuation guidance to the existing thread, not resend the
  original task prompt that is already present in thread history.
- **Budget-pressure steering (IDE-189).** When the continuation march is within
  `agent.budget_pressure_turns` of `agent.max_turns`, the continuation guidance for the *next* turn
  SHOULD carry an explicit directive to commit the current working state now (even if incomplete),
  so converging work is captured before the cap forcibly stops the run. Because a prompt is atomic
  once sent, the directive rides a turn the agent can still act on: the threshold MUST leave at
  least one actionable turn (it is only appended while `max_turns - turn_number > 0`), and never on
  the final turn where it would be useless. `agent.budget_pressure_turns: 0` disables this. This is
  best-effort steering; durable correctness is guaranteed by the non-destructive cutoff (§9.4), not
  by the agent obeying the directive.
- Once the worker exits normally, the orchestrator still schedules a short continuation retry
  (about 1 second) so it can re-check whether the issue remains active and needs another worker
  session.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule continuation retry (attempt `1`) after the worker exhausts or finishes its in-process
    turn loop.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Agent Update Event`
  - Update live session fields, token counters, and rate limits (when the active adapter
    surfaces them).

- `Retry Timer Fired`
  - Re-fetch active candidates and attempt re-dispatch, or release claim if no longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `Stall Timeout`
  - Kill worker and schedule retry.

### 7.4 Idempotency and Recovery Rules

- The orchestrator serializes state mutations through one authority to avoid duplicate dispatch.
- `claimed` and `running` checks are REQUIRED before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven (without a durable orchestrator DB).
- Startup terminal cleanup removes stale workspaces for issues already in terminal states.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `polling.interval_ms`.

The effective poll interval SHOULD be updated when workflow config changes are re-applied.

Tick sequence:

1. Reconcile running issues.
2. Run dispatch preflight validation.
3. Fetch candidate issues from tracker using active states.
4. Roll up parent/umbrella issues whose sub-issues are all `Done` (§8.7).
5. Sort issues by dispatch priority.
6. Dispatch eligible issues while slots remain.
7. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

An issue is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its state is in `active_states` and not in `terminal_states`.
- If `required_labels` is non-empty, it carries *all* of those labels (case-insensitive).
- If `excluded_labels` is non-empty, it carries *none* of those labels (case-insensitive).
- It is not a parent/umbrella issue:
  - An issue that has sub-issues (children) is a tracker, not a work unit — its
    work lives in the children. Parent issues are never dispatch-eligible,
    regardless of state, so the agent cannot re-implement a sub-issue's scope and
    collide with the sub-issue's own PR. (Parents are still surfaced for
    observability as container nodes in the dependency graph — see §4.2's
    `dependency_graph` — grouping their sub-issues, including ones this instance
    does not manage. A parent is also rolled up to `Done` once all of its
    sub-issues are `Done` — see §8.7.)
- It is not already in `running`.
- It is not already in `claimed`.
- Global concurrency slots are available.
- Per-state concurrency slots are available.
- Blocker rule passes:
  - Do not dispatch an issue in any active state when any blocker is non-terminal. Issues that
    fail *only* this rule SHOULD be recorded in `dependency_blocked` (§4.1.8) so dashboards can
    surface them; the rule itself remains the source of truth for dispatch eligibility.
  - If a running issue gains a non-terminal blocker, stop the active worker without cleaning its
    workspace and release the claim. The issue remains dependency-blocked until the blocker reaches
    a terminal state, then it can be dispatched again by the normal polling loop. Because the
    workspace is preserved (not re-cloned), the paused issue is recorded in `rebase_pending`
    (§4.1.8); when it is re-dispatched, its turn-1 prompt carries a rebase-on-resume directive so the
    agent integrates the now-landed blocker work onto its base before continuing.
  - If that running issue was moved out of the active state set while it was waiting on the blocker
    (for example to `Human Review`), the orchestrator SHOULD move it back to the previous active
    state, falling back to `Todo` when no previous active state is known.

Sorting order (stable intent):

1. `priority` ascending (1..4 are preferred; null/unknown sorts last)
2. `created_at` oldest first
3. `identifier` lexicographic tie-breaker

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

Provider-quota pause gate (OPTIONAL):

- When `agent.<active-provider>.quota.enabled` is set, new dispatch is additionally gated on account
  quota. If the active provider's freshest non-stale snapshot reports any bucket at or above
  `dispatch_pause_percent`, the orchestrator dispatches no new work for that tick and logs the pause.
- The gate is fail-open: a missing, `null`, or stale (`> stale_after_ms`) snapshot never pauses
  dispatch. It applies only to *new* dispatch — running agents, retries, and reconciliation continue.
- Disabled by default, so it never changes dispatch behavior unless an operator opts in. See §5.3.5.3.

### 8.4 Retry and Backoff

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

1. Fetch active candidate issues (not all issues).
2. Find the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise requeue with error `no available orchestrator slots`.
5. If found but no longer active, release claim.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation
  (including terminal transitions for currently running issues).
- Retry handling mainly operates on active candidates and releases claims when the issue is absent,
  rather than performing terminal cleanup itself.

### 8.5 Active Run Reconciliation

Reconciliation runs every tick and has two parts.

Part A: Stall detection

- For each running issue, compute `elapsed_ms` since:
  - `last_agent_timestamp` if any event has been seen, else
  - `started_at`
- If `elapsed_ms` exceeds the active adapter's `stall_timeout_ms` (`agent.codex.stall_timeout_ms`
  or `agent.claude.stall_timeout_ms` per `agent.kind` — see §5.3.5), terminate the worker and
  queue a retry.
- For the Claude adapter, when ≥1 native tool call is in flight (tracked from the
  sidecar's `tool_started`/`tool_finished` hooks), the longer
  `agent.claude.tool_stall_timeout_ms` window applies instead of `stall_timeout_ms`:
  a long native tool (e.g. a build) is silent on the wire and must not be misread
  as a hang. The count resets at each `turn_end`.
- If the resolved `stall_timeout_ms <= 0`, skip stall detection entirely.

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If tracker state is terminal: terminate worker and clean workspace.
  - If tracker state is still active: update the in-memory issue snapshot.
  - If tracker state is neither active nor terminal: terminate worker without workspace cleanup.
- If state refresh fails, keep workers running and try again on the next tick.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for issues in terminal states.
2. For each returned issue identifier, remove the corresponding workspace directory.
3. If the terminal-issues fetch fails, log a warning and continue startup.

This prevents stale terminal workspaces from accumulating after restarts.

### 8.7 Parent Issue Auto-Completion

Parent/umbrella issues are never dispatched (§8.2) — their work lives in their
sub-issues — so nothing in the agent loop advances them. Once every sub-issue is
finished, the parent would otherwise sit open indefinitely. To close that gap,
every poll tick the orchestrator rolls a parent up to `Done` when all of the
following hold:

- The issue is a parent (has sub-issues) returned by the active-state candidate
  poll, so it is currently in an active (non-terminal) state. A parent already
  in a terminal state — including one deliberately `Cancelled` — is never
  touched.
- Its sub-issue set is fully present (the per-parent child fetch is bounded; a
  parent whose returned child list is at the fetch cap is skipped, since the set
  may be truncated) and non-empty.
- *Every* sub-issue is in the `Done` state specifically. A sub-issue in any other
  terminal state (`Cancelled`, `Closed`, …) leaves the parent open.

When satisfied, the orchestrator moves the parent to `Done` via the tracker. The
move drops the parent out of the active-state poll, so the roll-up fires at most
once per parent. Nested umbrellas cascade naturally across ticks: completing a
parent that is itself a sub-issue makes its own parent eligible on a later tick.
A failed tracker update is logged and retried on the next tick.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `workspace.root` (normalized absolute path)

Per-issue workspace path:

- `<workspace.root>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Successful runs do not auto-delete workspaces.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Ensure the workspace path exists as a directory.
4. Mark `created_now=true` only if the directory was created during this call; otherwise
   `created_now=false`.
5. If `created_now=true`, run `after_create` hook if configured.

Notes:

- This section does not assume any specific repository/VCS workflow.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 OPTIONAL Workspace Population (Implementation-Defined)

The spec does not require any built-in VCS or repository bootstrap behavior.

Implementations MAY populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations MAY remove the partially
  prepared directory.
- Reused workspaces SHOULD NOT be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- Hook timeout uses `hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout is logged and ignored.

#### 9.4.1 Non-destructive cutoff (IDE-189)

Distinct from `before_remove` (which fires only on workspace deletion), implementations SHOULD
preserve uncommitted work whenever a session is stopped with a possibly-dirty tree — including stops
that keep the workspace (Backlog/non-active stop, stall restart, dependency pause) and the
`agent.max_turns` cutoff (which restarts a fresh session on the same workspace, so `before_remove`
never runs). The IDE-189 regression was exactly this: an agent was stopped with converging work that
was never committed and was therefore lost on the fresh restart.

- Gated on `agent.preserve_uncommitted_work` (default `true`).
- The snapshot MUST be non-destructive: it MUST NOT move HEAD, switch/modify the current branch, or
  mutate the working tree (no `checkout`/`reset`/`stash`). A `git stash create` is non-conforming
  because it silently drops *untracked* files — the IDE-189 stranded work was a new file.
- A conforming implementation copies the index to a throwaway `GIT_INDEX_FILE`, `git add -A` (so
  modified + staged + untracked files are all captured), `git write-tree`, then `git commit-tree`
  parented on HEAD (omit the parent for a HEAD-less repo), and stores the result under
  `refs/symphony/wip/<sanitized-id>`. When `agent.preserve_uncommitted_work_branch` is true, also
  create a visible `symphony/wip/<id>` branch.
- A clean tree (`git status --porcelain` empty) is a no-op (no empty WIP commit, no ref).
- Preservation is best-effort: failures and timeouts (`agent.cutoff_timeout_ms`) are logged and
  swallowed and MUST NOT block the stop or retry. Logs include `issue_id` + `issue_identifier`.
- Operators recover preserved work with `git log refs/symphony/wip/<ID>` (or
  `git branch --list 'symphony/wip/*'` when the branch option is enabled).

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path MUST stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

## 10. Coding-Agent Adapter Contract

This section defines Symphony's adapter-neutral, language-neutral responsibilities for integrating
a coding agent. Symphony supports more than one coding-agent runtime; the abstract contract here
is implemented by the kind-specific subsections that follow:

- §10.7 Codex App-Server Adapter (`agent.kind == codex`).
- §10.8 Claude Agent SDK Adapter (`agent.kind == claude`).

Both adapters live behind the same orchestrator-facing interface. Each kind-specific subsection MAY
add MUSTs and SHOULDs that supplement the abstract contract, but MUST NOT relax it.

### 10.1 Adapter Selection

- Adapter selection is driven by `agent.kind` (see §5.3.5), defaulting to `codex`.
- Selection is fixed at the moment a session starts; reload of `agent.kind` affects only future
  agent launches and does not migrate in-flight sessions.
- The orchestrator consults the selected adapter's nested config block (`agent.codex.*` or
  `agent.claude.*`) for launch command, timeouts, approval/sandbox/permission posture, and any
  adapter-specific knobs.

### 10.2 Common Adapter Responsibilities

Every conforming adapter MUST:

- Launch its subprocess (or equivalent runtime) with the per-issue workspace path as the working
  directory.
- Expose a long-lived, turn-driven session to the orchestrator. The first turn carries the
  rendered WORKFLOW.md prompt (see Section 12); continuation turns carry continuation guidance,
  not a re-render of the original issue prompt.
- Surface a `session_id` to Symphony as soon as it is known and reuse it across continuation turns
  inside the same worker run.
- Emit the standard event vocabulary defined in §10.3 to Symphony's orchestrator callback.
- Honor the adapter-specific `read_timeout_ms`, `turn_timeout_ms`, and `stall_timeout_ms` values
  resolved through `agent.<kind>.*`.
- Handle continuation turns on the same live session: the underlying subprocess SHOULD remain
  alive across continuation turns and be stopped only when the worker run is ending.
- Stop the session cleanly when the orchestrator terminates the run.

RECOMMENDED additional process settings:

- Max line size for stdio-framed transports: 10 MB (for safe buffering).

### 10.3 Standard Emitted Events

Each adapter emits structured events to the orchestrator callback. Each event SHOULD include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `agent_kind` (string enum, mirrors `agent.kind` for the active session)
- `agent_pid` (if available)
- `session_id` (if known)
- OPTIONAL `usage` map (token counts)
- payload fields as needed

Important emitted events include, for example:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

The vocabulary is shared across adapters; an adapter that does not have a native concept for a
given event (for example a runtime without rate-limit signals) SHOULD simply not emit it.

### 10.4 Approval, Sandbox, and User-Input Policy

Approval, sandbox, and user-input behavior is implementation-defined per adapter.

Policy requirements:

- Each adapter MUST document its chosen approval, sandbox, and operator-confirmation posture.
- Approval requests and user-input-required events MUST NOT leave a run stalled indefinitely.
  An adapter MAY satisfy them, surface them to an operator, auto-resolve them, or fail the run
  according to its documented policy.

Example high-trust behavior (applies to either adapter):

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the adapter
  SHOULD be handled according to their extension contract.
- If the agent requests a dynamic tool call that is not supported, the adapter MUST return a tool
  failure response and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extension:

- An adapter MAY expose a limited set of client-side tools to its session.
- Current standardized optional tool: `linear_graphql`.
- If implemented, supported tools SHOULD be advertised to the session during startup using the
  mechanism the adapter exposes (Codex app-server tool advertisement; Claude Agent SDK in-process
  MCP `@tool`/`tool()` registration). The contract below is adapter-agnostic.
- Unsupported tool names SHOULD still return a failure result and continue the session.

`linear_graphql` extension contract (adapter-agnostic):

- Purpose: execute a raw GraphQL query or mutation against Linear using Symphony's configured
  tracker auth for the current session.
- Availability: only meaningful when `tracker.kind == "linear"` and valid Linear auth is
  configured.
- Preferred input shape:

  ```json
  {
    "query": "single GraphQL query or mutation document",
    "variables": {
      "optional": "graphql variables object"
    }
  }
  ```

- `query` MUST be a non-empty string.
- `query` MUST contain exactly one GraphQL operation.
- `variables` is OPTIONAL and, when present, MUST be a JSON object.
- Implementations MAY additionally accept a raw GraphQL query string as shorthand input.
- Execute one GraphQL operation per tool call.
- If the provided document contains multiple operations, reject the tool call as invalid input.
- `operationName` selection is intentionally out of scope for this extension.
- Reuse the configured Linear endpoint and auth from the active Symphony workflow/runtime config;
  do not require the coding agent to read raw tokens from disk.
- Tool result semantics:
  - transport success + no top-level GraphQL `errors` -> `success=true`
  - top-level GraphQL `errors` present -> `success=false`, but preserve the GraphQL response body
    for debugging
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the GraphQL response or error payload as structured tool output that the model can
  inspect in-session.
- Implementations MAY attach a corrective `hint` (in the error payload) or `symphony_hint` (in a
  200-body carrying `errors`) for known, recurring mistake classes, alongside — never replacing —
  the verbatim `errors[]`. The tool MUST NOT rewrite the agent's call. (Reference implementation:
  the `IssueRelationType` enum has only `blocks`; `blocked_by` is rejected at variable coercion, so
  the hint explains that direction is encoded by operand order and the agent must swap
  `issueId`/`relatedIssueId` rather than change the type value.)

User-input-required policy:

- Each adapter MUST document how user-input-required signals are handled.
- A run MUST NOT stall indefinitely waiting for user input.
- A conforming adapter MAY fail the run, surface the request to an operator, satisfy it through
  an approved operator channel, or auto-resolve it according to its documented policy.
- The example high-trust behavior above fails user-input-required turns immediately.

### 10.5 Timeouts and Error Mapping

Timeouts (resolved per adapter from `agent.<kind>.*`):

- `read_timeout_ms`: request/response timeout during startup and sync requests
- `turn_timeout_ms`: total turn stream timeout
- `stall_timeout_ms`: enforced by orchestrator based on event inactivity

Error mapping (RECOMMENDED normalized categories):

Common (any adapter):

- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

Codex-adapter specific (when `agent.kind == codex`):

- `codex_not_found`
- `port_exit`

Claude-adapter specific (when `agent.kind == claude`):

- `claude_sidecar_not_found`
- `claude_sdk_error`
- `permission_denied`

### 10.6 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + selected adapter.

Behavior:

1. Create/reuse workspace for issue.
2. Build prompt from workflow template.
3. Start the selected adapter's session (Codex app-server or Claude SDK sidecar).
4. Forward adapter events to orchestrator.
5. On any error, fail the worker attempt (the orchestrator will retry).

Note:

- Workspaces are intentionally preserved after successful runs.

### 10.7 Codex App-Server Adapter (Implementation)

Selected when `agent.kind == codex` (the default).

Protocol source of truth:

- The Codex app-server protocol for the targeted Codex version is the source of truth for
  protocol schemas, message payloads, transport framing, and method names.
- Implementations MUST send messages that are valid for the targeted Codex app-server version.
- Implementations MUST consult the targeted Codex app-server documentation or generated schema
  rather than treating this specification as a protocol schema.
- If this specification appears to conflict with the targeted Codex app-server protocol, the Codex
  protocol controls protocol shape and transport behavior. Symphony-specific requirements still
  control orchestration behavior, workspace selection, prompt construction, continuation
  handling, and observability extraction.

Reference: https://developers.openai.com/codex/app-server/

Launch contract:

- Command: `agent.codex.command` (default `codex app-server`).
- Invocation: `bash -lc <agent.codex.command>` in the per-issue workspace.
- Transport/framing: the protocol transport required by the targeted Codex app-server version.
- Approval policy, sandbox policy, cwd, prompt input, and OPTIONAL tool declarations are supplied
  using fields supported by the targeted Codex app-server version.

Session startup obligations (in addition to §10.2):

- Start the app-server subprocess in the per-issue workspace.
- Initialize the app-server session using the targeted Codex app-server protocol.
- Create or resume a coding-agent thread according to the targeted protocol.
- Supply the absolute per-issue workspace path as the thread/turn working directory wherever the
  targeted protocol accepts cwd.
- Supply the implementation's documented approval and sandbox policy using fields supported by
  the targeted protocol.
- Include issue-identifying metadata, such as `<issue.identifier>: <issue.title>`, when the
  targeted protocol supports turn or session titles.
- Advertise implemented client-side tools using the targeted protocol.

Session identifiers:

- Extract `thread_id` from the thread identity returned by the targeted Codex app-server protocol.
- Extract `turn_id` from each turn identity returned by the targeted Codex app-server protocol.
- Compose `session_id = "<thread_id>-<turn_id>"`.
- Reuse the same `thread_id` for all continuation turns inside one worker run.

Streaming turn processing:

- Process app-server updates according to the targeted Codex app-server protocol until the active
  turn terminates.
- Completion conditions:
  - Targeted-protocol turn completion signal -> success
  - Targeted-protocol turn failure signal -> failure
  - Targeted-protocol turn cancellation signal -> failure
  - Turn timeout (`agent.codex.turn_timeout_ms`) -> failure
  - Subprocess exit -> failure
- Follow the transport and framing rules of the targeted Codex app-server version.
- For stdio-based transports, keep protocol stream handling separate from diagnostic stderr
  handling unless the targeted protocol specifies otherwise.

Approval/sandbox: use the Codex `AskForApproval` / `SandboxMode` / `SandboxPolicy` values resolved
from `agent.codex.approval_policy` / `agent.codex.thread_sandbox` / `agent.codex.turn_sandbox_policy`.
The §15.2 workspace-cwd safety invariants MUST hold.

Tool advertisement: when implemented, `linear_graphql` is advertised through the Codex app-server
tool mechanism for the targeted version.

### 10.8 Claude Agent SDK Adapter (Implementation)

Selected when `agent.kind == claude`.

Protocol source of truth:

- The Claude Agent SDK and its underlying `claude` CLI are the source of truth for protocol
  behavior. The SDK API is semver-versioned; the underlying `--input-format=stream-json` wire
  protocol is intentionally not specified by Anthropic for third-party use
  ([anthropics/claude-code#24594](https://github.com/anthropics/claude-code/issues/24594)).
- Implementations MUST consume the SDK rather than hand-rolling the wire protocol.
- The Symphony adapter is implemented as a long-lived subprocess (the "sidecar") that hosts the
  SDK and bridges Symphony's orchestrator to the SDK over a JSON-line stdio protocol.

Launch contract:

- Command: `agent.claude.command` (default
  `jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent`;
  `SYMPHONY_CLAUDE_PRIV_DIR` is injected by the implementation and resolves to the
  `<priv-claude-agent>` directory).
- Invocation: `bash -lc <agent.claude.command>` in the per-issue workspace.
- Required environment: `ANTHROPIC_API_KEY` (or the equivalent provider auth env var when routing
  through Bedrock/Vertex/Foundry — see §5.3.5.2).
- Forwarded environment: `agent.claude.extra_env` plus the standard provider env vars
  (`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `ANTHROPIC_AUTH_TOKEN`, etc.) when
  present in the host environment.
- Implementation-injected environment:
  - `SYMPHONY_CLAUDE_PRIV_DIR` always points at the `<priv-claude-agent>` directory so
    `agent.claude.command` can be portable across hosts (see default above).
  - `CLAUDE_CONFIG_DIR` is set to `agent.claude.config_dir` (path-expanded) when that field
    is non-empty, so the sidecar's `claude` CLI scopes its OAuth lookup to that subscription.
  - Both are `Map.put_new`-style: `extra_env` entries with the same key win.

Sidecar wire protocol (Symphony ↔ sidecar over stdio, line-delimited JSON):

- Symphony → sidecar: `init`, `turn`, `tool_result`, `permission_response`, `interrupt`,
  `shutdown`.
- Sidecar → Symphony: `ready`, `system_init`, `assistant_message` (and/or deltas), `tool_call`,
  `tool_started`, `tool_finished`, `permission_request`, `token_usage`, `turn_end`, `error`, `log`.
- `tool_started`/`tool_finished` are native-tool lifecycle notifications (from the SDK's
  PreToolUse/PostToolUse hooks) that let the orchestrator apply the longer
  `agent.claude.tool_stall_timeout_ms` window while a tool runs (see §5.3.5 stall detection).
- The concrete envelope shape is implementation-defined within the MUSTs above; implementations
  MUST document and version their envelope.

Session startup:

- The sidecar MUST construct a `ClaudeSDKClient` (Python; or the TypeScript SDK equivalent)
  with `ClaudeAgentOptions` carrying at minimum:
  - `cwd` set to the per-issue workspace path.
  - `system_prompt` selected by `agent.claude.system_prompt_preset` (default `claude_code` preset
    with the rendered WORKFLOW.md body appended).
  - `permission_mode` from `agent.claude.permission_mode`.
  - `model` from `agent.claude.model`.
  - `allowed_tools` and `disallowed_tools` from the corresponding config keys.
  - `setting_sources` from `agent.claude.setting_sources` when set; when unset (the default)
    the option is OMITTED so the SDK loads its default sources (CLI parity: inherit the repo's
    `.claude/settings.json`, project `.mcp.json` servers, and `CLAUDE.md`). `[]` opts back into
    isolation.
  - `max_turns` from `agent.claude.max_turns` when set.
  - `effort` from `agent.claude.effort` when set.
  - `mcp_servers` containing an in-process MCP server constructed via
    `create_sdk_mcp_server(name, version, tools=[...])` that registers Symphony's advertised
    tools (notably `linear_graphql`, when implemented) using the SDK's `@tool` decorator. Tools
    registered this way are addressed as `mcp__<server_name>__<tool_name>` and MUST appear in
    `allowed_tools` when `permission_mode == "dontAsk"`.
  - `hooks` map registering at least a `PreToolUse` hook that validates tool inputs against the
    workspace boundary (rejecting filesystem-mutating tool inputs whose realpath escapes the
    workspace); this is the load-bearing sandbox check in `dontAsk` mode.

Session identifiers:

- `session_id` is the SDK-assigned UUID delivered in the first `SystemMessage` whose
  `subtype == "init"`. In Python, the value is read from `message.data["session_id"]`; in
  TypeScript, from `message.session_id`.
- Continuation turns reuse the same `ClaudeSDKClient` instance and therefore the same session.
  Cross-process resumption (sidecar restart) MAY use the SDK's `resume=<session_id>` option
  against the on-disk session file under `~/.claude/projects/<encoded-cwd>/` — implementations
  MUST document whether they support cross-restart resumption.

Turn processing:

- Each turn is initiated by Symphony writing a `turn` request.
- The sidecar drives `client.query(prompt)` and then iterates `client.receive_response()` until
  a `ResultMessage`, at which point it emits `turn_end` carrying `stop_reason`, `num_turns`, and
  `usage`. The `usage` payload uses snake_case keys: `input_tokens`, `output_tokens`,
  `cache_creation_input_tokens`, `cache_read_input_tokens`.
- For each `AssistantMessage` whose underlying message carries a non-`None` `usage` field
  (claude-agent-sdk ≥0.1.49 — *"Preserve per-turn `usage` on `AssistantMessage`"*), the sidecar
  SHOULD also emit a separate `token_usage` envelope carrying that API call's billing
  (`session_id` + four-field `usage` payload, same snake_case shape as `turn_end.usage`). This is
  the live mid-turn signal; the SDK does not expose Anthropic's raw `message_start` /
  `message_delta` SSE events. Suppress the envelope when `usage` is `None` to avoid claiming a
  billing event that didn't happen.
- Implementations that consume both `token_usage` and `turn_end.usage` MUST reconcile rather than
  sum. Per-turn semantics: per-message `token_usage` is provisional; `ResultMessage.usage` from
  `turn_end` is authoritative for the turn rollup. The recommended reconciliation is to track a
  per-running-entry "turn-provisional" accumulator that is bumped on each `token_usage` and reset
  on `turn_end`; on `turn_end`, apply `correction = max(0, turn_end.usage - turn_provisional)` to
  the cumulative totals so they end at the authoritative value without ever moving backwards. If
  no `token_usage` envelopes arrived for a turn (legacy sidecar / error path), `turn_provisional`
  stays at 0 and the correction equals the full rollup, matching the pre-`token_usage` behaviour.
- The sidecar subprocess remains alive across continuation turns.
- Symphony's `interrupt` request MUST be implemented as `await client.interrupt()` on the live
  `ClaudeSDKClient`; it is an async method, not a wire-level signal sent into the subprocess.

Approval / sandbox mapping:

- The Claude Agent SDK has no native filesystem/network sandbox primitive. Two unattended postures
  are supported; the containment boundary differs, but the Elixir-side workspace-cwd invariant from
  §15.2 MUST hold under both.

  Posture A — **allow-all behind an outer sandbox** (the shipped default for generated instances and
  the maintainer `WORKFLOW.md`, because they run under the `jai` launcher):
  1. `permission_mode = bypassPermissions` — every tool runs without prompts; `allowed_tools` is
     ignored.
  2. Containment is delegated entirely to external isolation: the `jai` COW-overlay sandbox
     (or an equivalent container/VM) plus the workspace-cwd invariant. There is no in-SDK tool
     gate in this mode, so the outer sandbox is load-bearing and MUST be present.
  3. `bypassPermissions` MUST NOT be selected together with a `can_use_tool` policy callback — the
     SDK skips `can_use_tool` in that mode, silently disabling enforcement.

  Posture B — **in-SDK whitelist, no outer sandbox required** (the schema default when
  `permission_mode` is omitted, and the recommended posture for deployments without an outer
  sandbox):
  1. `permission_mode = dontAsk` — anything not pre-approved is denied (no human prompts). An
     empty/absent `allowed_tools` under `dontAsk` denies every tool and is rejected at boot
     (`Config.validate!`).
  2. A tightly scoped `allowed_tools` whitelist that contains only the tools the workflow needs
     (e.g. `Read`, `Glob`, `Edit`, `Write`, plus any explicitly registered
     `mcp__<server>__<tool>` entries). Avoid blanket-allowing `Bash` unless the workflow
     genuinely needs shell execution.
  3. `disallowed_tools` for explicit denials of dangerous tools (e.g. `WebFetch`).
  4. A `PreToolUse` hook that validates tool input paths against the workspace `cwd` via
     realpath comparison (the SDK's built-in `cwd` check is helpful but a defence-in-depth
     hook MUST be present).
- The deployment-time hardening guidance in §15.5 applies in addition to the in-SDK controls
  above.

Tool advertisement:

- `linear_graphql` (when implemented) is registered as an in-process SDK tool through
  `create_sdk_mcp_server` + `@tool`, not as a separate stdio MCP shim; the SDK's tool-call
  control protocol delivers invocations to the sidecar, which forwards them to Symphony as
  `tool_call` events. The tool MUST appear in `agent.claude.allowed_tools` (under its
  `mcp__<server>__linear_graphql` SDK name) for `dontAsk` mode to permit invocation.
- Custom tool errors SHOULD be returned as `is_error=True` tool responses so the agent loop
  continues and Claude can recover, rather than raising exceptions that tear down the session.

Timeouts:

- `agent.claude.read_timeout_ms`, `agent.claude.turn_timeout_ms`, and
  `agent.claude.stall_timeout_ms` mirror the Codex semantics described in §10.5.

Logging verbosity:

- `agent.claude.verbose_logging` (boolean, default `false`) is the single knob that gates
  Claude's debug feed across both the orchestrator and the sidecar. When `false`:
  - The sidecar MUST omit `include_partial_messages` and `include_hook_events` from
    `ClaudeAgentOptions` so the SDK does not surface partial-stream/hook events.
  - The sidecar MUST NOT forward the underlying `claude` CLI's stderr to Symphony as
    `log` envelopes (the SDK launches the CLI with `--verbose` unconditionally, so the
    forwarder is the only path through which that stderr would otherwise reach the
    orchestrator).
  - The orchestrator MUST suppress per-envelope `tool_call`/`assistant_message`/
    `turn_completed`/`permission_request`/`system_init`/`log` log lines. Per-issue
    and per-session lifecycle logging (e.g. session start/completion/error) stays at
    `info` regardless.
- When `true`, all three streams are restored — the recommended posture when debugging
  adapter or sidecar issues.

## 11. Issue Tracker Integration Contract (Linear-Compatible)

### 11.1 REQUIRED Operations

An implementation MUST support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return issues in configured active states for a configured project.

2. `fetch_issues_by_states(state_names)`
   - Used for startup terminal cleanup.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Used for active-run reconciliation.

### 11.2 Query Semantics (Linear)

Linear-specific requirements for `tracker.kind == "linear"`:

- `tracker.kind == "linear"`
- GraphQL endpoint (default `https://api.linear.app/graphql`)
- Auth token sent in `Authorization` header
- `tracker.project_slug` maps to Linear project `slugId`
- Candidate issue query filters project using `project: { slugId: { eq: $projectSlug } }`
- Issue-state refresh query uses GraphQL issue IDs with variable type `[ID!]`
- Pagination REQUIRED for candidate issues
- Page size default: `50`
- Network timeout: `30000 ms`

Important:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types REQUIRED by this specification.

A non-Linear implementation MAY change transport details, but the normalized outputs MUST match the
domain model in Section 4.

### 11.3 Normalization Rules

Candidate issue normalization SHOULD produce fields listed in Section 4.1.1.

Additional normalization details:

- `labels` -> lowercase strings
- `blocked_by` -> derived from inverse relations where relation type is `blocks`
- `has_children` -> true when the issue's `children` connection has at least one node
- `parent_id` -> `parent.id` from the tracker payload (null when the issue has no parent)
- `parent` -> the `parent` connection normalized as an issue, carrying its own `children`
  (the issue's siblings); each child is normalized with `parent_id` backfilled. Selected inline by
  the poll query (`children` for an issue's own sub-issues, `parent { ... children }` for a child's
  container + siblings), bounded per parent by a child-page cap so nested connections stay within the
  tracker's query-complexity budget
- `children` -> sub-issues normalized from the `children` connection; entries without an `identifier`
  are dropped
- `priority` -> integer only (non-integers become null)
- `state` -> `state.name` from the tracker payload (operator-facing label, may be customized)
- `state_type` -> `state.type` from the tracker payload (stable workflow-state bucket; see §4.1.1)
- `created_at` and `updated_at` -> parse ISO-8601 timestamps

### 11.4 Error Handling Contract

RECOMMENDED error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_tracker_project_slug`
- `linear_api_request` (transport failures)
- `linear_api_status` (non-200 HTTP)
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.

### 11.5 Tracker Writes (Important Boundary)

Symphony does not require first-class tracker write APIs in the orchestrator.

- Ticket mutations (state transitions, comments, PR metadata) are typically handled by the coding
  agent using tools defined by the workflow prompt.
- The service remains a scheduler/runner and tracker reader.
- Workflow-specific success often means "reached the next handoff state" (for example
  `Human Review`) rather than tracker terminal state `Done`.
- If the `linear_graphql` client-side tool extension is implemented, it is still part of the agent
  toolchain rather than orchestrator business logic.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to prompt rendering:

- `workflow.prompt_template`
- normalized `issue` object
- OPTIONAL `attempt` integer (retry/continuation metadata)

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers) so templates can iterate.

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD be passed to the template because the workflow prompt can provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

REQUIRED context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

REQUIRED context for coding-agent session lifecycle logs:

- `session_id`
- `agent_kind` (`codex | claude`)

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs are written (stderr, file, remote sink, etc.).

Requirements:

- Operators MUST be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations MAY write to one or more sinks.
- If a configured log sink fails, the service SHOULD continue running when possible and emit an
  operator-visible warning through any remaining sink.

### 13.3 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
SHOULD return:

- `running` (list of running session rows)
- each running row SHOULD include `turn_count` and `agent_kind`
- `retrying` (list of retry queue rows)
- `agent_totals`
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available; MAY be `null` when the
  active adapter does not surface rate-limit data — the Claude adapter does not surface them today)
- `provider_quotas` (per-provider normalized account-quota snapshots, keyed `codex`/`claude`; see
  §4.1.8 and §5.3.5.3. MAY be `null`/empty when no snapshot has been collected.)

RECOMMENDED snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 OPTIONAL Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is OPTIONAL and
implementation-defined.

If present, it SHOULD draw from orchestrator state/metrics only and MUST NOT be REQUIRED for
correctness.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Coding-agent events can include token counts in multiple payload shapes; rules below apply to
  any conforming adapter (see §10).
- For the Codex adapter, prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- For the Claude adapter, the canonical totals come from the `ResultMessage.usage` payload at the
  end of each turn (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`). The orchestrator MUST sum these across turns rather than treating
  any single turn's usage as cumulative.
- For the Claude adapter, `total_tokens = input_tokens + output_tokens` for codex parity (the
  `total_tokens` field reflects billable prompt+completion tokens). The two cache fields
  (`cache_creation_input_tokens`, `cache_read_input_tokens`) are claude-specific and exposed as
  siblings of `total_tokens` in storage, JSON, and humanized output — never folded into
  `total_tokens` (cache_read often dwarfs the prompt+completion total).
- The Claude `usage` map is already a per-turn delta (no cumulative→delta diffing needed); just
  sum directly across turns.
- When an implementation presents a unified status panel across adapter kinds (for example a single
  "Tokens" line in a terminal dashboard), it SHOULD sum the per-adapter aggregates
  (`agent_totals` + `claude_totals`) since each adapter accounts for its own disjoint sessions.
  Per-running-row token columns SHOULD branch on `agent_kind` and read the matching adapter's
  cumulative field; mixing the two on a single row would conflate distinct accounting domains.
- Ignore delta-style payloads such as `last_token_usage` (Codex) for dashboard/API totals.
- Extract input/output/total token counts leniently from common field names within the selected
  payload.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state (`agent_totals`).

Runtime accounting:

- Runtime SHOULD be reported as a live aggregate at snapshot/render time.
- Implementations MAY maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not REQUIRED.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Humanized Agent Event Summaries (OPTIONAL)

Humanized summaries of raw agent protocol events are OPTIONAL.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.7 OPTIONAL HTTP Server Extension

This section defines an OPTIONAL HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not REQUIRED for conformance.
- The implementation MAY serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API MUST be observability/control surfaces only and MUST NOT become REQUIRED for
  orchestrator correctness.

Extension config:

- `server.port` (integer, OPTIONAL)
  - Enables the HTTP server extension.
  - `0` requests an ephemeral port for local development and tests.
  - CLI `--port` overrides `server.port` when both are present.

Enablement (extension):

- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `server.port` is present in `WORKFLOW.md` front matter.
- The `server` top-level key is owned by this extension.
- Positive `server.port` values bind that port.
- Implementations SHOULD bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `server.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.7.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document SHOULD depict the current state of the system (for example active sessions,
  retry delays, token consumption, runtime totals, recent events, a dependency graph of active
  candidates and their transitive blockers, and health/error indicators).
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.

#### 13.7.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, retry queue/delays,
    aggregate token/runtime totals, latest rate limits, and any additional tracked summary fields).
  - Top-level `linear_project` mirrors `tracker.project_slug` — the tracker project the runtime is
    attached to — so dashboards and API consumers can label which project the runtime serves
    (`null` for non-Linear trackers without a configured slug).
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "linear_project": "my-project",
      "counts": {
        "running": 2,
        "retrying": 1,
        "blocked": 0,
        "dependency_blocked": 1
      },
      "running": [
        {
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "agent_kind": "claude",
          "state": "In Progress",
          "session_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "output_tokens": 800,
            "total_tokens": 2000,
            "cache_creation_input_tokens": 320,
            "cache_read_input_tokens": 5400
          }
        }
      ],
      "retrying": [
        {
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "no available orchestrator slots"
        }
      ],
      "dependency_blocked": [
        {
          "issue_id": "ghi789",
          "issue_identifier": "MT-651",
          "title": "Wire up the audit log",
          "state": "Todo",
          "blocked_by": [
            {"issue_id": "abc123", "issue_identifier": "MT-649", "state": "In Progress"}
          ],
          "observed_at": "2026-02-24T20:11:42Z"
        }
      ],
      "dependency_graph": {
        "nodes": [
          {
            "id": "ghi789",
            "issue_identifier": "MT-651",
            "title": "Wire up the audit log",
            "state": "Todo",
            "state_type": "unstarted",
            "priority": 3,
            "priority_label": "Medium",
            "url": "https://linear.app/example/issue/MT-651",
            "placeholder": false,
            "symphony_status": "waiting_on_blockers",
            "symphony_status_label": "Waiting on blockers",
            "session_id": null,
            "workspace_path": null,
            "inactive_reason": "Waiting on 1 blocker(s)",
            "kind": "issue",
            "parent": "umb001",
            "managed": true,
            "requirements": [],
            "child_total": null,
            "child_done": null
          },
          {
            "id": "abc123",
            "issue_identifier": "MT-649",
            "title": "Surface session metadata",
            "state": "In Progress",
            "state_type": "started",
            "priority": 2,
            "priority_label": "High",
            "url": "https://linear.app/example/issue/MT-649",
            "placeholder": false,
            "symphony_status": "running",
            "symphony_status_label": "Running",
            "session_id": "0199c2f4-thread-turn",
            "workspace_path": "/srv/symphony/workspaces/MT-649",
            "inactive_reason": null,
            "kind": "issue",
            "parent": "umb001",
            "managed": true,
            "requirements": [],
            "child_total": null,
            "child_done": null
          },
          {
            "id": "umb001",
            "issue_identifier": "MT-600",
            "title": "Observability epic",
            "state": "In Progress",
            "state_type": "started",
            "priority": null,
            "priority_label": "No priority",
            "url": "https://linear.app/example/issue/MT-600",
            "placeholder": false,
            "symphony_status": null,
            "symphony_status_label": null,
            "session_id": null,
            "workspace_path": null,
            "inactive_reason": "1/3 sub-issues done",
            "kind": "container",
            "parent": null,
            "managed": true,
            "requirements": [],
            "child_total": 3,
            "child_done": 1
          },
          {
            "id": "jkl012",
            "issue_identifier": "MT-652",
            "title": "Backfill historical metrics",
            "state": "Backlog",
            "state_type": "backlog",
            "priority": 4,
            "priority_label": "Low",
            "url": "https://linear.app/example/issue/MT-652",
            "placeholder": false,
            "symphony_status": null,
            "symphony_status_label": null,
            "session_id": null,
            "workspace_path": null,
            "inactive_reason": "Needs: move to an active state (Todo, In Progress)",
            "kind": "issue",
            "parent": "umb001",
            "managed": false,
            "requirements": ["move to an active state (Todo, In Progress)"],
            "child_total": null,
            "child_done": null
          }
        ],
        "edges": [
          {"source": "abc123", "target": "ghi789", "kind": "blocks"}
        ]
      },
      "agent_totals": {
        "input_tokens": 5000,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "rate_limits": null,
      "provider_quotas": { "codex": null, "claude": null }
    }
    ```

    For `agent_kind == claude` running entries, the `tokens` map carries the Anthropic-specific
    `cache_creation_input_tokens` and `cache_read_input_tokens` siblings shown above. `total_tokens`
    on a claude entry is `input_tokens + output_tokens` (codex parity); cache fields are never
    folded into `total_tokens`. Codex entries omit the cache fields. Implementations MAY also expose
    a top-level `claude_totals` block (parallel to a codex-shaped `agent_totals`) carrying the same
    six-field aggregate so dashboards can render both shapes without re-deriving from running
    entries.

- `GET /api/v1/<issue_identifier>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - Suggested response shape:

    ```json
    {
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/symphony_workspaces/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "agent_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/symphony/agent/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    MAY coalesce repeated requests).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

API design notes:

- The JSON shapes above are the RECOMMENDED baseline for interoperability and debugging ergonomics.
- Implementations MAY add fields, but SHOULD avoid breaking existing fields within a version.
- Endpoints SHOULD be read-only except for operational triggers like `/refresh`.
- Unsupported methods on defined routes SHOULD return `405 Method Not Allowed`.
- API errors SHOULD use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it SHOULD consume this API rather than duplicating state
  logic.

### 13.5 Deterministic Per-Turn Progress Signals (IDE-189, Layer 1)

Layer 1 of the agent-run robustness defense (alongside the Layer-0 budget cutoff in §6/§9.4 and
the Layer-2 AI overseer). At each **turn boundary** — the `:turn_completed` envelope for the
claude adapter, a new-`session_id` `:session_started` envelope for codex — the orchestrator runs a
single cheap, non-mutating git probe and rolls forward per-issue progress signals. Gated on
`agent.progress_signal_enabled`; bounded by `agent.progress_signal_git_timeout_ms` so a
slow/locked repo degrades to "assessment unchanged" rather than stalling the orchestration loop.
The probe runs in the orchestrator process *after* the turn completes — off the agent's critical
path.

Per turn the probe observes three raw inputs:

- **working-tree hash** — a content hash of the full tree (tracked **and** untracked, via
  `git write-tree` on a throwaway index so HEAD/index/working tree are untouched). Identical hash
  across turns ⇔ the agent changed nothing.
- **empty** — whether `git status --porcelain` is empty (clean tree).
- **commits_since** — commits on `HEAD` since a dispatch marker captured lazily on the first probe.

plus an optional adapter-tagged terminal-error signature (or `nil` when the turn ended cleanly).

From the rolling streaks the orchestrator derives a **status** (most→least severe) and an
**independent** boolean, where `K = agent.progress_signal_window_k`:

```
:oscillating     last 4 hashes are A,B,A,B with A != B
:repeated_error  error_sig != nil AND its streak >= K
:stuck_state     identical hash for >= K turns AND the tree is empty   ← empty-tree guard
:progressing     otherwise

at_risk_no_commits = commits_since == 0 AND turn_count >= K
```

The **empty-tree guard** is load-bearing: an issue holding a *dirty* tree (real pending work) for
many turns without committing is `:progressing` + `at_risk_no_commits`, **never** `:stuck`.
`at_risk_no_commits` is therefore a parallel flag that coexists with `:progressing`; it is not a
status value.

**Non-enforcement contract.** Layer 1 only *reports*: the status and flag are logged (§13 logging
conventions: `issue_id` + `issue_identifier` + `session_id`, `key=value`, deterministic wording)
and exposed verbatim through the orchestrator snapshot (dashboard + `/api/v1/*`). Layer 1 takes no
action — no session kill, no Linear state move, no continuation gating; those belong to Layers 0/2.
The trigger predicate Layer 2 consumes is:

```
status in [:stuck_state, :oscillating, :repeated_error]
OR (at_risk_no_commits AND turn_count >= agent.progress_trigger_min_turns)
```

### 13.6 AI Overseer (IDE-212, Layer 2)

Layer 2 of the agent-run robustness defense (alongside the Layer-0 budget cutoff in §6/§9.4 and the
Layer-1 progress signals in §13.5). Where Layer 1 only *reports* deterministic git signals, Layer 2
is a gated, **read-only** AI overseer that *semantically* classifies a near-budget run and
recommends one action. It is **disabled by default** (`agent.overseer.enabled`), runs at most a
couple of times per run (never per turn), and **never changes the turn budget**. Every error path
is **fail-open**: a transport / parse / timeout failure leaves the run exactly as Layer 1 left it.

**Engine.** The implemented engine (`agent.overseer.engine: "api"`) is a single read-only call to
the Anthropic Messages API. Read-only by construction: the only tool offered is `emit_verdict`,
whose `input_schema` *is* the verdict contract, and `tool_choice` forces the model to call it — the
model cannot read files, run commands, or touch the workspace. (`"sidecar"` is reserved for
forward-compat and currently fails open / treated as disabled.)

**Trigger (gating).** Evaluated at a turn boundary in the worker. The budget-threshold arm fires
when `turn >= agent.max_turns - agent.overseer.budget_threshold_k`, gated by a cooldown
(`agent.overseer.min_turns_between`) and a per-run cap (`agent.overseer.max_calls_per_session`) so
it does not re-fire every turn from K down to 0. (The Layer-1 signal arm in §13.5 is a planned
second trigger; it needs an orchestrator→worker signal channel that does not exist yet, so only the
budget-threshold arm is wired today.)

**Evidence (read-only).** A bounded bundle: issue title/description, the turn/budget counters, the
`git diff HEAD` summary (single non-mutating probe, byte-capped), tails of build/test logs matching
`agent.overseer.log_globs`, and a bounded window (`agent.overseer.transcript_window`) of the
**normalized** transcript envelopes (`%{event:, payload:}`) both adapters emit — the
adapter-agnostic consumption point the parity contract relies on.

**Verdict → action.** The structured verdict is `verdict` (converging / thrashing / blocked),
`confidence` (0..1), `recommended_action`, `steering_message` (non-null **iff** the action is
`nudge`), and `rationale`. The worker maps it to a concrete action, enforcing:

- `confidence < agent.overseer.confidence_floor` ⇒ downgrade to a comment-only `continue` (never
  steers or escalates on a low-confidence verdict);
- `continue` — no-op (healthy run proceeds untouched);
- `nudge` — the `steering_message` rides the *next* turn's prompt as an explicit directive, plus one
  Linear comment; if the steering is missing/empty it downgrades to `continue`;
- `recommend_extend_budget` — one Linear comment + log only; **never** changes `agent.max_turns`;
- `escalate` — routed through the existing deterministic-failure escalation pipeline (§13.x /
  IDE-73) via the `:overseer_escalation` error code, moving the issue to
  `agent.deterministic_failure_escalation_state`;
- `abort` — treated as `escalate` unless `agent.overseer.allow_abort` is true (never autonomously
  kills a borderline session by default).

Config lives under `agent.overseer.*` (§5.3.5); `agent.overseer.api_key` resolves from
`$ANTHROPIC_API_KEY` (mirroring `tracker.api_key`/`$LINEAR_API_KEY`), and an absent key disables the
overseer regardless of the `enabled` flag.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `WORKFLOW.md`
   - Invalid YAML front matter
   - Unsupported tracker kind or missing tracker credentials/project slug
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; can come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested and handled as failure by the implementation's documented policy
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Current design is intentionally in-memory for scheduler state.
Restart recovery means the service can resume useful operation by polling tracker state and reusing
preserved workspaces. It does not mean retry timers, running sessions, or live worker state survive
process restart.

After restart:

- No retry timers are restored from prior process memory.
- No running sessions are assumed recoverable.
- Service recovers by:
  - startup terminal workspace cleanup
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing `WORKFLOW.md` (prompt and most runtime settings).
- `WORKFLOW.md` changes are detected and re-applied automatically without restart according to
  Section 6.2.
- Changing issue states in the tracker:
  - terminal state -> running session is stopped and workspace cleaned when reconciled
  - non-active state -> running session is stopped without cleanup
- Restarting the service for process recovery or deployment (not as the normal path for applying
  workflow config changes).

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations SHOULD state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations SHOULD state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path MUST remain under configured workspace root.
- Coding-agent cwd MUST be the per-issue workspace path for the current run.
- Workspace directory names MUST use sanitized identifiers.

RECOMMENDED additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in workflow config.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from `WORKFLOW.md`.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output SHOULD be truncated in logs.
- Hook timeouts are REQUIRED to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running coding-agent sessions against repositories, issue trackers, and other inputs that can
contain sensitive data or externally-controlled content can be dangerous. A permissive deployment
can lead to data leaks, destructive mutations, or full machine compromise if the agent is induced
to execute harmful commands or use overly-powerful integrations.

Implementations SHOULD explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
implementations SHOULD NOT assume that tracker data, repository contents, prompt inputs, or tool
arguments are fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening the active adapter's approval and sandbox controls described elsewhere in this
  specification instead of running with a maximally permissive configuration (for example Codex
  `agent.codex.approval_policy` / `agent.codex.thread_sandbox`, or Claude
  `agent.claude.permission_mode = dontAsk` paired with a tight `agent.claude.allowed_tools`
  whitelist and a `PreToolUse` workspace-boundary hook — see §10.8 for why
  `bypassPermissions` cannot be combined with a policy callback). Where the agent runs behind a
  strong external sandbox (e.g. the `jai` launcher), `bypassPermissions` with that sandbox as the
  boundary is an acceptable alternative — see Posture A in §10.8 — but the sandbox is then
  load-bearing and MUST be present.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the adapter's built-in policy controls.
- Filtering which Linear issues, projects, teams, labels, or other tracker sources are eligible for
  dispatch so untrusted or out-of-scope tasks do not automatically reach the agent.
- Narrowing the `linear_graphql` tool so it can only read or mutate data inside the
  intended project scope, rather than exposing general workspace-wide tracker access.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.

The correct controls are deployment-specific, but implementations SHOULD document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    agent_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    agent_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    identifier: issue.identifier,
    issue,
    agent_kind: get_config_agent_kind(),
    session_id: null,
    agent_pid: null,
    last_agent_message: null,
    last_agent_event: null,
    last_agent_timestamp: null,
    agent_input_tokens: 0,
    agent_output_tokens: 0,
    agent_total_tokens: 0,
    last_reported_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(workflow_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("prompt error")

    turn_result = app_server.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {agent_update, issue.id, msg})
    )

    if turn_result failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      app_server.stop_session(session)
      run_hook_best_effort("after_run", workspace.path)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)  # bookkeeping only
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    return state

  if available_slots(state) == 0:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: issue.identifier,
      error: "no available orchestrator slots"
    })

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation SHOULD include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests REQUIRED for all conforming implementations.
- `Extension Conformance`: REQUIRED only for OPTIONAL features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks RECOMMENDED before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Workflow and Config Parsing

- Workflow file path precedence:
  - explicit runtime path is used when provided
  - cwd default is `WORKFLOW.md` when no explicit runtime path is provided
- Workflow file changes are detected and trigger re-read/re-apply without restart
- Invalid workflow reload keeps last known good effective configuration and emits an
  operator-visible error
- Missing `WORKFLOW.md` returns typed error
- Invalid YAML front matter returns typed error
- Front matter non-map returns typed error
- Config defaults apply when OPTIONAL values are missing
- `tracker.kind` validation enforces currently supported kind (`linear`)
- `tracker.api_key` works (including `$VAR` indirection)
- `$VAR` resolution works for tracker API key and path values
- `~` path expansion works
- `agent.codex.command` and `agent.claude.command` are preserved as shell command strings
- `agent.kind` validates against the supported enum (`codex` | `claude`)
- Per-state concurrency override map normalizes state names and ignores invalid values
- Prompt template renders `issue` and `attempt`
- Prompt rendering fails on unknown variables (strict mode)

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- OPTIONAL workspace population/synchronization errors are surfaced
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts are ignored
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths

### 17.3 Issue Tracker Client

- Candidate issue fetch uses active states and project slug
- Linear query uses the specified project filter field (`slugId`)
- Empty `fetch_issues_by_states([])` returns empty without API call
- Pagination preserves order across multiple pages
- Blockers are normalized from inverse relations of type `blocks`
- Labels are normalized to lowercase
- Issue state refresh by ID returns minimal normalized issues
- Issue state refresh query uses GraphQL ID typing (`[ID!]`) as specified in Section 11.2
- Error mapping for request errors, non-200, GraphQL errors, malformed payloads

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order is priority then oldest creation time
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Normal worker exit schedules a short continuation retry (attempt 1)
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Retry backoff cap uses configured `agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, identifier, and error
- Stall detection kills stalled sessions and schedules retry
- Slot exhaustion requeues retries with explicit error reason
- If a snapshot API is implemented, it returns running rows, retry rows, token totals, and rate
  limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent Adapter

Adapter-agnostic checks (apply to whichever adapter implementations the runtime ships):

- Launch command uses workspace cwd and invokes `bash -lc <agent.<kind>.command>`
- Per-issue prompt is rendered from the workflow template and supplied as the first turn input
- Request/response read timeout is enforced
- Turn timeout is enforced
- Continuation turns reuse the same live session
- Command/file-change approvals are handled according to the adapter's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the adapter's documented policy and do not stall
  indefinitely
- Emitted events follow the standard vocabulary in §10.3 (with `agent_kind`, `session_id`)
- If the `linear_graphql` client-side tool extension is implemented:
  - the tool is advertised to the session via the adapter's mechanism
  - valid `query` / `variables` inputs execute against configured Linear auth
  - top-level GraphQL `errors` produce `success=false` while preserving the GraphQL body
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session

If the Codex adapter is implemented (`agent.kind == codex`):

- Session startup follows the targeted Codex app-server protocol
- Client identity/capability payloads are valid when the targeted Codex app-server protocol
  requires them
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- Thread and turn identities exposed by the targeted protocol are extracted and used to emit
  `session_started`
- Transport framing required by the targeted protocol is handled correctly
- For stdio-based transports, diagnostic stderr handling is kept separate from the protocol stream
- Usage and rate-limit telemetry exposed by the targeted protocol is extracted
- Approval, user-input-required, usage, and rate-limit signals are interpreted according to the
  targeted protocol
- If client-side tools are implemented, session startup advertises the supported tool specs using
  the targeted app-server protocol

If the Claude adapter is implemented (`agent.kind == claude`):

- Sidecar launch uses workspace cwd and forwards `ANTHROPIC_API_KEY` (and any present
  Bedrock/Vertex/Foundry routing env vars) per §10.8
- The `init` handshake completes before any `turn` request is sent
- The first `SystemMessage` with `subtype == "init"` is parsed and `session_id` (UUID) is
  captured for logs (Python: `message.data["session_id"]`; TypeScript: `message.session_id`)
- A `turn` request → `turn_end` round-trip emits the standard event vocabulary plus `usage`
  totals (snake_case keys: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
  `cache_read_input_tokens`) and is summed across turns rather than treated per-turn as
  cumulative
- Tool-call round-trip: sidecar `tool_call` → Symphony `tool_handler` → sidecar `tool_result`
- Permission round-trip: sidecar `permission_request` → Symphony policy → sidecar
  `permission_response`
- Sidecar `interrupt` aborts the in-flight turn cleanly via `await client.interrupt()`
- Sidecar process exit / malformed-line / stall behaviours mirror the Codex adapter's error
  mapping (mapped to `claude_sidecar_not_found` / `claude_sdk_error` / `permission_denied` per
  §10.5)
- When `permission_mode == "dontAsk"`, tools absent from `agent.claude.allowed_tools` are
  refused without prompting and without stalling
- A `PreToolUse` hook rejects tool inputs whose realpath escapes the workspace
- `setting_sources` is honored: when set to `[]` the sidecar loads no host-level Claude Code
  settings (deterministic isolation); when unset (default) the option is omitted so the SDK
  loads its default sources (the agent inherits the repo's `.claude/settings.json`,
  `.mcp.json`, and `CLAUDE.md`, like an interactive `claude` run)
- If `linear_graphql` is implemented, it is registered via `create_sdk_mcp_server` + `@tool`
  (in-process MCP) and addressed as `mcp__<server_name>__linear_graphql` in `allowed_tools`

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior

### 17.7 CLI and Host Lifecycle

- CLI accepts a positional workflow path argument (`path-to-WORKFLOW.md`)
- CLI uses `./WORKFLOW.md` when no workflow path argument is provided
- CLI errors on nonexistent explicit workflow path or missing default `./WORKFLOW.md`
- CLI surfaces startup failure cleanly
- CLI exits with success when application starts and shuts down normally
- CLI exits nonzero when startup fails or the host process exits abnormally

### 17.8 Real Integration Profile (RECOMMENDED)

These checks are RECOMMENDED for production readiness and MAY be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials supplied by `LINEAR_API_KEY` or a
  documented local bootstrap mechanism (for example `~/.linear_api_key`).
- If the Claude adapter is implemented, a real Claude integration smoke test can be run with
  `ANTHROPIC_API_KEY` (or the equivalent provider auth env var) and `agent.kind: claude`.
- Real integration tests SHOULD use isolated test identifiers/workspaces and clean up tracker
  artifacts when practical.
- A skipped real-integration test SHOULD be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures SHOULD
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 REQUIRED for Conformance

- Workflow path selection supports explicit runtime path and cwd default
- `WORKFLOW.md` loader with YAML front matter + prompt body split
- Typed config layer with defaults and `$` resolution
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt
- Polling orchestrator with single-authority mutable state
- Issue tracker client with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`hooks.timeout_ms`, default `60000`)
- Coding-agent adapter contract from §10 (start session, run turn, emit standard event vocabulary,
  stop session) implemented for at least one of the supported `agent.kind` values
- Adapter selection config (`agent.kind`, default `codex`) and at least one conforming adapter
  implementation (Codex App-Server per §10.7 or Claude Agent SDK per §10.8)
- Strict prompt rendering with `issue` and `attempt` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`agent.max_retry_backoff_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, `session_id`, and `agent_kind`
- Operator-visible observability (structured logs; OPTIONAL snapshot/status surface)

### 18.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- HTTP server extension honors CLI `--port` over `server.port`, uses a safe default bind host, and
  exposes the baseline endpoints/error semantics in Section 13.7 if shipped.
- `linear_graphql` client-side tool extension exposes raw Linear GraphQL access through the active
  adapter's session using configured Symphony auth (per §10.4).
- Claude Agent SDK adapter (per §10.8) exposes Symphony orchestration through `claude-agent-sdk`
  as an additional `agent.kind` option.
- TODO: Persist retry queue and session metadata across process restarts.
- TODO: Make observability settings configurable in workflow front matter without prescribing UI
  implementation details.
- TODO: Add first-class tracker write APIs (comments/state transitions) in the orchestrator instead
  of only via agent tools.
- TODO: Add pluggable issue tracker adapters beyond Linear.

### 18.3 Operational Validation Before Production (RECOMMENDED)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access
  for the selected adapter (`agent.kind`).
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- If the OPTIONAL HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (OPTIONAL)

This appendix describes a common extension profile in which Symphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

Extension config:

- `worker.ssh_hosts` (list of SSH host strings, OPTIONAL)
  - When omitted, work runs locally.
- `worker.max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - Shared per-host cap applied across configured SSH hosts.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `worker.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `workspace.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime SHOULD stay on the same host and workspace.
- A remote host SHOULD satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts MAY be treated as a pool for dispatch.
- Implementations MAY prefer the previously used host on retries when that host is still
  available.
- `worker.max_concurrent_agents_per_host` is an OPTIONAL shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch SHOULD wait rather than silently falling back to a
  different execution mode.
- Implementations MAY fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host SHOULD be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations SHOULD distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same ticket is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host SHOULD reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.
