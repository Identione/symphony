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

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/Identione/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/Identione/symphony/blob/main/elixir/README.md

For project bootstrap, `./bin/symphony init --linear-project <URL> --repo-url <URL> --agent codex`
generates a usable `WORKFLOW.md` and `./bin/symphony preflight ./WORKFLOW.md` validates Linear
auth, repo reachability, agent availability, workspace writability, and dashboard port without
spawning any agents — see [elixir/README.md](elixir/README.md#how-to-use-it) for the full flow.

For operator setup that lives outside the repo — in particular the Codex permissions profile
required when `WORKFLOW.md` sets `codex.use_configured_permissions: true` — see [SETUP.md](SETUP.md).

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
