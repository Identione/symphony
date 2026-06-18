# Compatibility Harness

How the Linear simulator proves it stays faithful to real Linear — and how to use
it. This is the operational companion to the design doc
[`linear-sim.md`](linear-sim.md) ("Compatibility Coverage", §1–14), which covers
the rationale; this file covers how the implemented harness works and what you can
do with it.

## The core idea

The simulator implements only the slice of Linear that [Symphony](../../elixir)
actually uses. The harness's job is to **prove, mechanically, that the slice is
correct** — that every GraphQL operation Symphony sends is legal against *real
Linear*, legal against *the simulator*, and *behaves right* when executed. Three
questions, three layers:

1. **Is the operation legal Linear?** — does it use only fields/arguments/enums
   that really exist in Linear's API.
2. **Is the operation legal against the simulator?** — has the simulator
   implemented those fields.
3. **Does it return the right data?** — replay it against a deterministic scenario
   and assert the response.

A field merely *existing* in the simulator schema is not enough; the response has
to be useful and deterministic under the selected scenario. The harness measures
all three layers and fails the build only where Symphony actually depends on the
answer.

## Architecture

```
mix linear.fetch_schema ──► priv/linear/schema_reference.json   (real Linear, authoritative)
                            priv/linear/schema_reference.graphql (best-effort SDL, for diffs)
                            priv/linear/schema_metadata.json

mix linear_sim.dump_schema ─► priv/linear_sim/schema.graphql + schema.json (the simulator)

                 ┌─────────────────────────────────────────────┐
                 │           lib/linear_sim/compat/             │
   both JSONs ──►│ ReferenceSchema  – index introspection JSON  │
                 │ OperationValidator – walk an op vs an index  │
                 │ Paths / Context  – shared replay helpers     │
                 │ Report           – aggregate to txt + json   │
                 └─────────────────────────────────────────────┘
                        ▲                 ▲                ▲
   validate_operations ─┘   replay_operations ─┘   compatibility_report ─┘
```

### The reference snapshot

`mix linear.fetch_schema` introspects `https://api.linear.app/graphql` with your
`LINEAR_API_KEY` and commits three files under `priv/linear/`:

| File | Role |
| --- | --- |
| `schema_reference.json` | the full introspection result (~1079 types) — **authoritative** |
| `schema_reference.graphql` | best-effort SDL, *only* so PR diffs are readable — nothing validates against it |
| `schema_metadata.json` | `{source, endpoint, fetchedAt, notes}` |

It fails cleanly if `LINEAR_API_KEY` is unset, and the network call is seamed via
`Req.Test` so unit tests never hit the real API. Refresh it **deliberately** —
like a dependency bump — not on every build.

### The validation engine (`lib/linear_sim/compat/`)

This is what makes the "pure Elixir, no Node" approach work against a 1.6 MB
foreign schema:

- **`ReferenceSchema`** reads an introspection JSON and indexes it into fast
  lookup maps (types → fields → args, input fields, enum values). It indexes
  *both* Linear's committed snapshot **and** the simulator's own live
  introspection (`Absinthe.Schema.introspect/2`) — same JSON shape, one indexer,
  two sources.
- **`OperationValidator`** uses Absinthe only to *parse* an operation into an AST,
  then walks its selection sets against an indexed schema in plain Elixir:
  resolve each field to its return type, descend, check arguments, recurse into
  input-object variables, check enum values. It returns structured findings such
  as `{:missing_field, "Issue", "branchName"}`. Because the reference is just
  data we walk — never a schema we compile — validating against all 1079 Linear
  types is effectively free.

> **Why not compile Linear's SDL?** Building a runtime Absinthe schema from
> Linear's ~30k-line SDL via `import_sdl` would pay a large compile cost on every
> build and needs every custom scalar (`DateTime`, `JSON`, `UUID`, …) predefined.
> Walking the introspection JSON sidesteps all of that. See `linear-sim.md` §6.

### The four-quadrant classifier

`mix linear_sim.validate_operations` runs each curated operation through **both**
schemas and labels the outcome:

| Linear | Simulator | Meaning | Build impact |
| :---: | :---: | --- | --- |
| ✅ | ✅ | Good | — |
| ✅ | ❌ | Simulator missing support | **required failure (non-zero exit)** |
| ❌ | ✅ | Stale / over-permissive simulator schema | advisory |
| ❌ | ❌ | Captured op or variables are wrong/outdated | advisory (loud) |

If the reference snapshot is absent (e.g. a fresh clone with no token), the Linear
column is **skipped with a warning** and only the simulator gate applies — so the
build still passes its required check.

### Replay

`mix linear_sim.replay_operations` loads each operation's scenario, runs it through
the real resolvers + SQLite via `Absinthe.run/3` with a context resolved from the
operation's `auth`, and asserts the `expected.paths` from its metadata. It shares
the path-walking (`Compat.Paths`) and token→context (`Compat.Context`) code with
the HTTP replay test (`test/linear_sim_web/operation_replay_test.exs`), so the two
replay surfaces cannot drift. The HTTP test exercises the plug/transport stack; the
task is the `make compat`/CI entrypoint outside ExUnit.

