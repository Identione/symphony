# Linear GraphQL API Simulator Plan

## 1. Goal

Build a Linear-compatible GraphQL API simulator for local development, integration tests, and deterministic workflow testing.

The simulator should behave like a small, controllable Linear workspace rather than a full clone of Linear.

It should:

* Accept GraphQL requests shaped like Linear API requests.
* Implement only the queries and mutations used by the target client application.
* Store deterministic simulator state in SQLite.
* Provide resettable named scenarios.
* Support Linear-like Relay connection responses.
* Simulate current user and organization context from the `Authorization` header.
* Log incoming GraphQL requests for debugging.
* Map mutation validation failures into structured GraphQL errors.
* Optionally simulate Linear-style webhooks, including valid webhook signatures.

It should not attempt to reimplement the full Linear public API.

---

## 2. Technology Stack

Use:

```text
Elixir + Phoenix + Absinthe + Ecto + SQLite
```

Core responsibilities:

| Component          | Responsibility                                           |
| ------------------ | -------------------------------------------------------- |
| Phoenix            | HTTP server, routing, admin endpoints, test support      |
| Absinthe           | GraphQL schema, resolvers, execution                     |
| Ecto               | Data modeling, migrations, queries, changeset validation |
| SQLite             | Portable local simulator state                           |
| Req or Finch       | Outbound webhook delivery                                |
| Logger / Telemetry | Request tracing and developer observability              |

Recommended dependencies:

```elixir
defp deps do
  [
    {:phoenix, "~> 1.8"},
    {:phoenix_ecto, "~> 4.6"},
    {:ecto_sql, "~> 3.13"},
    {:ecto_sqlite3, "~> 0.24"},
    {:absinthe, "~> 1.7"},
    {:absinthe_plug, "~> 1.5"},
    {:jason, "~> 1.4"},
    {:req, "~> 0.5"}
  ]
end
```

---

## 3. Project Shape

Suggested app name:

```bash
mix phx.new linear_sim --database sqlite3
cd linear_sim
mix ecto.create
```

Suggested folder structure:

```text
lib/
  linear_sim/
    linear/
      organization.ex
      user.ex
      team.ex
      workflow_state.ex
      issue.ex
      comment.ex
      project.ex
      cycle.ex
      label.ex
      webhook_delivery.ex

    linear.ex

    graphql/
      connection.ex

    webhooks/
      signer.ex
      delivery.ex

    scenarios/
      scenarios.ex
      basic_workspace.ex
      empty_workspace.ex
      many_issues.ex
      permission_denied.ex
      rate_limited.ex
      webhook_demo.ex

  linear_sim_web/
    router.ex

    controllers/
      admin_controller.ex
      health_controller.ex

    graphql/
      schema.ex
      errors.ex

      plugs/
        context.ex
        request_logger.ex

      types/
        common_types.ex
        organization_types.ex
        user_types.ex
        team_types.ex
        issue_types.ex
        project_types.ex
        webhook_types.ex

      resolvers/
        viewer_resolver.ex
        organization_resolver.ex
        team_resolver.ex
        issue_resolver.ex
        project_resolver.ex
```

---

## 4. HTTP Endpoints

Expose:

```text
POST /graphql
GET  /health

POST /admin/reset
POST /admin/scenario/:name
POST /admin/webhooks/replay
GET  /admin/state
```

Endpoint responsibilities:

| Endpoint                      | Purpose                                     |
| ----------------------------- | ------------------------------------------- |
| `POST /graphql`               | Linear-compatible GraphQL endpoint          |
| `GET /health`                 | Health check                                |
| `POST /admin/reset`           | Reset simulator to default scenario         |
| `POST /admin/scenario/:name`  | Load a named fixture scenario               |
| `POST /admin/webhooks/replay` | Send a Linear-style webhook to a target app |
| `GET /admin/state`            | Debug current simulator state               |

Admin endpoints should be separate from the simulated Linear GraphQL endpoint.

---

## 5. SQLite Strategy

Use file-backed SQLite by default.

Development config:

```elixir
config :linear_sim, LinearSim.Repo,
  database: Path.expand("../linear_sim_dev.db", Path.dirname(__ENV__.file)),
  pool_size: 5,
  busy_timeout: 5_000
```

Test config:

```elixir
config :linear_sim, LinearSim.Repo,
  database: Path.expand("../linear_sim_test.db", Path.dirname(__ENV__.file)),
  pool_size: 1,
  busy_timeout: 5_000
```

Avoid in-memory SQLite initially because file-backed databases are easier to inspect, debug, reset, and share between Phoenix request processes and test processes.

For tests, prefer explicit state reset over relying on async transactional sandbox behavior.

Recommended test strategy:

```text
1. Use file-backed SQLite.
2. Run tests that mutate simulator state with async: false.
3. Reset scenario state before each integration test or test module.
4. Use pool_size: 1 to reduce SQLite locking issues.
5. Use one database file per external test worker if parallelism is required later.
```

---

## 6. Test Isolation

Every integration test should start from a known scenario.

For v1, use explicit scenario reset instead of transactional sandboxing.

Example `ConnCase` setup:

```elixir
defmodule LinearSimWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use LinearSimWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest

      @endpoint LinearSimWeb.Endpoint
    end
  end

  setup _tags do
    LinearSim.Scenarios.reset!()

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
```

Recommended test rule:

```text
Every test that touches simulator state must either:
- call LinearSim.Scenarios.reset!(), or
- load a named scenario explicitly.
```

Because `Scenarios.reset!()` is in `setup` rather than `setup_all`, and the SQLite file is shared, **all tests that touch simulator state must use `async: false`**. Nothing in `ConnCase` currently enforces this. Add a check or document it prominently — a test module accidentally using `async: true` will produce non-deterministic failures that are difficult to diagnose.

Future async strategy:

```text
For async tests, create one SQLite database file per test worker or test run.
Point the Repo at that file before the simulator process starts.
Delete the file after the test run.
```

Do not optimize for async test execution until the simulator’s behavior is stable.

---

## 7. Data Model

Start with these tables:

```text
organizations
users
api_tokens
teams
workflow_states
issues
issue_relations
comments
projects
cycles
labels
issue_labels
webhook_deliveries
```

Use string primary keys for deterministic fixtures:

```text
org_default
user_hakan
token_hakan
team_eng
state_todo
issue_eng_1
project_roadmap
```

This makes tests and debugging easier than randomized UUIDs.

---

## 8. Foreign Keys and Cascades

SQLite foreign keys can cause reset friction if parent rows are deleted before child rows.

Use `on_delete: :delete_all` for ownership-style relationships where deleting a parent should remove child simulator data.

Example:

```elixir
create table(:teams, primary_key: false) do
  add :id, :string, primary_key: true

  add :organization_id,
      references(:organizations, type: :string, on_delete: :delete_all),
      null: false

  add :key, :string, null: false
  add :name, :string, null: false

  timestamps(type: :utc_datetime_usec)
end
```

```elixir
create table(:issues, primary_key: false) do
  add :id, :string, primary_key: true

  add :organization_id,
      references(:organizations, type: :string, on_delete: :delete_all),
      null: false

  add :team_id,
      references(:teams, type: :string, on_delete: :delete_all),
      null: false

  add :state_id,
      references(:workflow_states, type: :string, on_delete: :nilify_all)

  add :assignee_id,
      references(:users, type: :string, on_delete: :nilify_all)

  add :parent_id,
      references(:issues, type: :string, on_delete: :nilify_all)

  add :identifier, :string, null: false
  add :number, :integer, null: false
  add :title, :string, null: false
  add :description, :text
  add :priority, :integer
  add :branch_name, :string
  add :url, :string
  add :archived_at, :utc_datetime_usec

  timestamps(type: :utc_datetime_usec)
end
```

