# R9 — Model-tiered subagents (implementation plan)

_Plan date: 2026-06-16. Companion to [`claude-token-spend-remediation-plan.md`](./claude-token-spend-remediation-plan.md)._

## Why this exists (and why it replaces R0)

R0 (switch the bulk agent to Sonnet) was **rejected**: the Todo/In-Progress work is
*planning + implementation*, which is exactly where Opus quality earns its cost — a weaker plan
means more turns and reworks, eating the nominal 5× saving.

R9 keeps **Opus as the main (planning) agent** and lets it **delegate bounded sub-tasks to
cheaper-model subagents**. Two compounding wins:

1. **Cheaper model for grunt work** — exploration / search / log-digging / mechanical edits run on
   Sonnet or Haiku, not Opus.
2. **Context isolation (the larger win)** — a subagent runs its `Read`/`Bash` calls in *its own*
   conversation; those large outputs accrue `cache_read` on the cheap model, and only a compact
   **summary** returns to the Opus thread. The ledger (`claude-token-spend-analysis.md` §2c) shows
   subagent results already average ~3,202 chars returned vs. a 7,377-char average `Read` re-read
   ~300× inline. This directly attacks the 49% `cache_read` line — arguably better than the R2b
   truncation hook, because the main thread never sees the raw bytes. (The review-phase fan-out
   already does exactly this on Haiku in our runs — §2c's 214 `Agent` calls — but *exploration*, the
   bulk of the `Read` line, is not yet delegated; the `explorer` subagent closes that gap.)

R9 therefore **subsumes the rejected R0 and a large part of R2b**.

## Verified facts (against the installed toolchain, 2026-06-16)

- **SDK supports it.** `claude_agent_sdk/types.py`:
  - `AgentDefinition` (`:82-99`) — per-subagent `model` (`"opus"`/`"sonnet"`/`"haiku"`/`"inherit"`
    or full ID), plus `effort`, `tools`, `disallowedTools`, `prompt`, `maxTurns`, `permissionMode`,
    `mcpServers`, `initialPrompt`, `skills`, `memory`, `background`.
  - `ClaudeAgentOptions.agents: dict[str, AgentDefinition] | None` (`:1781`) —
    "Programmatically define custom subagents invokable via the Agent tool."
