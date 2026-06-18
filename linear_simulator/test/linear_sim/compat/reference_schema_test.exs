defmodule LinearSim.Compat.ReferenceSchemaTest do
  use ExUnit.Case, async: true

  alias LinearSim.Compat.ReferenceSchema

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "tiny_reference_schema.json"])

  defp tiny do
    {:ok, schema} =
      @fixture |> File.read!() |> Jason.decode!() |> ReferenceSchema.from_introspection()

    schema
  end

  describe "from_introspection/1" do
    test "indexes object types and their fields" do
      schema = tiny()
      user = ReferenceSchema.lookup_type(schema, "User")

      assert user.kind == :object
      assert Map.has_key?(user.fields, "id")
      assert Map.has_key?(user.fields, "name")
    end

    test "records field arguments" do
      schema = tiny()
      node = ReferenceSchema.lookup_type(schema, "Query").fields["node"]
      assert Map.has_key?(node.args, "id")
    end

    test "indexes input object fields" do
      schema = tiny()
      input = ReferenceSchema.lookup_type(schema, "IssueCreateInput")

      assert input.kind == :input_object
      assert Map.has_key?(input.input_fields, "title")
      assert Map.has_key?(input.input_fields, "priority")
    end

    test "indexes enum values as a MapSet" do
      schema = tiny()
      enum = ReferenceSchema.lookup_type(schema, "IssuePriority")

      assert enum.kind == :enum
      assert MapSet.member?(enum.enum_values, "HIGH")
      refute MapSet.member?(enum.enum_values, "URGENT")
    end

    test "resolves the query and mutation roots" do
      schema = tiny()
      assert ReferenceSchema.root_type(schema, :query).name == "Query"
      assert ReferenceSchema.root_type(schema, :mutation).name == "Mutation"
    end

    test "accepts a bare __schema map as well as a data wrapper" do
      raw = @fixture |> File.read!() |> Jason.decode!()
      {:ok, from_data} = ReferenceSchema.from_introspection(raw)
      {:ok, from_schema} = ReferenceSchema.from_introspection(raw["__schema"])
      assert ReferenceSchema.lookup_type(from_data, "User").name == "User"
      assert ReferenceSchema.lookup_type(from_schema, "User").name == "User"
    end
  end

  describe "named_type/1 helper" do
    test "unwraps non-null and list wrappers to the underlying name" do
      ref = %{
        "kind" => "NON_NULL",
        "name" => nil,
        "ofType" => %{"kind" => "OBJECT", "name" => "User", "ofType" => nil}
      }

      assert ReferenceSchema.named_type(ref) == "User"
    end
  end

  describe "load_reference/0" do
    test "returns {:error, :not_found} when the snapshot file is absent" do
      assert ReferenceSchema.load_reference(path: "priv/linear/does_not_exist.json") ==
               {:error, :not_found}
    end
  end

  describe "from_simulator/1" do
    test "indexes the live simulator schema" do
      {:ok, schema} = ReferenceSchema.from_simulator(LinearSimWeb.GraphQL.Schema)
      issue = ReferenceSchema.lookup_type(schema, "Issue")
      assert issue.kind == :object
      assert Map.has_key?(issue.fields, "branchName")
      assert schema.source == :simulator
    end
  end
end
