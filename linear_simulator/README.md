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
mise exec -- mix setup  # deps.get + ecto.create + migrate + seed basic_workspace
mise exec -- mix phx.server   # serves http://localhost:4000
```

Health check: `curl http://localhost:4000/health` → `{"status":"ok"}`.

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

The curated corpus lives under `priv/linear/operations/curated/` — the exact eight
operations Symphony sends (five queries, three mutations), each with example
variables, scenario, auth, and expected response paths. They are replayed in CI by
`test/linear_sim_web/operation_replay_test.exs`.

### Compatibility tooling

- `mix linear_sim.dump_schema` — writes the simulator's SDL to
  `priv/linear_sim/schema.graphql` for review/diffing.
- `mix linear_sim.validate_operations` — validates every curated operation
  against the simulator schema via Absinthe (parse + schema validation, no
  execution, no Node dependency). Exits non-zero on any failure.
- Operation replay (`test/linear_sim_web/operation_replay_test.exs`) executes
  each curated operation against its scenario and asserts response paths.
- **Operation capture** (`config :linear_sim, :operation_capture, enabled: true`)
  writes incoming GraphQL documents to `priv/linear/operations/captured/` —
  useful for discovering **agent ad-hoc operations** (e.g. the `MoveIssue`
  mutation a coding agent issues via symphony's `linear_graphql` tool). Promote
  useful captures into the curated corpus.

Validating against the *real Linear reference schema* (a `mix linear.fetch_schema`
that introspects `https://api.linear.app/graphql`) needs a real Linear token and
is left as future work.

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