- **Delegation tool name is `Agent`.** Confirmed against the pinned CLI
  (`/Users/hniska/.local/share/claude/versions/2.1.178`): the in-binary guidance reads
  _"To delegate work to a subagent, use the **Agent tool**"_ (params `subagent_type` + `prompt`).
  The historical `Task` name now refers to the task-list family (`TaskCreate`/`TaskGet`/…), a
  different thing. So the tool name is **`Agent`**, not `Task` — though whether it needs whitelisting
  at all is in doubt (Verified facts #3 below).
- **Symphony does not *configure* subagents — but they already run.** The sidecar builds
  `ClaudeAgentOptions(**payload)` (`sidecar.py:511`), never passes `agents`
  (`build_options_payload`, `sidecar.py:318-345`), and no instance whitelists `Agent`. *Yet the
  Agent tool is already invoked in agent runs:* the ledger counts **214** `Agent (subagent results)`
  calls (`claude-token-spend-analysis.md` §2c); a sampled sidecar session (`…IDE-88`) shows 3 —
  diff-review fan-outs spawned by the loaded `simplify`/`code-review` skill, **running on Haiku**
  (their subagent transcripts are `claude-haiku-4-5-20251001`). Two consequences:
  - **`allowed_tools` does NOT gate the Agent tool.** `Agent` (and `Skill`) ran while absent from
    every whitelist → **R9.5's "add `Agent` to `allowed_tools`" is not the enabler** the plan first
    assumed. Confirm the real gate during R9.5; don't treat the whitelist as load-bearing here.
  - **What's missing is *control*, not the capability.** These delegations are incidental to whichever
    skills happen to load, cover only the **review** phase, and Symphony tunes none of it (model,
    tools, when they fire). The dominant `Read` line (3.1M tok of *exploration*) is **not** delegated.
    R9's value is a deterministic, Symphony-configured roster (esp. an `explorer` for that Read line) —
    not "turning on" a dormant feature.

## Plumbing chain

Mirrors exactly how `model`/`effort`/`model_by_state` already flow — each stop has a known pattern
to copy:

```
schema.ex (agents field)
  → AppServer.resolve_config/2     (carry into the resolved map)
  → AppServer.write_init/3         (emit into the init envelope, omit when empty)
  → sidecar.build_options_payload  (map snake→camel, plain dicts — SDK-free)
  → sidecar._handle_init           (wrap each → AgentDefinition; SDK-only path)
  → ClaudeAgentOptions(agents=…)   → CLI Agent tool
```

---

## TDD steps (red → green per repo convention)

### R9.1 — Schema field `agent.claude.agents`
- **Red** — `test/symphony_elixir/claude_adapter_config_test.exs` (model on the `model_by_state`
  tests at `:206-243`):
  - `agent.claude.agents` defaults to `%{}`.
  - parses a map `name → %{description, prompt, model, effort, tools, ...}`.
  - rejects a non-map value.
- **Green** — `lib/symphony_elixir/config/schema.ex:308` (Claude embed):
  `field(:agents, :map, default: %{})` + cast in the changeset. Keep it a **permissive map** (same
  posture as `model_by_state`); shape is validated at the sidecar boundary, not in Ecto.

### R9.2 — `resolve_config/2` carries `:agents`
- **Red** — `claude_adapter_config_test.exs`: the resolved map from `AppServer.resolve_config/2`
  includes `:agents` (global pass-through — NOT state-resolved).
- **Green** — `lib/symphony_elixir/claude/app_server.ex:174-189`: add `agents: claude.agents` to
  the returned map.

### R9.3 — `write_init/3` emits `agents` (omit when empty)
- **Red** — `test/symphony_elixir/claude_app_server_test.exs` (wire/init test): the init envelope
  includes `agents` when configured; **omits** the key entirely when `%{}`.
- **Green** — `app_server.ex:324-349`: add `agents: nilify_empty(Map.get(config, :agents))` —
  collapse `%{}` → `nil` so the existing `is_nil` reject (`:349`) drops it, keeping parity with
  every other optional field. Add a tiny `nilify_empty/1` helper (`%{}`/`nil` → `nil`, else the map).

### R9.4 — Sidecar maps `agents` (SDK-free), then constructs `AgentDefinition` (SDK path)
> ⚠️ **Do not construct `AgentDefinition` inside `build_options_payload`.** That function is
> deliberately SDK-free (`test_sidecar_wire.py:1-8`: "do not require claude-agent-sdk"; the import is
> `try/except`-guarded at `sidecar.py:25-38`). And you can't pass plain dicts straight through to
> `ClaudeAgentOptions(agents=…)` either: the SDK calls `asdict(agent_def)` on each value
> (`client.py:220`), which raises `TypeError` on a dict — it needs real dataclass instances. So split
> mapping (testable, no SDK) from construction (SDK-only path).

**R9.4a — map snake_case → camelCase (in `build_options_payload`, SDK-free)**
- **Red** — `priv/claude_agent/tests/test_sidecar_wire.py` (model on
  `test_build_options_payload_forwards_effort_when_set` at `:108`):
  - an init envelope with
    `agents: {"explorer": {"description": "...", "prompt": "...", "model": "haiku", "tools": ["Read","Grep"], "disallowed_tools": ["Bash"]}}`
    yields `payload["agents"] == {"explorer": {"description": ..., "prompt": ..., "model": "haiku", "tools": ["Read","Grep"], "disallowedTools": ["Bash"]}}`
    — **plain dicts, camelCased keys** (no `AgentDefinition` import in this test).
  - absent `agents` → the key is omitted from the payload.
- **Green** — `priv/claude_agent/symphony_claude_agent/sidecar.py:318` `build_options_payload`: for
  each entry, map snake_case → the SDK's camelCase field names (`disallowed_tools→disallowedTools`,
  `max_turns→maxTurns`, `permission_mode→permissionMode`, `initial_prompt→initialPrompt`,
  `mcp_servers→mcpServers`; `model`/`tools`/`effort`/`skills`/`memory`/`background` pass through).
  Emit `payload["agents"]` as a dict of plain dicts, only when present/non-empty. Drop a malformed
  entry (missing `description`/`prompt`) defensively (log + skip), consistent with
  `extract_tool_schemas`.

