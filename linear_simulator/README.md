# Linear API Simulator (`linear_sim`)

A Linear-compatible GraphQL API simulator for local development and deterministic
testing of [Symphony](../elixir). It behaves like a small, controllable Linear
workspace — not a full clone — implementing only the operations Symphony actually
sends. Design and rationale live in [`docs/linear-sim.md`](docs/linear-sim.md).

Stack: Elixir + Phoenix + Absinthe + Ecto + SQLite (Req for outbound webhooks).

## Quick start

```bash
cd linear_simulator
mise install            # Erlang 28 / Elixir 1.19 (pinned in mise.toml)
mise exec -- mix setup  # deps.get + ecto.create + migrate + seed basic_workspace + assets
mise exec -- mix phx.server   # serves http://localhost:4000
```

`mix setup` includes `mix assets.setup`, which copies the prebuilt LiveView JS
client (`phoenix.min.js` + `phoenix_live_view.min.js`) from deps into
`priv/static/assets/` — there is no JS bundler. Re-run `mix assets.setup` after a
`phoenix`/`phoenix_live_view` upgrade.

Health check: `curl http://localhost:4000/health` → `{"status":"ok"}`.

## Dashboard (web UI)

A LiveView control dashboard is served at the root path — open
<http://localhost:4000/> in a browser. It is styled like Linear (dark theme,
indigo accent, monospace technical values) and exposes the simulator's control
plane interactively:

| Page | Path | What it does |
| --- | --- | --- |
| Overview | `/` | Live entity counts + current scenario / response mode / capture state |
| Scenarios | `/scenarios` | Load any scenario; force a response-mode override |
| Entities | `/entities` | Browse issues, projects, teams, workflow states, users |
| Captured Operations | `/captured` | Inspect captured ops; promote to the curated corpus; clear |
| Webhooks | `/webhooks` | Sign & replay a webhook; delivery history |
| Settings | `/settings` | Toggle operation capture / GraphQL logging; reset / wipe |

The top bar's **Reset** and **Capture ops** controls and live status pills work
on every page. Tailwind and fonts load from a CDN, so the browser needs network
access (fine for a local dev tool).

## Endpoints

| Endpoint | Purpose |
| --- | --- |
| `POST /graphql` | Linear-compatible GraphQL endpoint |
| `GET /health` | Liveness probe |
| `POST /admin/reset` | Reset to the default scenario (`basic_workspace`) |
| `POST /admin/scenario/:name` | Load a named scenario |
| `POST /admin/webhooks/replay` | Sign + deliver a Linear-style webhook to a target app |
| `GET /admin/state` | Dump coarse state counts for debugging |

## Scenarios

State is driven entirely by named scenarios (`LinearSim.Scenarios`). Each wipes
all tables and re-seeds deterministic, string-keyed fixtures.

| Scenario | Contents |
| --- | --- |
| `basic_workspace` | org `Acme`, user `user_hakan`, team `ENG`, project `roadmap`, one Todo issue `ENG-1`, one seeded workpad comment |
| `empty_workspace` | the skeleton with no issues |
| `many_issues` | 75 Todo issues (exercises pagination) |
| `archived_issues` | one active Todo issue and one archived (Done) issue |
| `webhook_demo` | same as `basic_workspace` |
| `rate_limited` | basic data, but `/graphql` returns a Linear `RATELIMITED` error body |
| `invalid_token` | basic data, but `/graphql` returns an `AUTHENTICATION_ERROR` body |
| `permission_denied` | basic data, but `/graphql` returns a `FORBIDDEN` body |

```bash
curl -X POST http://localhost:4000/admin/scenario/many_issues
```

## Auth

Send `Authorization: Bearer <token>`. The default token is `user_hakan` (resolves
to the seeded user/org). A missing header falls back to the default user; an
unrecognised token yields a Linear-like auth error.

## Implemented operations

The curated corpus lives under `priv/linear/operations/curated/` — the 12
operations Symphony sends (the core five queries + three mutations, plus four
preflight queries), each with example variables, scenario, auth, and expected
response paths. They are replayed in CI by
`test/linear_sim_web/operation_replay_test.exs`.

### Compatibility harness

The harness proves — in pure Elixir, no Node — that every operation Symphony
sends validates against **both** the real Linear schema and the simulator schema,
and replays correctly against deterministic scenarios. How it works and what you
can do with it is documented in
[`docs/compatibility-harness.md`](docs/compatibility-harness.md) (design rationale
in [`docs/linear-sim.md`](docs/linear-sim.md) § "Compatibility Coverage"). Run the
whole chain with:

```bash
make compat        # dump_schema → validate_operations → replay_operations → compatibility_report
```

Individual tasks:

- `mix linear.fetch_schema` — introspects `https://api.linear.app/graphql`
  (needs `LINEAR_API_KEY`) and writes the committed reference snapshot:
  `priv/linear/schema_reference.json` (authoritative), `schema_reference.graphql`
  (best-effort SDL, for diffs), and `schema_metadata.json`. Run **deliberately**,
  like a dependency bump — it is *not* part of `make compat`.
- `mix linear_sim.dump_schema` — writes the simulator's `schema.graphql` + the
  symmetric `schema.json` under `priv/linear_sim/`.
- `mix linear_sim.validate_operations` — validates each curated operation against
  **both** schemas and classifies it into the four-quadrant matrix (docs §6).
  Simulator-invalid ops are a required (non-zero) failure; reference drift is
  advisory. If the reference snapshot is absent the reference column is skipped
  with a warning and only the simulator gate applies.
- `mix linear_sim.replay_operations` — replays the corpus against scenarios via
  `Absinthe.run/3` (the `make compat`/CI entrypoint; the HTTP replay path stays
  covered by `test/linear_sim_web/operation_replay_test.exs`).
- `mix linear_sim.compatibility_report` — aggregates the above plus schema drift
  into `tmp/linear_sim/compatibility_report.{txt,json}` (docs §8).

The shared validation engine lives under `lib/linear_sim/compat/`
(`ReferenceSchema` indexes either schema's introspection JSON; `OperationValidator`
walks an operation's selection sets against it). Each curated `metadata.json`
carries a `compatibility` block (`level`/`requiresBehavior`/`knownDifferences`,
docs §11) that the report surfaces as behavioural gaps.

**Operation capture** (`config :linear_sim, :operation_capture, enabled: true`)
writes incoming GraphQL documents to `priv/linear/operations/captured/` — useful
for discovering **agent ad-hoc operations** (e.g. a `MoveIssue` mutation a coding
agent issues via symphony's `linear_graphql` tool). Promote useful captures into
the curated corpus.

## Pointing Symphony at the simulator

Symphony's Linear endpoint is configurable via `tracker.endpoint`. In an instance
`WORKFLOW.md`, set:

```yaml
tracker:
  endpoint: http://localhost:4000/graphql
  api_key: user_hakan        # any seeded token; bypasses $LINEAR_API_KEY
  project_slug: roadmap
  active_states: ["Todo"]
```

With `basic_workspace` loaded, Symphony's poll (`SymphonyLinearPoll`) returns
`ENG-1`. Transitions (`issueUpdate`) and comments (`commentCreate`/`commentUpdate`)
mutate simulator state; reset between runs with `POST /admin/reset`.

## Tests

```bash
mise exec -- mix test
```

Tests use file-backed SQLite with **explicit scenario reset** (not the SQL
sandbox), so every test that touches simulator state runs `async: false` and resets
to a known scenario in setup (`docs/linear-sim.md` §5–6). Use the `@tag scenario:`
attribute to pick a non-default scenario per test.
