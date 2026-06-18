defmodule LinearSim.Compat.ReferenceSchema do
  @moduledoc """
  Indexes a GraphQL introspection result into in-memory maps for fast
  operation validation (docs/linear-sim.md §2, §6).

  The same indexer serves both the committed real Linear snapshot
  (`priv/linear/schema_reference.json`) and the simulator's own live
  introspection (`Absinthe.Schema.introspect/2`) — they share the standard
  introspection JSON shape — so `LinearSim.Compat.OperationValidator` can check a
  curated operation against either with one code path.
  """

  @type type_kind ::
          :object | :input_object | :interface | :union | :enum | :scalar | :unknown

  @typedoc "A raw introspection type reference (`%{\"kind\" => ..., \"name\" => ..., \"ofType\" => ...}`)."
  @type type_ref :: map()

  @type arg :: %{name: String.t(), type_ref: type_ref()}
  @type field :: %{name: String.t(), type_ref: type_ref(), args: %{optional(String.t()) => arg()}}

  @type indexed_type :: %{
          name: String.t(),
          kind: type_kind(),
          fields: %{optional(String.t()) => field()},
          input_fields: %{optional(String.t()) => arg()},
          enum_values: MapSet.t(String.t())
        }

  @type source :: :linear_reference | :simulator | :unknown

  @type t :: %{
          query_root: String.t() | nil,
          mutation_root: String.t() | nil,
          types: %{optional(String.t()) => indexed_type()},
          source: source()
        }

  @default_reference_path Path.join(["priv", "linear", "schema_reference.json"])

  @doc """
  Builds an indexed schema from an introspection map. Accepts either a `data`
  wrapper (`%{"__schema" => ...}`) or a bare `__schema` map.
  """
  @spec from_introspection(map(), source()) :: {:ok, t()} | {:error, term()}
  def from_introspection(introspection, source \\ :unknown)

  def from_introspection(%{"__schema" => schema}, source),
    do: from_introspection(schema, source)

  def from_introspection(%{"types" => types} = schema, source) when is_list(types) do
    indexed =
      types
      |> Enum.map(&index_type/1)
      |> Map.new(fn type -> {type.name, type} end)

    {:ok,
     %{
       query_root: get_in(schema, ["queryType", "name"]),
       mutation_root: get_in(schema, ["mutationType", "name"]),
       types: indexed,
       source: source
     }}
  end

  def from_introspection(_other, _source), do: {:error, :invalid_introspection}

  @doc "Loads and indexes the committed Linear reference snapshot, if present."
  @spec load_reference(keyword()) :: {:ok, t()} | {:error, :not_found | term()}
  def load_reference(opts \\ []) do
    path = Keyword.get(opts, :path, @default_reference_path)

    case File.read(path) do
      {:ok, contents} ->
        contents |> Jason.decode!() |> from_introspection(:linear_reference)

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Indexes the live simulator schema via `Absinthe.Schema.introspect/2`."
  @spec from_simulator(module()) :: {:ok, t()} | {:error, term()}
  def from_simulator(schema_module) do
    case Absinthe.Schema.introspect(schema_module) do
      {:ok, %{data: data}} -> from_introspection(data, :simulator)
      other -> {:error, other}
    end
  end

  @doc "Looks up an indexed type by name."
  @spec lookup_type(t(), String.t() | nil) :: indexed_type() | nil
  def lookup_type(_schema, nil), do: nil
  def lookup_type(schema, name), do: Map.get(schema.types, name)

  @doc "Returns the indexed root type for `:query` or `:mutation`, or `nil`."
  @spec root_type(t(), :query | :mutation) :: indexed_type() | nil
  def root_type(schema, :query), do: lookup_type(schema, schema.query_root)
  def root_type(schema, :mutation), do: lookup_type(schema, schema.mutation_root)

  @doc "Unwraps a type reference's `NON_NULL`/`LIST` wrappers to the underlying named type."
  @spec named_type(type_ref() | nil) :: String.t() | nil
  def named_type(nil), do: nil

  def named_type(%{"ofType" => nil} = ref), do: ref["name"]
  def named_type(%{"ofType" => inner}) when is_map(inner), do: named_type(inner)
  def named_type(%{"name" => name}), do: name

  defp index_type(type) do
    %{
      name: type["name"],
      kind: kind(type["kind"]),
      fields: index_members(type["fields"]),
      input_fields: index_args(type["inputFields"]),
      enum_values: index_enum_values(type["enumValues"])
    }
  end

  defp index_members(nil), do: %{}

  defp index_members(fields) when is_list(fields) do
    Map.new(fields, fn field ->
      {field["name"],
       %{name: field["name"], type_ref: field["type"], args: index_args(field["args"])}}
    end)
  end

  defp index_args(nil), do: %{}

  defp index_args(args) when is_list(args) do
    Map.new(args, fn arg -> {arg["name"], %{name: arg["name"], type_ref: arg["type"]}} end)
  end

  defp index_enum_values(nil), do: MapSet.new()

  defp index_enum_values(values) when is_list(values) do
    MapSet.new(values, & &1["name"])
  end

  defp kind("OBJECT"), do: :object
  defp kind("INPUT_OBJECT"), do: :input_object
  defp kind("INTERFACE"), do: :interface
  defp kind("UNION"), do: :union
  defp kind("ENUM"), do: :enum
  defp kind("SCALAR"), do: :scalar
  defp kind(_), do: :unknown
end
