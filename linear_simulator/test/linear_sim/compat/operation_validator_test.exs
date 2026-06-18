defmodule LinearSim.Compat.OperationValidatorTest do
  use ExUnit.Case, async: true

  alias LinearSim.Compat.{OperationValidator, ReferenceSchema}

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "tiny_reference_schema.json"])

  setup do
    {:ok, schema} =
      @fixture |> File.read!() |> Jason.decode!() |> ReferenceSchema.from_introspection()

    %{schema: schema}
  end

  test "a fully-valid query has no findings", %{schema: schema} do
    result = OperationValidator.validate("query { viewer { id name } }", %{}, schema)
    assert result.ok?
    assert result.findings == []
  end

  test "flags an unknown field on a known type", %{schema: schema} do
    result = OperationValidator.validate("query { viewer { id bogus } }", %{}, schema)
    refute result.ok?
    assert {:missing_field, "User", "bogus"} in result.findings
  end

  test "flags an unknown field on the query root", %{schema: schema} do
    result = OperationValidator.validate("query { nope { id } }", %{}, schema)
    assert {:missing_field, "Query", "nope"} in result.findings
  end

  test "flags an unknown argument", %{schema: schema} do
    doc = "query($x: ID!) { node(bogusArg: $x) { id } }"
    result = OperationValidator.validate(doc, %{"x" => "1"}, schema)
    assert {:missing_argument, "Query", "node", "bogusArg"} in result.findings
  end

  test "flags an unknown input-object field via a variable", %{schema: schema} do
    doc = "mutation($i: IssueCreateInput!) { issueCreate(input: $i) { success } }"
    vars = %{"i" => %{"title" => "x", "bad" => 1}}
    result = OperationValidator.validate(doc, vars, schema)
    assert {:missing_input_field, "IssueCreateInput", "bad"} in result.findings
  end

  test "flags an invalid enum value supplied through a variable", %{schema: schema} do
    doc = "mutation($i: IssueCreateInput!) { issueCreate(input: $i) { success } }"
    vars = %{"i" => %{"title" => "x", "priority" => "URGENT"}}
    result = OperationValidator.validate(doc, vars, schema)
    assert {:missing_enum_value, "IssuePriority", "URGENT"} in result.findings
  end

  test "accepts a valid enum value", %{schema: schema} do
    doc = "mutation($i: IssueCreateInput!) { issueCreate(input: $i) { success } }"
    vars = %{"i" => %{"title" => "x", "priority" => "HIGH"}}
    result = OperationValidator.validate(doc, vars, schema)
    assert result.ok?
  end

  test "selects the operation by name when several are present", %{schema: schema} do
    doc = """
    query A { viewer { id } }
    query B { viewer { bogus } }
    """

    assert OperationValidator.validate(doc, %{}, schema, operation_name: "A").ok?
    refute OperationValidator.validate(doc, %{}, schema, operation_name: "B").ok?
  end

  test "reports a parse error as a finding rather than raising", %{schema: schema} do
    result = OperationValidator.validate("query { viewer {", %{}, schema)
    refute result.ok?
    assert Enum.any?(result.findings, &match?({:parse_error, _}, &1))
  end
end
