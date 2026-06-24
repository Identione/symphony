# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise the coding agent; they can manage the work at a higher level._

Symphony's coding-agent runtime is pluggable (SPEC.md §10). Two adapters ship with the reference implementation:

- **Codex App-Server** (`agent.kind: codex`, default) — runs OpenAI Codex via its app-server protocol.
- **Claude Agent SDK** (`agent.kind: claude`) — launches a Python sidecar that hosts `claude-agent-sdk`. Generated instances ship `permission_mode: bypassPermissions` (allow-all), relying on the outer `jai` sandbox + workspace-`cwd` boundary so the agent runs unattended without ever pausing for human input. For a tighter posture, set `permission_mode: dontAsk` and an explicit `allowed_tools` whitelist (that combination is also the schema default if `permission_mode` is omitted; an empty whitelist under `dontAsk` is rejected at boot). Like an interactive `claude` run, it loads the target repo's Claude Code settings (`.claude/settings.json`, project `.mcp.json` servers such as `lsp`, and `CLAUDE.md`); set `agent.claude.setting_sources: []` for deterministic isolation.

Either adapter can opt into account-quota-aware dispatch pausing (`agent.<provider>.quota`, off by default): Symphony surfaces provider usage on the dashboard and, when enabled, stops dispatching new work while usage is near the account limit — see SPEC.md §5.3.5.3.

When a run approaches its continuation cap (`agent.max_turns`), Symphony steers the agent to commit its in-progress work, and — as a safety net independent of whether the agent obeys — non-destructively snapshots any uncommitted work (modified, staged, and untracked files) to a `refs/symphony/wip/<id>` commit before stopping the session, so converging work is never silently discarded. See SPEC.md §6 and §9.4.1.

An AI overseer (`agent.overseer`, **on by default** but dormant without a resolved API key) judges an extending run against its plan and is the binding controller of the per-session turn budget: it approves continued extension (up to `absolute_max_turns`, default 500) or gives up — posting findings, suppressing the retry, and moving the issue to Human Review after one graceful wind-down turn (commit + workpad update). Without a resolved key the run caps at `agent.max_turns` and posts a "could not judge" comment. Read-only by construction (it cannot touch the workspace) and fails open on any error. See SPEC.md §13.6.

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Quick start

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/).

```bash
git clone https://github.com/Identione/symphony
cd symphony
mise trust elixir && mise install
make build
make init INSTANCE=my-repo ARGS="\
  --linear-project https://linear.app/<org>/project/<slug> \
  --repo-url git@github.com:<org>/<repo>.git \
  --agent codex \
  --port 3454"          # add --host 0.0.0.0 for a LAN-visible dashboard
cd instances/my-repo
make preflight
make start              # `make logs`, `make stop`, `make help` from here
```

Each `make init` creates an isolated `instances/<name>/`; multiple instances can run in parallel
from the same checkout.

Add `--base-branch <name>` to point an instance at a development branch instead of `main`: agents
branch from, sync with, and merge into `<name>` (each issue on its own `symphony/<issue-id>` branch,
PRs targeting `<name>`), leaving `main` untouched. Omit it and nothing changes — work targets the
repo's default branch as before. Pair such an instance with its own Linear project so only the
intended issues feed it.

Running several instances? Keep them in a local manifest instead of re-typing `make init`. Copy
`instances.local.example` to `instances.local` (gitignored), list one instance per line as
`<name> <init-args>` — the first token is the instance name, the rest is forwarded verbatim to
`make init` (blank lines and `#` comments are ignored):

```
# instances.local
symphony --linear-project https://linear.app/<org>/project/<slug> --repo-url git@github.com:<org>/symphony.git --agent claude --port 3454
entry    --linear-project https://linear.app/<org>/project/<slug> --repo-url git@github.com:<org>/entry.git    --agent codex  --port 3455
```

Then generate them all at once:

```bash
cp instances.local.example instances.local   # then edit: one instance per line
make init-all                                 # creates missing instances, skips existing
make init-all FORCE=1                          # regenerate all (passes --force)
```

## Upgrading after a `git pull`

```bash
git pull
make upgrade-all                       # rebuild escript + restart every running instance (serial)
make upgrade INSTANCE=my-repo          # …or one at a time
cd instances/my-repo && make upgrade   # …or from inside the instance
```

`upgrade` always rebuilds `elixir/bin/symphony` and only restarts daemons that are currently
running — stopped instances are left alone and pick up the new escript on their next `make start`.

It does **not** regenerate `WORKFLOW.md` or the instance `Makefile`. To pull in template changes,
re-run `make init INSTANCE=<name> ARGS="--force ..."` — that clobbers both files, so back up any
hand-edits first.

It also does **not** upgrade the agent toolchain (codex, claude-agent-sdk). That's a separate,
deliberate action — `cd elixir && make upgrade-tools` — which refreshes `mise.lock` and the
sidecar's `uv.lock`. See [elixir/README.md](elixir/README.md#upgrading-the-agent-toolchain).

## Utility scripts

### Scanning token waste

`scripts/scan_token_waste.py` analyzes Claude Agent SDK session transcripts to quantify rate-limit waste per issue. It outputs CSV statistics on rate-limiting impact and session efficiency, useful for diagnosing and tracking API quota issues.

Usage:

```bash
python3 scripts/scan_token_waste.py [BASE_DIR] > token_waste.csv
ssh orchestrator-host 'python3 -' < scripts/scan_token_waste.py > token_waste.csv  # pipe over SSH
```

Output columns: `issue`, `sessions`, `ratelimit_sessions`, `assistant_turns`, `ratelimit_turns`, `ratelimit_share`, `turns_in_rl_sessions`, `rl_session_share`.

Base directory defaults to `~/.jai/default.changes/.claude-identione/projects` (where orchestrator transcripts live). Two waste measures are reported: turn-level (`ratelimit_share`) and session-level (`rl_session_share`).

---

- Full flag list and operator notes: [elixir/README.md](elixir/README.md)
- Codex permissions profile setup: [SETUP.md](SETUP.md)
- Building your own from scratch: [SPEC.md](SPEC.md)

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