`branch_name` and `url` are required by symphony's polling query. `parent_id` is needed to answer `children(first: 1)` — symphony uses the presence of children to set `has_children` on the issue struct.

Add a migration for `issue_relations` (needed for symphony's `inverseRelations` blocker check):

```elixir
create table(:issue_relations, primary_key: false) do
  add :id, :string, primary_key: true

  add :issue_id,
      references(:issues, type: :string, on_delete: :delete_all),
      null: false

  add :related_issue_id,
      references(:issues, type: :string, on_delete: :delete_all),
      null: false

  add :type, :string, null: false

  timestamps(type: :utc_datetime_usec)
end
```

Add a migration for `comments` with `resolved_at` (returned by symphony's `SymphonyIssueComments` query):

```elixir
create table(:comments, primary_key: false) do
  add :id, :string, primary_key: true

  add :issue_id,
      references(:issues, type: :string, on_delete: :delete_all),
      null: false

  add :user_id,
      references(:users, type: :string, on_delete: :nilify_all)

  add :body, :text, null: false
  add :resolved_at, :utc_datetime_usec

  timestamps(type: :utc_datetime_usec)
end
```

`projects` needs a `slug_id` field — symphony's polling query filters issues by `project.slugId`:

```elixir
create table(:projects, primary_key: false) do
  add :id, :string, primary_key: true

  add :organization_id,
      references(:organizations, type: :string, on_delete: :delete_all),
      null: false

  add :name, :string, null: false
  add :slug_id, :string, null: false

  timestamps(type: :utc_datetime_usec)
end
```

Recommended policy:

| Relationship            | Suggested `on_delete` |
| ----------------------- | --------------------- |
| Organization → Teams    | `:delete_all`         |
| Organization → Issues   | `:delete_all`         |
| Team → Workflow states  | `:delete_all`         |
| Team → Issues           | `:delete_all`         |
| Issue → Comments        | `:delete_all`         |
| Issue → Issue labels    | `:delete_all`         |
| Issue → Issue relations | `:delete_all`         |
| Issue → Children        | `:nilify_all`         |
| User → Assigned issues  | `:nilify_all`         |
| Workflow state → Issues | `:nilify_all`         |
| Project → Issues        | `:nilify_all`         |
| Cycle → Issues          | `:nilify_all`         |

Still keep reset deletion order bottom-up. Cascades are a safety net, not a replacement for predictable reset logic.

---

## 9. Naming Convention Strategy

Use Absinthe’s default language convention adapter.

Inside Elixir and Absinthe schema definitions, use snake_case:

```elixir
field :created_at, :datetime
field :updated_at, :datetime
field :workflow_state, :workflow_state
```

Externally, GraphQL clients use camelCase:

```graphql
{
  issues {
    nodes {
      createdAt
      updatedAt
      workflowState {
        id
        name
      }
    }
  }
}
```

Project rule:

```text
Internal schema names: snake_case
External GraphQL names: camelCase
Manual `name:` override: only for confirmed exceptions
```

Tests should submit GraphQL documents using camelCase and assert JSON responses using camelCase.

### Naming exceptions

Most names should rely on the default adapter:

```elixir
field :url_key, :string
# external: urlKey

field :api_key, :string
# external: apiKey

field :team_id, :id
# external: teamId
```

If the target client expects casing that the adapter cannot produce, document the exception and use `name:` only for that field.

Example:

```elixir
field :some_internal_name, :string, name: "exactExternalName"
```

Do not add speculative naming overrides. Add them only after observing a real mismatch between the simulator schema and the client’s operation.

---

## 10. Absinthe Schema Configuration

Import custom scalar types:

```elixir
defmodule LinearSimWeb.GraphQL.Schema do
  use Absinthe.Schema

  import_types Absinthe.Type.Custom

  import_types LinearSimWeb.GraphQL.Types.CommonTypes
  import_types LinearSimWeb.GraphQL.Types.UserTypes
  import_types LinearSimWeb.GraphQL.Types.TeamTypes
  import_types LinearSimWeb.GraphQL.Types.IssueTypes

  query do
    import_fields :viewer_queries
    import_fields :organization_queries
    import_fields :team_queries
    import_fields :issue_queries
  end

  mutation do
    import_fields :issue_mutations
    import_fields :comment_mutations
  end
end
```

Use `:datetime` for Linear-like timestamps:

```elixir
field :created_at, :datetime
field :updated_at, :datetime
field :archived_at, :datetime
```

---

## 11. Developer Observability

The simulator should make it easy to inspect what the client application is actually sending.

In dev and test, log:

```text
- GraphQL operation name.
- GraphQL document.
- Variables.
- Redacted Authorization header.
- Resolved simulator token.
- Resolved current user.
- Resolved current organization.
- GraphQL errors.
```

Config:

```elixir
config :linear_sim, :graphql_logging,
  enabled: true,
  log_query: true,
  log_variables: true,
  redact_authorization: true
```

Request logger plug:

```elixir
defmodule LinearSimWeb.GraphQL.Plugs.RequestLogger do
  @behaviour Plug

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    config = Application.get_env(:linear_sim, :graphql_logging, [])

    if Keyword.get(config, :enabled, false) do
      Logger.info("GraphQL request",
        operation_name: get_in(conn.params, ["operationName"]),
        query: maybe_query(conn, config),
        variables: maybe_variables(conn, config),
        authorization: redact_auth(conn),
        current_user_id: get_in(conn.private, [:absinthe, :context, :current_user, :id]),
        current_organization_id: get_in(conn.private, [:absinthe, :context, :current_organization, :id])
      )
    end

    conn
  end

  defp maybe_query(conn, config) do
    if Keyword.get(config, :log_query, false), do: get_in(conn.params, ["query"])
  end

  defp maybe_variables(conn, config) do
    if Keyword.get(config, :log_variables, false), do: get_in(conn.params, ["variables"])
  end

  defp redact_auth(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> "Bearer #{String.slice(token, 0, 8)}..."
      _ -> nil
    end
  end
end
```

Router placement:

```elixir
pipeline :graphql do
  plug :accepts, ["json"]
  plug LinearSimWeb.GraphQL.Plugs.Context
  plug LinearSimWeb.GraphQL.Plugs.RequestLogger
end
```

Start with plain logging. Add Telemetry later if structured metrics or tracing become useful.

### Recording unsupported operations

The simulator only implements the slice of Linear's GraphQL API that clients
actually exercise. When a client sends an operation the schema **cannot handle** —
an unknown field, argument, enum value, or input field — Absinthe's validation
phase rejects it with `HTTP 200 {"errors": [...]}`. `LinearSimWeb.GraphQL.UnsupportedRecorder`
appends those — and only those — to a single JSONL file so the gaps are easy to
find and implement next.

It runs as `Absinthe.Plug`'s `:before_send` hook (the only place that sees the
resolved result):

```elixir
forward "/graphql", Absinthe.Plug,
  schema: LinearSimWeb.GraphQL.Schema,
  before_send: {LinearSimWeb.GraphQL.UnsupportedRecorder, :record}
```

**Classifier.** Absinthe attaches a `:path` to *resolution* errors (changeset /
not-found returned from a resolver — normal API behaviour) but leaves
validation/parse errors without one. An error map lacking `:path` therefore means
the schema couldn't handle that operation — those are what's recorded. Business
errors are correctly ignored.

Entries are deduplicated by signature (operation name + the set of error messages),
so a polling client repeatedly hitting the same gap yields a single line. Each line:

```json
{"capturedAt":"2026-06-18T10:15:00Z","operationName":"GetCycles",
 "errors":["Cannot query field \"cycles\" on type \"Query\"."],
 "query":"query GetCycles {...}","variables":{...}}
```

Config (on by default; the file is gitignored — it's a runtime to-do list, not a
committed artifact):

```elixir
config :linear_sim, :unsupported_operations,
  enabled: true,
  path: "priv/linear/operations/unsupported.jsonl",
  redact_variables: ["accessToken", "apiKey", "password", "token"]
```

The dashboard surfaces the count: a red badge in the top bar (on every page) and
an "Unsupported ops" row on the Overview's *Current state* panel, both driven by
`UnsupportedRecorder.count/0`. Clicking the badge opens a modal that lists every
recorded call as pretty-printed JSON (`UnsupportedRecorder.list/0`). A newly
recorded gap broadcasts a state change (`Shell.notify_changed/0`) so the count —
and the open modal — update live without a page refresh.

To close a gap, read the file, pick an operation, then follow the resolver +
context-function + schema-type extension flow (§16) and add a test.

---

## 12. GraphQL Error Formatting

All mutation validation failures should pass through a shared changeset-to-GraphQL error formatter.

Ecto changeset errors should become GraphQL errors with:

```text
message
extensions.code
extensions.field
```

Initial code:

```text
VALIDATION_ERROR
```

Helper:

```elixir
defmodule LinearSimWeb.GraphQL.Errors do
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message ->
        %{
          message: "#{field} #{message}",
          extensions: %{
            code: "VALIDATION_ERROR",
            field: to_string(field)
          }
        }
      end)
    end)
  end

  defp translate_error({message, opts}) do
    Enum.reduce(opts, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
```

Resolver usage:

```elixir
case Linear.create_issue(input, context) do
  {:ok, issue} ->
    {:ok, %{success: true, issue: issue}}

  {:error, %Ecto.Changeset{} = changeset} ->
    {:error, LinearSimWeb.GraphQL.Errors.changeset_errors(changeset)}
end
```

If Absinthe error shaping needs adjustment later, keep this formatter as the central source of truth and change only the final adapter layer.

---

## 13. Relay-Style Connection Support

Support both simplified and Relay-compatible connection fields.

A connection should expose:

```text
nodes
edges
edges.cursor
edges.node
pageInfo
pageInfo.startCursor
pageInfo.endCursor
pageInfo.hasPreviousPage
pageInfo.hasNextPage
```

Manual lightweight implementation:

```elixir
object :page_info do
  field :start_cursor, :string
  field :end_cursor, :string
  field :has_previous_page, non_null(:boolean)
  field :has_next_page, non_null(:boolean)
end

object :issue_edge do
  field :cursor, non_null(:string)
  field :node, :issue
end

object :issue_connection do
  field :nodes, list_of(:issue)
  field :edges, list_of(:issue_edge)
  field :page_info, non_null(:page_info)
end
```

Connection builder:

```elixir
defmodule LinearSim.GraphQL.Connection do
  def from_nodes(nodes, _args \\ %{}) do
    edges =
      Enum.map(nodes, fn node ->
        %{
          cursor: cursor_for(node),
          node: node
        }
      end)

    %{
      nodes: nodes,
      edges: edges,
      page_info: %{
        start_cursor: edges |> List.first() |> edge_cursor(),
        end_cursor: edges |> List.last() |> edge_cursor(),
        has_previous_page: false,
        has_next_page: false
      }
    }
  end

  defp cursor_for(%{id: id}) do
    Base.encode64("cursor:#{id}")
  end

  defp edge_cursor(nil), do: nil
  defp edge_cursor(%{cursor: cursor}), do: cursor
end
```

For v1, pagination can be partial:

```text
- Accept first, after, last, before.
- Return deterministic cursors.
- Implement hasNextPage accurately only if needed by the client.
- Prefer simple stable behavior over full Relay correctness initially.
```

Note: the current `Connection.from_nodes/2` ignores `first` and `after` and always returns `has_next_page: false`. This is safe for small test datasets — symphony's polling loop stops when it sees `has_next_page: false`, so it will receive all seeded issues in one page. However, `many_issues` scenarios with more than 50 issues will silently truncate without triggering symphony's pagination path. If testing pagination behavior is a goal, `from_nodes/2` must be updated to apply `first`/`after` correctly and return an accurate `has_next_page`.

---

## 14. Authorization Header and Simulator Context

Linear uses bearer tokens to identify the calling user/app. The simulator should parse the `Authorization` header even if it does not cryptographically validate it.

Example convention:

```text
Authorization: Bearer user_hakan
Authorization: Bearer token_hakan
Authorization: Bearer org_default:user_hakan
```

Recommended behavior:

| Header               | Behavior                                             |
| -------------------- | ---------------------------------------------------- |
| Missing              | Use default scenario user                            |
| `Bearer user_hakan`  | Set current user to `user_hakan`                     |
| `Bearer token_hakan` | Look up token in `api_tokens`                        |
| Unknown token        | Return Linear-like auth error, depending on scenario |

Absinthe context plug:

```elixir
defmodule LinearSimWeb.GraphQL.Plugs.Context do
  @behaviour Plug

  import Plug.Conn

  alias LinearSim.Linear

  def init(opts), do: opts

  def call(conn, _opts) do
    context =
      conn
      |> get_req_header("authorization")
      |> parse_authorization()
      |> build_context()

    Absinthe.Plug.put_options(conn, context: context)
  end

  defp parse_authorization(["Bearer " <> token | _]), do: token
  defp parse_authorization(_), do: nil

  defp build_context(nil) do
    %{
      current_user: Linear.default_user(),
      current_organization: Linear.default_organization()
    }
  end

  defp build_context(token) do
    case Linear.resolve_token(token) do
      {:ok, user, organization} ->
        %{
          current_user: user,
          current_organization: organization,
          simulator_token: token
        }

      :error ->
        %{
          current_user: nil,
          current_organization: nil,
          simulator_token: token,
          auth_error: :invalid_token
        }
    end
  end
end
```

Router:

```elixir
pipeline :graphql do
  plug :accepts, ["json"]
  plug LinearSimWeb.GraphQL.Plugs.Context
  plug LinearSimWeb.GraphQL.Plugs.RequestLogger
end

scope "/" do
  pipe_through :graphql

  forward "/graphql", Absinthe.Plug,
    schema: LinearSimWeb.GraphQL.Schema
end
```

The `viewer` resolver should use the Absinthe context:

```elixir
def viewer(_parent, _args, %{context: %{current_user: user}}) when not is_nil(user) do
  {:ok, user}
end

def viewer(_parent, _args, _resolution) do
  {:error, "Authentication required"}
end
```

---

## 15. Core GraphQL Scope

Implement only what the target client actually calls.

The operations below are derived directly from symphony's `linear/client.ex` and `linear/adapter.ex`. Store each as a `.graphql` file under `priv/linear/operations/` so they can be validated against both the Linear reference schema and the simulator schema in CI.

### SymphonyLinearPoll

Issued by the orchestrator on every poll cycle to fetch candidate issues.

```graphql
query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
  issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
    nodes {
      id
      identifier
      title
      description
      priority
      state {
        name
        type
      }
      branchName
      url
      assignee {
        id
      }
      labels {
        nodes {
          name
        }
      }
      children(first: 1) {
        nodes {
          id
        }
      }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue {
            id
            identifier
            state {
              name
            }
          }
        }
      }
      createdAt
      updatedAt
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
```

### SymphonyLinearIssuesById

Issued to refresh specific issues by their internal IDs (used after state changes).

```graphql
query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
  issues(filter: {id: {in: $ids}}, first: $first) {
    nodes {
      id
      identifier
      title
      description
      priority
      state {
        name
        type
      }
      branchName
      url
      assignee {
        id
      }
      labels {
        nodes {
          name
        }
      }
      children(first: 1) {
        nodes {
          id
        }
      }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue {
            id
            identifier
            state {
              name
            }
          }
        }
      }
      createdAt
      updatedAt
    }
  }
}
```

### SymphonyLinearViewer

Issued once at startup when `assignee: "me"` is configured, to resolve the current user's ID.

```graphql
query SymphonyLinearViewer {
  viewer {
    id
  }
}
```

### SymphonyIssueComments

Issued by the deterministic-failure escalation path to find the `## Symphony Workpad` marker comment. Paginated, ordered by `createdAt`.

```graphql
query SymphonyIssueComments($issueId: String!, $first: Int!, $after: String) {
  issue(id: $issueId) {
    comments(first: $first, after: $after, orderBy: createdAt) {
      nodes {
        id
        body
        resolvedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
```

### SymphonyResolveStateId

Issued before every `issueUpdate` state transition to look up the target state's UUID.

```graphql
query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
  issue(id: $issueId) {
    team {
      states(filter: {name: {eq: $stateName}}, first: 1) {
        nodes {
          id
        }
      }
    }
  }
}
```

### Mutations

```graphql
mutation SymphonyCreateComment($issueId: String!, $body: String!) {
  commentCreate(input: {issueId: $issueId, body: $body}) {
    success
  }
}
```

```graphql
mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
  issueUpdate(id: $issueId, input: {stateId: $stateId}) {
    success
  }
}
```

```graphql
mutation SymphonyUpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: {body: $body}) {
    success
  }
}
```

### Attachments (agent-driven)

Not part of Symphony's adapter, but the coding agent records the PR on an issue via
the `linear` skill before finalizing — without this it cannot leave `In Progress`,
so the orchestrator re-claims it forever. Implemented surface (resolvers in
`attachment_resolver.ex`, context in `linear.ex`):

| Field | Semantics |
|---|---|
| `attachmentLinkURL` / `attachmentLinkGitHubPR` / `attachmentLinkGitHubIssue` | Link a URL; **error** on a duplicate `(issue, url)` — `"This URL has already been linked with <ID>."` |
| `attachmentCreate(input:)` | **Upsert** on `(issue, url)` — returns the existing attachment and updates the title |
| `attachmentUpdate(id:, input:)` / `attachmentDelete(id:)` | Edit title/subtitle; delete |
| `issue { attachments }`, `attachment(id:)`, `attachmentsForURL(url:)` | Read links back |

The link*-vs-`attachmentCreate` split (error vs upsert), `issueId` accepting an
identifier or UUID, and `subtitle`/`id` shapes were verified against the live
Linear API (2026-06-18). The simulator stores literal inputs only — it does **not**
replicate Linear's async GitHub enrichment (`sourceType`/`source`/`metadata`
backfill and title override); `metadata` resolves to `{}`, `source` to `null`.

