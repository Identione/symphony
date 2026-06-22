defmodule LinearSim.Compat.SchemaParityTest do
  @moduledoc """
  Standing fidelity guard for the ENG-10 class of bug: an agent composes a query
  that is valid against *real* Linear, but the operation-driven simulator hadn't
  implemented the field, so it false-negatives with `Cannot query field …`.

  The simulator is intentionally not schema-complete, so we don't assert full
  reference parity. Instead we pin an explicit allowlist of fields that agents are
  known to query on core read types — seeded from the ENG-7/8/9/10 testbed runs
  plus the ENG-10 `Comment.url` regression. Adding a field here is the one-line way
  to make a fidelity obligation explicit and regression-proof.
  """
  use ExUnit.Case, async: true

  alias LinearSim.Compat.ReferenceSchema

  # camelCase GraphQL field names, as they appear in the introspected live schema.
  # Object output fields and input-object fields both count (e.g. IssueFilter.number).
  # Seeded from ENG-7/8/9/10 runs plus gaps recorded in unsupported.jsonl.
  @must_implement %{
    "Comment" => ["id", "body", "url", "createdAt", "user"],
    "Issue" => ["id", "identifier", "title", "url", "branchName", "state"],
    "WorkflowState" => ["id", "name", "type", "position"],
    "User" => ["id", "name", "assignedIssues"],
    "IssueFilter" => ["number"]
  }

  test "core read types implement the fields agents query" do
    {:ok, schema} = ReferenceSchema.from_simulator(LinearSimWeb.GraphQL.Schema)

    missing =
      for {type_name, fields} <- @must_implement,
          live = ReferenceSchema.lookup_type(schema, type_name),
          field <- fields,
          is_nil(live) or
            not (Map.has_key?(live.fields, field) or Map.has_key?(live.input_fields, field)),
          do: "#{type_name}.#{field}"

    assert missing == [],
           "simulator is missing agent-queried fields (implement them, don't suppress " <>
             "the agent): #{inspect(missing)}"
  end
end