### The report

`mix linear_sim.compatibility_report` aggregates validation (both schemas) +
replay + schema drift into `tmp/linear_sim/compatibility_report.{txt,json}`:

```
Operations:
- Curated operations: 12
- Validate against Linear: 12/12
- Validate against simulator: 12/12
- Replay successfully: 12/12

Missing simulator fields:   ← fields a curated op needs that the sim lacks (annotated by op)
Stale simulator fields:     ← fields in the sim but not in Linear (drift)
Behavioral gaps:            ← from each op's compatibility.knownDifferences
```

### Curated operation metadata

Each operation lives in `priv/linear/operations/curated/<name>/` as
`operation.graphql` + `variables.json` + `metadata.json`. The metadata carries a
`compatibility` block (`linear-sim.md` §11) the report consumes:

```json
{
  "name": "symphony_linear_poll",
  "scenario": "basic_workspace",
  "operationName": "SymphonyLinearPoll",
  "auth": "Bearer user_hakan",
  "compatibility": {
    "level": "behavior",
    "requiresBehavior": ["pagination:first", "filter:project", "filter:state", "sort:createdAt"],
    "knownDifferences": ["hasNextPage is computed from scenario data, not live pagination"]
  },
  "expected": {
    "allowErrors": false,
    "paths": { "data.issues.nodes.0.identifier": "ENG-1" }
  }
}
```

`level` is one of `shape` | `behavior` | `error` | `webhook`.

## Running it

```bash
make compat        # dump_schema → validate_operations → replay_operations → compatibility_report
```

Individual tasks:

| Command | What it does |
| --- | --- |
| `mix linear.fetch_schema` | introspect Linear, write the committed reference snapshot (needs `LINEAR_API_KEY`; **not** part of `make compat`) |
| `mix linear_sim.dump_schema` | write the simulator's `schema.graphql` + `schema.json` |
| `mix linear_sim.validate_operations` | dual-validate the corpus; four-quadrant; non-zero on simulator-missing-support |
| `mix linear_sim.replay_operations` | replay the corpus against scenarios via `Absinthe.run/3` |
| `mix linear_sim.compatibility_report` | write the aggregated report to `tmp/linear_sim/` |

## What you can do with it

**Day-to-day**
- `make compat` is your one-command "is the simulator still faithful?" check.
- Add a field to the simulator schema, run `make compat` → instantly see whether
  it's *stale* (in the sim, not in Linear) or *fills a real gap*.

**When Symphony starts sending a new operation**
- Enable capture (`config :linear_sim, :operation_capture, enabled: true`), run
  Symphony against the simulator, then promote the captured op into
  `priv/linear/operations/curated/`. `validate_operations` immediately tells you
  whether the simulator already supports it or you need to add fields — and the
  exact missing field, if so.

**When Linear changes their API**
- Re-run `mix linear.fetch_schema`, commit the new snapshot, run `make compat`.
  The four-quadrant output shows whether anything Symphony depends on broke. Treat
  schema drift like a reviewed dependency update (`linear-sim.md` §12 checklist).

## Extending it

- **CI gate** — add `make compat` to a CI workflow so the build fails on any
  `simulator_missing_support` operation.
- **Deeper per-level assertions** — use `compatibility.level` to drive checks:
  `behavior` ops could assert pagination/side-effects, `error` ops could assert
  the `rate_limited`/`permission_denied`/`invalid_token` response shapes.
- **Drift-to-todo report** — extend the report to list Linear fields Symphony has
  *started* using that the simulator still lacks, turning discovery into a backlog.
- **Quieter task output** — the replay/report tasks start the app and currently
  emit Repo debug logs in dev; lower the logger level inside those tasks if the
  noise bothers you.

## File map

| Path | Purpose |
| --- | --- |
| `lib/linear_sim/compat/reference_schema.ex` | index introspection JSON (Linear or simulator) |
| `lib/linear_sim/compat/operation_validator.ex` | walk one operation against an indexed schema |
| `lib/linear_sim/compat/paths.ex` | shared response-path assertion logic |
| `lib/linear_sim/compat/context.ex` | token → Absinthe context (also used by the HTTP plug) |
| `lib/linear_sim/compat/sdl_printer.ex` | best-effort introspection-JSON → SDL |
| `lib/linear_sim/compat/report.ex` | aggregate signals → text/JSON report |
| `lib/mix/tasks/linear.fetch_schema.ex` | fetch + commit the Linear reference snapshot |
| `lib/mix/tasks/linear_sim.dump_schema.ex` | dump the simulator schema (SDL + JSON) |
| `lib/mix/tasks/linear_sim.validate_operations.ex` | dual-schema validation + four-quadrant |
| `lib/mix/tasks/linear_sim.replay_operations.ex` | scenario replay via `Absinthe.run/3` |
| `lib/mix/tasks/linear_sim.compatibility_report.ex` | gather + write the report |
| `priv/linear/schema_reference.json` | committed real-Linear reference (authoritative) |
| `priv/linear/operations/curated/<name>/` | the 12 curated operations + metadata |