**Deferred** (record, not implemented): the third-party integration links —
`attachmentLinkGitLabMR`, `attachmentLinkSlack`, `attachmentLinkDiscord`,
`attachmentLinkFront`, `attachmentLinkIntercom`, `attachmentLinkJiraIssue`,
`attachmentLinkSalesforce`, `attachmentLinkZendesk`, `attachmentSyncToSlack`,
`attachmentSources`, and `Project.attachments`. Each would be a thin alias on the
same persistence path if ever needed.

> **SDL casing note:** the default `LanguageConventions` adapter maps the exact
> Linear names the client sends (e.g. `attachmentLinkURL`) to snake-case field
> identifiers, so those queries resolve correctly — but the *introspected* SDL
> shows the adapter's re-camelized form (`attachmentLinkUrl`,
> `attachmentLinkGitHubPr`, `attachmentsForUrl`). This is cosmetic: the inbound
> names work, and attachments are not curated operations.

### Discovery queries (agent-driven)

Not part of Symphony's adapter, but coding agents (and MCP-style Linear clients) probe
the workspace with standard Linear root queries to discover teams, users, and workflow
states before acting. The simulator captured these as schema gaps in
`priv/linear/operations/unsupported.jsonl`; the ones below are real Linear fields and are
now implemented (resolvers in `team_resolver.ex` / `user_resolver.ex`, context in
`linear.ex`):