**R9.4b — construct `AgentDefinition` (in `_handle_init`, SDK path, `# pragma: no cover`)**
- **Green** — `sidecar.py:480-511` `_handle_init`, right before `ClaudeAgentOptions(**payload)`: if
  `payload.get("agents")`, replace it with
  `{name: AgentDefinition(**d) for name, d in payload["agents"].items()}`. Add `AgentDefinition` to
  the guarded SDK import block (`sidecar.py:26-34`; it's exported from `claude_agent_sdk` top-level).
  This is the same SDK-only code path that already injects `mcp_servers`/`stderr`, so it stays out of
  the SDK-free unit tests. (No separate unit test — exercised by the SDK integration path, like
  `mcp_servers`.)

### R9.5 — Operator config + prompt steering *(config + docs; the actual tuning)*
This is where behavior actually changes, and where the open decision lives (below).
- Define an `agents:` block (candidate roster below). **This is the lever** — it gives Symphony
  deterministic control over the subagent model/tools that today are left to whichever skill loads.
- ~~Add `Agent` to `allowed_tools`.~~ **Likely a no-op** — the Agent tool already runs while absent
  from the whitelist (see Verified facts #3). Confirm the gate empirically first; if built-ins really
  aren't gated by `allowed_tools`, skip this step so the doc doesn't imply it's required.
- Steer in the `WORKFLOW.md` body: "delegate codebase search / file exploration to the `explorer`
  subagent instead of reading files inline; reserve direct Reads for files you will edit." Steering
  is the mechanism, not polish — a bare skill fan-out only fires for review; exploration won't
  delegate unless told to, and only delegates to a roster subagent when the prompt names it
  (`subagent_type: explorer`).
- ⚠️ `elixir/WORKFLOW.md` is a **tested fixture** — adding an `agents` block (and any `allowed_tools`
  change) may trip fixture-asserting tests. Check `claude_app_server_test.exs` /
  `workspace_and_config_test.exs` before editing.

---

## Caveats to resolve during implementation (not hand-waved)

1. **`permission_mode: dontAsk` × subagent tools** *(largely answered by existing runs).* The
   `…IDE-88` subagents made `Read`/`Grep`/`Bash` calls successfully under `dontAsk`, and the rostered
   tools (explorer: `Read`/`Grep`/`Glob`; mechanic: `Edit`/`Write`/`Bash`) are all already in the
   instances' `allowed_tools`. Downgrade from "must verify" to "spot-check" — the failure mode would
   be a subagent tool *outside* the parent whitelist.
2. **Workspace-cwd invariant (CLAUDE.md hard rule).** Subagents inherit the session cwd; confirm
   they stay under `workspace.root` and never see the source repo. Almost certainly fine (shared
   cwd), but it's an enforced invariant so it must be checked, not assumed.
3. **`setting_sources: []`** (all live instances) is meant to disable on-disk `.claude/agents/*.md`,
   making the programmatic `agents` map the **only** source of *definitions* — the deterministic
   behavior we want, but it means inline WORKFLOW config is mandatory, not optional. ⚠️ Confirm this
   actually holds: the `…IDE-88` evidence shows *skills* (`simplify`) still load and fan out subagents
   under isolation, so don't assume isolation suppresses every delegation path.
4. **Steering dependency.** The win only materializes if Opus actually delegates. Without explicit
   prompt steering it will keep doing the work inline. This is a tuning loop, not a one-shot.
5. **Per-delegation overhead.** A subagent is a fresh session; net-positive for token-heavy tasks,
   net-negative for trivial ones. Scope subagents to genuinely heavy work.
6. **Subagents can't call `linear_graphql`.** `AgentDefinition.mcpServers` takes server names/inline
   configs, but Symphony's `symphony` MCP server is an in-process object built per session
   (`sidecar.py:452-477`) — not nameable via config. Fine for `explorer`/`mechanic`, but don't design
   a roster subagent that needs Linear access.

---

## Open decisions (resolve before R9.5)

### D1 — How far to take this pass
- **(a) Plumbing only (R9.1–R9.4).** Ships the *capability*, fully TDD. Empty `agents` map = today's
  behavior exactly → zero runtime change until an operator opts in. Safest; lets the roster be
  designed separately. **Recommended first step.**
- **(b) Plumbing + example roster.** (a) plus a documented (but not live-wired) `agents` block in the
  canonical `elixir/WORKFLOW.md` as a copy-paste starting point.
- **(c) Plumbing + wire into live instances.** Everything — roster + steering in
  `symphony`/`entry-elixir` instances (no `allowed_tools` change needed; see R9.5) → takes effect on
  next restart. Highest impact, but the roster is unvalidated on real issues.

### D2 — Candidate subagent roster
- **explorer** — Haiku, read-only (`Read`, `Grep`, `Glob`). Codebase search & exploration. Highest
  value (Read is the 3.1M-token line), lowest risk (cannot modify anything).
- **mechanic** — Sonnet, edit-capable (`Read`, `Edit`, `Write`, `Bash`). Bounded mechanical edits.
  Higher value, higher risk — needs validation.
- Options: ship **explorer only** (conservative), **explorer + mechanic** (covers both top sinks),
  or **decide later** (pairs with D1(a)).

### Recommendation
Do **D1(a) plumbing-only now** (mechanical, safe, no behavior change — an empty `agents` map
reproduces today's behavior exactly), then validate an **explorer** subagent on a handful of real
issues before adding `mechanic` or wiring into live instances. The upside is against the
**`Read`/exploration** line specifically: review-phase delegation already happens on Haiku (the
ledger's 214 calls), so don't re-count it — the explorer is the net-new lever.

---

## Docs to update on landing
- `SPEC.md` §10.8 — claude adapter init-envelope contract (new `agents` field).
- `claude-token-spend-remediation-plan.md` — add R9; note it subsumes rejected R0 + part of R2b.
- `elixir/README.md` — the `agent.claude.agents` config knob.
- `elixir/docs/token_exhaustion.md` — only if escalation/retry semantics are touched (they are not).

## Quality gate
`cd elixir && make all` (fmt, lint, coverage, dialyzer) + the sidecar `pytest` suite, on a fresh
`jj` change. No public `def` added without an adjacent `@spec` (the `nilify_empty/1` helper is a
`defp`, exempt).

---

## Review (2026-06-17) — underspecified / inconsistent / weird points

Traced the full chain against the installed toolchain (schema → `app_server` → `sidecar` → SDK
`AgentDefinition` → `client.py` `asdict`) and the test/fixture surface. **The mechanical claims hold:**
line anchors, the `AgentDefinition` field set (`types.py:82-99`), the `asdict(agent_def)` requirement
(`_internal/client.py:157`, `client.py:220`), the SDK-free boundary, and the `is_nil`-reject parity all
check out. The plumbing (R9.1–R9.4) is sound and low-risk. The findings below are at the design / spec
level — concentrated in the **value half** (R9.5 + recommendation), which rests on unverified
assumptions.

### Strategy / value is hollow or unverified
1. **[inconsistent] The recommended first step delivers none of the headline savings.** D1(a)
   "plumbing only" ships the capability but — by the plan's own words — is "zero runtime change until an
   operator opts in," and savings additionally require steering (caveat #4). So the recommended path
   produces *zero* attack on the 49% `cache_read` line the doc is premised on; all value defers to the
   "unvalidated" D1(c).
2. **[inconsistent] The enabling mechanism is admittedly unknown.** Verified-fact #2 asserts the tool is
   `Agent`; #3 and R9.5 then say whitelisting is "likely a no-op / in doubt — confirm the gate
   empirically." The whole plan rests on subagents firing, yet *how they're gated* is open going in.
3. **[inconsistent] R9 enables what the shipped config explicitly forbids.** `elixir/WORKFLOW.md`'s
   `allowed_tools` comment states the posture grants "no unsupervised sub-agents," and `Agent` is absent
   from every instance whitelist (verified). R9 turns that on without reconciling the contradiction or
   noting that the comment becomes false.
4. **[unaddressed tension] The `explorer` reintroduces the exact thing R0 was rejected for.** R0 was
   rejected because "a weaker plan means more turns and reworks." The 3.1M-token Read line *is*
   exploration-during-planning — deciding what to read is planning-adjacent judgment. Haiku in that loop
   trades Opus's judgment about relevance for Haiku's; the tension between "reject R0" and "explorer on
   Haiku" is never addressed.

### Untested / crash-prone paths
5. **[risk] R9.4b ships genuinely untested.** The wire/dry-run tests cover only `build_options_payload`
   (SDK-free; no test references `_handle_init`/`AgentDefinition`/`ClaudeAgentOptions`). The
   `AgentDefinition(**d)` construction is `# pragma: no cover`. "Exercised by the SDK integration path,
   like `mcp_servers`" is **not** true — `mcp_servers` construction is *also* uncovered. The riskiest line
   lands with no test.
6. **[risk] One operator typo hard-fails every issue.** R9.4a drops entries missing
   `description`/`prompt` but does **not** strip/validate unknown keys. A typo like `disalowed_tools:`
   survives R9.4a, then `AgentDefinition(**d)` raises `TypeError: unexpected keyword argument` in
   `_handle_init` → `ready` never emitted → `start_session` fails for *every* issue, in the untested path.
   **Fix:** R9.4a should whitelist-filter inner keys to the known `AgentDefinition` field set (log+drop
   unknowns), which also closes #5/#11 when paired with a `_handle_init` test.
7. **[underspecified] Subagent permission round-trip is not wired.** `sidecar.py:441-443`: the
   `can_use_tool` path is "Currently unused." A subagent that needs an approval (or sets its own
   `permissionMode`) has no responder. Caveat #1 downgrades this to "spot-check," but a missing permission
   channel is the concrete blocker for exactly the failure mode caveat #1 names.

### Missing validation / enforcement
8. **[underspecified] Nothing enforces subagent tools ⊆ parent `allowed_tools`.** Caveat #1 *observes*
   the rostered tools happen to be whitelisted; no code checks it. A `mechanic` granted an off-whitelist
   tool is undefined under `dontAsk` (ties to #7).
9. **[inconsistent] Asymmetric validation.** Top-level `effort`/`permission_mode` are strictly validated
   (`schema.ex:405,407` `validate_inclusion`); subagent `effort`/`permission_mode` ride the permissive
   `:map` with zero validation and flow straight to `AgentDefinition`/CLI.
10. **[underspecified] Operator-facing key casing is never stated.** R9.4a maps snake→camel, so an
    operator copying SDK field names (camelCase, as in `types.py`) gets pass-through-by-luck for some keys
    but a `TypeError` for any snake-only key the mapping didn't rename. The doc never says "author
    snake_case in WORKFLOW.md."

### Weird-but-correct / footguns
11. **[weird] Two casing conventions in one payload.** `build_options_payload` emits snake_case
    `ClaudeAgentOptions` kwargs, but the `agents` sub-dicts must be camelCase (`disallowedTools`,
    `maxTurns`, `permissionMode`) because `AgentDefinition` fields are camelCase. Correct, but the R9.4a
    test must assert outer-snake / inner-camel, and it's a real footgun.
12. **[inconsistent] `mcp_servers→mcpServers` is mapped but unusable.** Caveat #6 says the only MCP
    server (`symphony`/`linear_graphql`) is an in-process object not nameable in config, and live
    instances run `setting_sources: []` (no external named servers). The mapped field can reference nothing
    real — dead weight that invites operators to wire Linear access that silently no-ops.
13. **[inconsistent] "Mirrors exactly how model/effort flow" overstates it.** R9.2 explicitly makes
    `agents` a *global pass-through*, NOT state-resolved — so it flows like the static fields
    (`allowed_tools`), not like `model`/`effort` (which go through `resolve_by_state`). The chain diagram's
    framing contradicts R9.2's own note.
14. **[underspecified] `background` passthrough vs. synchronous turn model.** `AgentDefinition.background`
    is listed as passthrough but never discussed. `run_turn` collects until terminal
    (`collect_until_terminal`); a backgrounded subagent could outlive the turn or muddy `receive_response`
    completion. No guard.
15. **[underspecified] Per-subagent `maxTurns` works *against* the savings goal.** A subagent is a fresh
    session with its own turn cap; an over-budget explorer can burn more than it saves. Caveat #5 gestures
    at "per-delegation overhead" but never names `maxTurns` as the knob to bound it.

### Spec / docs / context gaps
16. **[weird] Example and deployment have different settings semantics.** D1(b)'s example lands in
    `elixir/WORKFLOW.md`, where `setting_sources` is unset (commented) → on-disk `.claude/agents/*.md`
    still load. Live instances run `setting_sources: []` → only the programmatic map. A copy-paste
    "starting point" silently changes *which* definitions apply.
17. **[inconsistent] Caveat #3 undercuts itself.** It calls the programmatic map the "only source" under
    `setting_sources: []`, then immediately notes skills (`simplify`) still fan out under isolation. So
    isolation does *not* make the roster the sole driver of subagent behavior even in the recommended
    config — left unresolved.
18. **[weird] Mis-scoped invariant.** Caveat #2 imports the CLAUDE.md "Codex turn cwd must never be the
    source repo" rule — a Codex/`workspace.ex` invariant. Claude subagents share the parent's per-issue
    cwd already, so the check is automatically satisfied; the caveat flags a non-bite as something to
    verify.
19. **[weird] Ledger framing is apples-to-oranges and projected.** "~3,202-char subagent return vs
    7,377-char Read re-read ~300×" compares a per-call return to a re-read *count*. The 214 Agent calls
    already run on Haiku (their `cache_read` is already in the ledger). "Directly attacks the 49% line" is a
    projection for the unmeasured net-new explorer — the doc says "don't re-count" but the headline still
    leans on the counted number.
20. **[underspecified] The mandated SPEC §10.8 edit has no defined shape.** "Update SPEC §10.8 (new
    `agents` field)" never specifies the wire envelope sub-shape (snake vs camel, required keys). Since SPEC
    is source-of-truth and the impl "must not conflict," the SPEC edit itself is underspecified.

> Minor accuracy nit: the cited Red-test anchor `claude_adapter_config_test.exs:206-243` is actually
> ~205–243 (`model_by_state` block) — trivial, but flagged because this is a line-precise "verified facts"
> doc.

### Bottom line
Ship **R9.1–R9.4 as written**, with two hardening changes that together close #5/#6/#10: (a) in R9.4a,
whitelist-filter each subagent's inner keys to the known `AgentDefinition` field set (log + drop unknowns)
rather than only checking `description`/`prompt`; (b) add a real `_handle_init` test that constructs an
`AgentDefinition` from a mapped payload. Do **not** treat D1(a) as delivering savings. Before R9.5, resolve
the three load-bearing unknowns the plan defers: what actually gates `Agent` (#2), whether subagent
permission requests can round-trip at all (#7), and whether Haiku-driven exploration reintroduces the R0
failure mode (#4).
