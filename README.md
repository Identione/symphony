# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

_In this [demo video](.github/media/symphony-demo.mp4), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise the coding agent; they can manage the work at a higher level._

Symphony's coding-agent runtime is pluggable (SPEC.md §10). Two adapters ship with the reference implementation:

- **Codex App-Server** (`agent.kind: codex`, default) — runs OpenAI Codex via its app-server protocol.
- **Claude Agent SDK** (`agent.kind: claude`) — launches a Python sidecar that hosts `claude-agent-sdk`. Sandbox-by-default: `permission_mode: dontAsk` + an explicit `allowed_tools` whitelist + workspace-`cwd` boundary, so the agent runs unattended without ever pausing for human input.

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

- Full flag list and operator notes: [elixir/README.md](elixir/README.md)
- Codex permissions profile setup: [SETUP.md](SETUP.md)
- Building your own from scratch: [SPEC.md](SPEC.md)

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