| Field | Semantics |
|---|---|
| `teams(first:, after:)` | List the organization's teams (connection) |
| `team(id:)` | Fetch a team by internal id **or** team key (e.g. `ENG`), mirroring `issue(id:)` |
| `users(first:, after:)` | List the organization's users (connection) |
| `workflowStates(filter:, first:, after:)` | List states across the org's teams; filter by `team.key.eq`, `team.id.eq`, `name.eq` |
| `User.displayName` | Linear's display name; the simulator returns the user's `name` |
| `Comment.user` | The comment's author |
| `WorkflowState.team` | The state's owning team (preloaded by the root `workflowStates` query) |

Intentionally **not** added, because real Linear rejects them too (the client is wrong —
the gap belongs in the caller, not the simulator): `Comment.isResolved` (use `resolvedAt`),
`Team.workflowStates` (use `Team.states`), `User.team` (Linear has no singular `team`),
`issueViaIdentifier` (use `issue(id:)`), and an `identifier` field on `IssueFilter` (use
`issue(id:)` or `number`). These remain in `unsupported.jsonl` as a record of client bugs.

### Filter argument requirements

Symphony's polling query uses a nested filter argument:

```text
issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}})
```

The `issues` query must accept a `filter` input type that supports at minimum:

```text
filter.project.slugId.eq   — String equality match on project slug
filter.state.name.in       — String list match on state name
filter.id.in               — ID list match (used by SymphonyLinearIssuesById)
```

The `issue(id: $issueId)` single-issue lookup (used by `SymphonyResolveStateId` and `SymphonyIssueComments`) must accept both internal UUIDs and ticket keys (e.g. `ENG-1`).

The `team.states` field (used by `SymphonyResolveStateId`) must accept:

```text
filter.name.eq   — String equality match on state name
```

---

## 16. Resolver Strategy

Keep resolvers thin.

Request flow:

```text
Absinthe resolver
  -> LinearSim.Linear context module
  -> Ecto query/change
  -> SQLite
```

Do not add Dataloader in v1.

Use explicit preloads in context functions. This is simpler and sufficient for an operation-driven simulator.

Example:

```elixir
defmodule LinearSimWeb.GraphQL.Resolvers.IssueResolver do
  alias LinearSim.GraphQL.Connection
  alias LinearSim.Linear

  def list(_parent, args, resolution) do
    organization = resolution.context.current_organization

    issues =
      Linear.list_issues(organization, args)

    {:ok, Connection.from_nodes(issues, args)}
  end

  def get(_parent, %{id: id}, resolution) do
    organization = resolution.context.current_organization

    {:ok, Linear.get_issue_by_id_or_identifier(organization, id)}
  end
end
```

Context function:

```elixir
def list_issues(organization, _args) do
  Issue
  |> where([i], i.organization_id == ^organization.id)
  |> preload([:state, :assignee, :team, :labels])
  |> order_by([i], asc: i.inserted_at, asc: i.id)
  |> Repo.all()
end
```

---

## 17. Scenario System

Scenarios are the source of truth for simulator state.

Recommended scenarios:

```text
basic_workspace
empty_workspace
many_issues
archived_issues
permission_denied
invalid_token
rate_limited
webhook_demo
```

Each scenario should:

1. Wipe existing state.
2. Insert deterministic organizations, users, tokens, teams, states, and issues.
3. Return known state.
4. Be safe to run repeatedly.

Scenario modules must not call `Repo.transaction` themselves — the transaction is owned by `Scenarios.load!/1`. If a scenario module wraps its inserts in its own transaction, the result is a nested transaction. Ecto handles SQLite nested transactions via savepoints and will not crash, but it adds confusion about commit boundaries and error rollback scope. Keep scenario modules as plain sequential inserts with no transaction wrapper.

Example:

```elixir
defmodule LinearSim.Scenarios.BasicWorkspace do
  alias LinearSim.Repo
  alias LinearSim.Linear.{Organization, User, ApiToken, Team, WorkflowState, Issue}

  def seed! do
    org =
        Repo.insert!(%Organization{
          id: "org_default",
          name: "Acme",
          url_key: "acme"
        })

      user =
        Repo.insert!(%User{
          id: "user_hakan",
          organization_id: org.id,
          name: "Håkan Niska",
          email: "hakan@example.test"
        })

      Repo.insert!(%ApiToken{
        id: "token_hakan",
        organization_id: org.id,
        user_id: user.id,
        token: "user_hakan",
        label: "Default simulator token"
      })

      team =
        Repo.insert!(%Team{
          id: "team_eng",
          organization_id: org.id,
          key: "ENG",
          name: "Engineering"
        })

      todo =
        Repo.insert!(%WorkflowState{
          id: "state_todo",
          team_id: team.id,
          name: "Todo",
          type: "unstarted",
          # Color mirrors the real Linear workspace (fetched from the API).
          color: "#e2e2e2",
          position: 2
        })

      Repo.insert!(%Issue{
        id: "issue_eng_1",
        organization_id: org.id,
        team_id: team.id,
        state_id: todo.id,
        assignee_id: user.id,
        identifier: "ENG-1",
        number: 1,
        title: "Build Linear simulator",
        description: "Initial simulator issue",
        priority: 2
      })

    :ok
  end
end
```

---

## 18. Admin Reset Endpoint

Admin controller:

```elixir
defmodule LinearSimWeb.AdminController do
  use LinearSimWeb, :controller

  def reset(conn, _params) do
    LinearSim.Scenarios.reset!()
    json(conn, %{ok: true, scenario: "basic_workspace"})
  end

  def scenario(conn, %{"name" => name}) do
    case LinearSim.Scenarios.load(name) do
      :ok ->
        json(conn, %{ok: true, scenario: name})

      {:error, :unknown_scenario} ->
        conn
        |> put_status(:not_found)
        |> json(%{ok: false, error: "Unknown scenario"})
    end
  end
end
```

Scenario dispatcher:

```elixir
defmodule LinearSim.Scenarios do
  alias LinearSim.Repo
  alias LinearSim.Linear.{
    ApiToken,
    Comment,
    Cycle,
    Issue,
    IssueLabel,
    Label,
    Organization,
    Project,
    Team,
    User,
    WebhookDelivery,
    WorkflowState
  }

  def reset! do
    load!("basic_workspace")
  end

  def load(name) do
    case name do
      "basic_workspace" -> load!("basic_workspace")
      "empty_workspace" -> load!("empty_workspace")
      "many_issues" -> load!("many_issues")
      _ -> {:error, :unknown_scenario}
    end
  end

  def load!(name) do
    Repo.transaction(fn ->
      wipe_inside_transaction!()

      case name do
        "basic_workspace" -> LinearSim.Scenarios.BasicWorkspace.seed!()
        "empty_workspace" -> LinearSim.Scenarios.EmptyWorkspace.seed!()
        "many_issues" -> LinearSim.Scenarios.ManyIssues.seed!()
      end
    end)

    :ok
  end

  defp wipe_inside_transaction! do
    Repo.delete_all(WebhookDelivery)
    Repo.delete_all(IssueLabel)
    Repo.delete_all(Comment)
    Repo.delete_all(Issue)
    Repo.delete_all(Label)
    Repo.delete_all(Cycle)
    Repo.delete_all(Project)
    Repo.delete_all(WorkflowState)
    Repo.delete_all(Team)
    Repo.delete_all(ApiToken)
    Repo.delete_all(User)
    Repo.delete_all(Organization)
  end
end
```

---

## 19. Webhook Simulation

Add webhook replay after GraphQL basics work.

Endpoint:

```text
POST /admin/webhooks/replay
```

Request example:

```json
{
  "targetUrl": "http://localhost:4001/linear/webhook",
  "secret": "test_webhook_secret",
  "event": {
    "type": "Issue",
    "action": "create",
    "issueId": "issue_eng_1"
  }
}
```

Important rule:

```text
Serialize once.
Sign that exact binary.
Send that exact binary.
Record the result.
Return a clean admin response.
```

Do not encode a map for signing and then allow the HTTP client to encode it again. Whitespace or key ordering differences would produce an invalid signature.

Signer:

```elixir
defmodule LinearSim.Webhooks.Signer do
  def sign_body!(raw_body, secret) when is_binary(raw_body) and is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, raw_body)
    |> Base.encode16(case: :lower)
  end
end
```

Resilient delivery:

```elixir
defmodule LinearSim.Webhooks.Delivery do
  alias LinearSim.Webhooks.Signer

  def deliver(target_url, secret, payload_map) do
    raw_body = Jason.encode!(payload_map)
    signature = Signer.sign_body!(raw_body, secret)

    result =
      Req.post(
        target_url,
        body: raw_body,
        headers: [
          {"content-type", "application/json"},
          {"linear-signature", signature}
        ],
        receive_timeout: 5_000,
        connect_options: [timeout: 2_000]
      )

    case result do
      {:ok, response} ->
        {:ok,
         %{
           status: :delivered,
           response_status: response.status,
           response_body: response.body,
           signature: signature,
           raw_body: raw_body
         }}

      {:error, reason} ->
        {:error,
         %{
           status: :failed,
           reason: inspect(reason),
           signature: signature,
           raw_body: raw_body
         }}
    end
  rescue
    exception ->
      {:error,
       %{
         status: :failed,
         reason: Exception.message(exception)
       }}
  end
end
```

Admin controller behavior:

```elixir
case LinearSim.Webhooks.Delivery.deliver(target_url, secret, payload) do
  {:ok, delivery} ->
    json(conn, %{ok: true, delivery: delivery})

  {:error, delivery} ->
    conn
    |> put_status(:bad_gateway)
    |> json(%{ok: false, delivery: delivery})
end
```

Webhook delivery table:

```elixir
create table(:webhook_deliveries, primary_key: false) do
  add :id, :string, primary_key: true
  add :target_url, :text, null: false
  add :event_type, :string, null: false
  add :action, :string, null: false
  add :payload_json, :text, null: false
  add :signature, :string
  add :status, :string, null: false
  add :response_status, :integer
  add :response_body, :text
  add :error_reason, :text

  timestamps(type: :utc_datetime_usec)
end
```

---

## 20. Client Introspection and Validation

Because this simulator implements a subset of Linear, some clients may fail if they expect the full Linear schema.

Risks:

```text
- Apollo/Relay/Urql dev tools may run introspection queries.
- Codegen tools may validate operations against a schema file.
- Client operations may reference fields not yet implemented.
```

Recommended strategy:

1. Support normal GraphQL introspection for the implemented subset.
2. Document that the simulator is operation-driven and not schema-complete.
3. Save the real Linear schema snapshot as reference material.
4. Add missing fields as client operations require them.
5. If client tooling needs broader schema validation, optionally maintain a generated schema file for the client that matches its expected operations.

Suggested repo files:

```text
priv/linear/schema_reference.graphql
priv/linear/operations/
  symphony_linear_poll.graphql
  symphony_linear_issues_by_id.graphql
  symphony_linear_viewer.graphql
  symphony_issue_comments.graphql
  symphony_resolve_state_id.graphql
  symphony_create_comment.graphql
  symphony_update_issue_state.graphql
  symphony_update_comment.graphql
```

Do not attempt to fake the entire introspection result in v1. Use Absinthe’s normal introspection first.

### Rate limit scenario

Symphony’s `RateLimit` module inspects two signals to detect rate limiting:

1. HTTP 429 response status.
2. A 200 response whose body contains `errors[].extensions.type == "RATELIMITED"`.

The `rate_limited` scenario must return one of these shapes. Return a 200 with a structured error body to exercise the more common Linear behavior:

```json
{
  "errors": [
    {
      "message": "Rate limit exceeded",
      "extensions": {
        "type": "RATELIMITED",
        "userPresentableMessage": "Rate limit exceeded. Please try again later."
      }
    }
  ]
}
```

Alternatively, return HTTP 429 to exercise the status-code path. Document which the scenario uses.

---

## 21. Linear Compatibility Rules

Implement these early:

| Feature           | Rule                                                                  |
| ----------------- | --------------------------------------------------------------------- |
| IDs               | Use stable string IDs                                                 |
| Auth              | Parse `Authorization: Bearer ...`                                     |
| Current user      | Resolve from token into Absinthe context                              |
| Organizations     | Filter data by current organization                                   |
| Connections       | Support `nodes`, `edges`, and `pageInfo`                              |
| Dates             | Use `:datetime` scalar                                                |
| Naming            | Use Absinthe language conventions; override only confirmed exceptions |
| Errors            | Return GraphQL-shaped errors                                          |
| Validation errors | Map changesets to structured GraphQL errors                           |
| Mutations         | Return `{ success, issue/comment/... }` payloads                      |
| Pagination args   | Accept `first`, `after`, `last`, `before`                             |
| Nullable fields   | Match Linear-like permissive nullability                              |
| Logging           | Log operation name, query, variables, and context in dev/test         |
| Webhooks          | Sign exact raw JSON body with HMAC-SHA256                             |
| Webhook delivery  | Use short timeouts and return clean failures                          |

---

## 22. Testing Strategy

Test at these levels:

### Context tests

```text
Linear.create_issue/2
Linear.update_issue/3
Linear.list_issues/2
Linear.get_issue_by_id_or_identifier/2
Linear.resolve_token/1
```

### GraphQL tests

Send real GraphQL documents to `/graphql`.

Example assertions:

```text
- viewer returns current user based on Authorization header.
- issues returns nodes, edges, and pageInfo.
- issueCreate increments team issue number.
- issueCreate returns structured validation errors for invalid input.
- issueUpdate changes updatedAt.
- invalid token returns expected auth error.
- GraphQL request logging does not leak full secrets.
```

### Scenario tests

Verify:

```text
POST /admin/reset
POST /admin/scenario/basic_workspace
POST /admin/scenario/empty_workspace
POST /admin/scenario/many_issues
```

produce deterministic state.

### Webhook tests

Verify:

```text
- raw body is encoded once.
- Linear-Signature is generated from the exact body.
- target receives the same body that was signed.
- delivery uses timeout settings.
- offline targets return clean 502-style admin responses.
- delivery success and failure are logged.
```

---

## 23. Milestones

### Milestone 1: App Skeleton

* Phoenix app boots.
* SQLite repo configured.
* `/health` works.
* `/graphql` route mounted.
* Empty Absinthe schema responds.

### Milestone 2: Core Persistence

* Migrations for organizations, users, API tokens, teams, workflow states, and issues.
* Foreign keys include appropriate `on_delete` behavior.
* Basic scenario seed works.
* `/admin/reset` works.

### Milestone 3: Auth Context and Observability

* Parse `Authorization` header.
* Resolve current user and organization.
* `viewer` query returns token-specific user.
* Missing/invalid token behavior is scenario-controlled.
* GraphQL request logger records operation name, query, variables, and resolved context.

### Milestone 4: Read GraphQL API

* `viewer`
* `organization`
* `teams`
* `issues`
* `issue(id:)`
* Relay-style connection response shape.

### Milestone 5: Mutations and Error Formatting

* `issueCreate`
* `issueUpdate`
* `commentCreate`
* Deterministic issue numbering.
* Linear-like mutation payloads.
* Ecto changeset errors become structured GraphQL errors.

### Milestone 6: Compatibility Hardening

* DateTime scalar support.
* GraphQL error shaping.
* Pagination argument acceptance.
* Naming convention tests.
* Naming exception registry.
* Subset introspection documentation.

### Milestone 7: Webhooks

* Replay endpoint.
* HMAC-SHA256 `Linear-Signature`.
* Exact raw body signing.
* Short outbound HTTP timeouts.
* Clean failure response when target app is offline.
* Delivery log.

### Milestone 8: Developer Experience

* README.
* Example GraphQL operations.
* Scenario documentation.
* Dockerfile or `mix run --no-halt` instructions.
* Makefile or Mix aliases for reset/seed/test.
* Logging configuration documentation.

---

## 24. Recommended Implementation Order

```text
1. Generate Phoenix app with SQLite.
2. Add Absinthe and mount /graphql.
3. Add migrations with cascade/delete policies.
4. Add BasicWorkspace scenario and /admin/reset.
5. Add explicit test reset setup in ConnCase.
6. Add Authorization header parsing into Absinthe context.
7. Add GraphQL request logging.
8. Implement viewer, organization, teams, and issues queries.
9. Add Relay-style connection shape.
10. Add DateTime scalar fields.
11. Implement issueCreate, issueUpdate, and commentCreate.
12. Add changeset-to-GraphQL error formatting.
13. Add GraphQL tests based on actual client operations.
14. Add webhook replay with exact raw-body signing.
15. Add webhook timeout/error handling and delivery logging.
16. Document subset-schema limitations and introspection behavior.
```

## Compatibility Coverage

> Implemented: see [`compatibility-harness.md`](compatibility-harness.md) for how the harness below works and how to run it (`make compat`).

The simulator is operation-compatible first, not full-schema-complete.

A full Linear clone would require matching Linear’s entire schema, authorization behavior, validation rules, pagination semantics, mutation side effects, rate limits, webhook timing, and error formatting. That is not the goal for v1.

The goal is to make compatibility measurable:

```text
Captured client operations
  -> validate against Linear reference schema
  -> validate against simulator schema
  -> replay against deterministic simulator scenarios
  -> report missing fields, arguments, input types, enum values, and behavior gaps
```

Linear’s API is GraphQL-based and explorable through introspection, so the real Linear schema can be used as the reference contract. Linear supports raw GraphQL requests, which makes it practical to capture and replay actual client operations against the simulator.

---

### 1. Compatibility levels

Define compatibility in layers.

| Level                      | Meaning                                                                                                 | Target                                 |
| -------------------------- | ------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| Operation compatibility    | Every GraphQL operation the target app sends validates and executes against the simulator               | Required for v1                        |
| Shape compatibility        | Types, fields, arguments, inputs, enums, nullability, and response shape match what the client expects  | Required for used operations           |
| Behavioral compatibility   | Business rules, permissions, filters, pagination, side effects, errors, and webhooks behave like Linear | Required only where tests depend on it |
| Full schema compatibility  | The simulator exposes all or nearly all Linear types and fields                                         | Optional later                         |
| Full product compatibility | The simulator behaves like Linear across the entire API                                                 | Not a realistic goal                   |

GraphQL validation is schema-driven: an operation is checked against the schema before execution, including whether fields, arguments, and types are valid.

For this simulator, the definition of “supported” should be:

```text
A GraphQL operation is supported when:
1. It validates against the saved Linear reference schema.
2. It validates against the simulator schema.
3. It executes against a deterministic simulator scenario.
4. Its response shape satisfies the target client.
5. Any known behavioral differences are documented or covered by tests.
```

---

### 2. Store Linear’s reference schema

Keep a snapshot of Linear’s current schema in the repo.

```text
priv/linear/
  schema_reference.graphql
  schema_reference.json
  schema_metadata.json
```

The SDL file is easier to diff in pull requests. The JSON introspection file is easier for automated validation and tooling.

Apollo Studio exposes Linear's public schema and supports downloading it in SDL or JSON format. Alternatively, fetch it directly via a standard GraphQL introspection query against `https://api.linear.app/graphql`.

Example metadata:

```json
{
  "source": "linear",
  "fetchedAt": "2026-06-17T12:00:00Z",
  "endpoint": "https://api.linear.app/graphql",
  "notes": "Reference schema used for simulator compatibility checks"
}
```

Add a Mix task:

```text
mix linear.fetch_schema
```

Responsibilities:

```text
- Fetch or import the current Linear introspection schema.
- Write priv/linear/schema_reference.json.
- Convert/write priv/linear/schema_reference.graphql.
- Write schema_metadata.json with fetch time and source.
- Fail if the schema cannot be parsed.
```

The fetch task does not need to run on every CI build. It can be run manually or on a scheduled job because a schema update should be reviewed deliberately.

---

### 3. Dump the simulator schema

Keep the simulator’s own schema snapshot in the repo or as a CI artifact.

```text
priv/linear_sim/
  schema.graphql
  schema.json
```

Absinthe supports schema introspection using the standard `__schema`, `__type`, and `__typename` fields — no extra configuration needed.

Add a Mix task:

```text
mix linear_sim.dump_schema
```

Responsibilities:

```text
- Run GraphQL introspection against LinearSimWeb.GraphQL.Schema.
- Write priv/linear_sim/schema.json.
- Convert/write priv/linear_sim/schema.graphql.
- Fail if the schema is invalid.
```

The simulator schema should be reviewed in PRs when fields are added or changed.

---

### 4. Capture real client operations

The most important compatibility input is the actual GraphQL documents your app sends.

Store operations here:

```text
priv/linear/operations/
  viewer.graphql
  viewer.variables.json
  teams.graphql
  teams.variables.json
  issues.graphql
  issues.variables.json
  issue_create.graphql
  issue_create.variables.json
  issue_update.graphql
  issue_update.variables.json
  comment_create.graphql
  comment_create.variables.json
```

Each operation should have:

```text
- A stable file name.
- The GraphQL document.
- Example variables.
- The scenario it expects.
- Optional notes about expected behavior.
```

Recommended metadata format:

```json
{
  "name": "issue_create",
  "scenario": "basic_workspace",
  "operationName": "CreateIssue",
  "auth": "Bearer user_hakan",
  "expected": {
    "mustHaveData": true,
    "allowErrors": false
  }
}
```

Suggested layout:

```text
priv/linear/operations/
  issue_create/
    operation.graphql
    variables.json
    metadata.json
```

This scales better than flat files once operations need scenario names, auth headers, and expected results.

---

### 5. Capture operations automatically

There are two distinct operation surfaces with different capture strategies:

**Hardcoded symphony operations** — five queries and three mutations embedded as Elixir string literals in `linear/client.ex` and `linear/adapter.ex`. These are deterministic and known upfront. Extract them directly to `.graphql` files in `priv/linear/operations/curated/` — they are the initial test corpus and require no runtime capture.

**Agent ad-hoc operations** — GraphQL documents generated at runtime by agents via the `linear_graphql` tool. These are non-deterministic; the same agent run may produce different queries. They cannot be captured upfront. The automatic capture flow below is designed primarily for this surface: run symphony against the simulator in a realistic scenario, let the logger write what comes in, then review and promote any novel operations to the curated corpus.

Manual operation files are useful, but the simulator should also help discover missing operations.

Add request tracing that can write incoming GraphQL documents to disk in dev/test:

```elixir
config :linear_sim, :operation_capture,
  enabled: true,
  directory: "priv/linear/operations/captured",
  include_variables: true,
  redact_variables: ["accessToken", "apiKey", "password"]
```

When the simulator receives a GraphQL request, it can write:

```text
priv/linear/operations/captured/
  2026-06-17T120000Z-CreateIssue.graphql
  2026-06-17T120000Z-CreateIssue.variables.json
  2026-06-17T120000Z-CreateIssue.metadata.json
```

Capture metadata:

```json
{
  "operationName": "CreateIssue",
  "capturedAt": "2026-06-17T12:00:00Z",
  "authToken": "Bearer user_ha...",
  "scenario": "basic_workspace",
  "source": "simulator_request_logger"
}
```

Then periodically promote captured operations into the curated test corpus:

```text
priv/linear/operations/curated/
```

Project rule:

```text
Captured operations are raw evidence.
Curated operations are compatibility tests.
```

This avoids polluting CI with duplicate or unstable operations while still making it easy to discover what the client is actually doing.

---

### 6. Validate operations against both schemas

For every curated operation, validate it against:

```text
1. Linear reference schema
2. Simulator schema
```

**Tooling options:**

- `graphql-inspector` (npm) — validates `.graphql` operation files against a schema file; can diff two schemas. Suitable for CI without running the Elixir app.
- Absinthe's built-in validation — validates operations at execution time when the simulator is running; catches type and field errors but requires a live server.
- A custom Mix task using `Absinthe.Schema.lookup_type/2` and `Absinthe.Language` — keeps everything in Elixir and avoids a Node dependency.

Recommended: use `graphql-inspector` for static CI validation (no server needed, fast), and rely on Absinthe's runtime validation as a secondary check during replay tests. This separates "is the operation valid?" from "does the simulator behave correctly?"

This gives a clear failure mode:

| Result                                          | Meaning                                            |
| ----------------------------------------------- | -------------------------------------------------- |
| Valid against Linear, valid against simulator   | Good                                               |
| Valid against Linear, invalid against simulator | Simulator missing support                          |
| Invalid against Linear, valid against simulator | Simulator has stale or overly permissive schema    |
| Invalid against both                            | Captured operation or variables are wrong/outdated |

Add a Mix task:

```text
mix linear_sim.validate_operations
```

Responsibilities:

```text
- Load Linear reference schema.
- Load simulator schema.
- Load every curated operation.
- Validate each operation against both schemas.
- Print failures grouped by missing type, field, argument, enum, input field, or nullability issue.
- Exit non-zero in CI if any required operation fails validation.
```

Example output:

```text
Compatibility validation failed

Operation: issue_details
Schema: simulator

Missing fields:
- Issue.branchName
- Issue.url
- Issue.relations

Missing input fields:
- IssueFilter.archived

Enum mismatches:
- IssueSortInput.updatedAt not implemented
```

---

### 7. Replay operations against deterministic scenarios

Validation proves that the operation is legal. It does not prove that the simulator behaves correctly.

Add replay tests that execute every curated operation against the simulator.

```text
mix linear_sim.replay_operations
```

Replay flow:

```text
for each curated operation:
  1. Load metadata.json.
  2. Reset simulator to metadata.scenario.
  3. Build request with metadata.auth.
  4. POST operation + variables to /graphql.
  5. Assert HTTP 200 unless explicitly testing transport errors.
  6. Assert errors are absent unless metadata.allowErrors is true.
  7. Assert data shape exists.
  8. Optionally assert specific response paths.
```

Example metadata with assertions:

```json
{
  "name": "issue_create",
  "scenario": "basic_workspace",
  "operationName": "CreateIssue",
  "auth": "Bearer user_hakan",
  "expected": {
    "allowErrors": false,
    "paths": {
      "data.issueCreate.success": true,
      "data.issueCreate.issue.identifier": "ENG-2"
    }
  }
}
```

Replay test skeleton:

```elixir
defmodule LinearSimWeb.OperationReplayTest do
  use LinearSimWeb.ConnCase, async: false

  @operation_dirs Path.wildcard("priv/linear/operations/curated/*")

  for operation_dir <- @operation_dirs do
    @operation_dir operation_dir

    test "replays #{Path.basename(operation_dir)}", %{conn: conn} do
      operation = File.read!(Path.join(@operation_dir, "operation.graphql"))
      variables = read_json(Path.join(@operation_dir, "variables.json"))
      metadata = read_json(Path.join(@operation_dir, "metadata.json"))

      LinearSim.Scenarios.load!(metadata["scenario"])

      conn =
        conn
        |> put_req_header("authorization", metadata["auth"])
        |> post("/graphql", %{
          "query" => operation,
          "variables" => variables,
          "operationName" => metadata["operationName"]
        })

      response = json_response(conn, 200)

      unless get_in(metadata, ["expected", "allowErrors"]) do
        assert response["errors"] in [nil, []]
      end

      assert is_map(response["data"])
      assert_expected_paths(response, get_in(metadata, ["expected", "paths"]) || %{})
    end
  end
end
```

---

### 8. Generate a compatibility report

Add a report that summarizes where the simulator stands.

```text
mix linear_sim.compatibility_report
```

The report should include:

```text
- Number of curated operations.
- Number of operations validating against Linear.
- Number of operations validating against simulator.
- Number of operations replaying successfully.
- Missing fields.
- Missing arguments.
- Missing input fields.
- Missing enum values.
- Unimplemented reference fields: real Linear fields absent from simulator types
  that *are* implemented — the proactive counterpart to the curated-operation
  signal above, and the class the ENG-10 `Comment.url` gap belonged to.
- Stale simulator fields not present in Linear reference schema.
- Observed unsupported operations: distinct schema-validation errors real clients
  already hit, surfaced from `UnsupportedRecorder` (the reactive signal).
- Behavioral gaps documented in metadata.
```

Example:

```text
Linear Simulator Compatibility Report

Schemas:
- Linear reference: priv/linear/schema_reference.graphql
- Simulator: priv/linear_sim/schema.graphql

Operations:
- Curated operations: 18
- Validate against Linear: 18/18
- Validate against simulator: 16/18
- Replay successfully: 15/18

Missing simulator fields:
- Issue.branchName used by issue_details
- Issue.url used by issue_details
- ProjectMilestone.name used by project_overview

Unimplemented reference fields (on implemented types):
- Comment.editedAt
- Comment.reactions
- Issue.subscribers

Stale simulator fields:
- RootQueryType.apiVersion

Observed unsupported operations:
- Cannot query field "url" on type "Comment".

Behavioral gaps:
- issues pagination currently returns hasNextPage=false always
- issueUpdate does not yet create webhook delivery events
```

Store reports as CI artifacts:

```text
tmp/linear_sim/compatibility_report.txt
tmp/linear_sim/compatibility_report.json
```

---

### 9. Add CI gates

CI should have two compatibility levels: strict and advisory.

Strict checks:

```text
- Simulator schema compiles.
- Curated operations validate against simulator schema.
- Curated operations replay successfully.
- No unexpected GraphQL errors.
```

Advisory checks:

```text
- Simulator schema diff versus Linear reference.
- Stale simulator fields.
- Unimplemented reference fields on implemented types.
- Missing unused Linear fields.
- Behavior gaps marked as TODO.
```

Recommended CI command:

```bash
mix test
mix linear_sim.dump_schema
mix linear_sim.validate_operations
mix linear_sim.replay_operations
mix linear_sim.compatibility_report
```

CI should fail on:

```text
- A curated operation fails validation against the simulator.
- A curated operation fails replay without allowErrors=true.
- A schema change removes a simulator field used by a curated operation.
```

CI should not fail on:

```text
- Linear has fields that the simulator does not implement and no curated operation uses.
- Advisory schema drift that does not affect captured operations.
```

This keeps the simulator practical rather than turning it into a full Linear reimplementation.

---

### 10. Track unsupported fields intentionally

When the simulator receives an operation with unsupported fields, make the failure useful.

Do not let developers hunt through a generic GraphQL error if you can provide a clear message.

Example developer-facing error:

```json
{
  "errors": [
    {
      "message": "Unsupported Linear simulator field: Issue.branchName",
      "extensions": {
        "code": "SIMULATOR_UNSUPPORTED_FIELD",
        "type": "Issue",
        "field": "branchName",
        "suggestion": "Add Issue.branchName to LinearSimWeb.GraphQL.Types.IssueTypes or remove it from the captured operation."
      }
    }
  ]
}
```

Absinthe’s normal validation will already catch unknown fields. The value of the simulator layer is to make missing compatibility actionable.

---

### 11. Compatibility metadata per operation

Each curated operation should declare its intended compatibility level.

Example:

```json
{
  "name": "issues",
  "scenario": "many_issues",
  "operationName": "Issues",
  "auth": "Bearer user_hakan",
  "compatibility": {
    "level": "shape",
    "requiresBehavior": [
      "pagination:first",
      "filter:team",
      "sort:createdAt"
    ],
    "knownDifferences": [
      "hasPreviousPage is always false in v1"
    ]
  },
  "expected": {
    "allowErrors": false,
    "paths": {
      "data.issues.pageInfo.hasNextPage": true
    }
  }
}
```

Compatibility levels:

```text
shape
  The operation must validate and return the requested response structure.

behavior
  The operation must also match specific Linear-like behavior.

error
  The operation intentionally checks a Linear-like error response.

webhook
  The operation must trigger webhook simulation behavior.
```

---

### 12. Schema drift workflow

When Linear changes its schema:

```text
1. Run mix linear.fetch_schema.
2. Commit the updated schema_reference files.
3. Run mix linear_sim.compatibility_report.
4. Review breaking changes.
5. Update simulator only if captured operations are affected.
6. Add new operations if the client has started using new fields.
```

Schema drift should be reviewed like a dependency update.

Recommended PR checklist:

```text
- Did Linear remove or change fields used by curated operations?
- Did Linear add fields the client now uses?
- Did enum values change?
- Did input objects or required fields change?
- Do replay tests still pass?
- Are known behavioral differences still acceptable?
```

---

### 13. What not to do in v1

Avoid these in the first version:

```text
- Do not attempt full Linear schema coverage.
- Do not stub thousands of fields with meaningless nulls.
- Do not fake full introspection beyond what Absinthe naturally exposes.
- Do not make CI fail because Linear has unused fields missing from the simulator.
- Do not generate behavior from schema alone; schema cannot describe Linear’s full business logic.
```

A field existing in the simulator schema is not enough. The response must be useful for the target client and deterministic under the selected scenario.

---

### 14. Definition of done

Compatibility is done for v1 when:

```text
- Every curated client operation validates against the Linear reference schema.
- Every curated client operation validates against the simulator schema.
- Every curated client operation executes against the simulator.
- All replay tests pass under deterministic scenarios.
- The compatibility report has no missing fields for curated operations.
- The target client can run its Linear integration test suite entirely against the simulator.
- Known behavioral differences are listed in operation metadata or scenario documentation.
```

Compatibility is not done merely because:

```text
- The simulator has the same type names as Linear.
- Introspection works.
- Basic queries return data.
- Unsupported fields return null.
```

The core standard is:

```text
The simulator supports all Linear GraphQL behavior that our application depends on, and we can prove it in CI.
```

---

## 25. Key Design Principle

Build an operation-driven simulator.

Use Linear’s real schema as a reference, but implement only what the target application actually sends.

The simulator should optimize for:

```text
determinism
debuggability
fast reset
realistic enough GraphQL shape
simple local operation
clear failure modes
```

Do not optimize for complete Linear API coverage until a real client operation requires it.
