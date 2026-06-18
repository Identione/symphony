defmodule LinearSim.Compat.SdlPrinter do
  @moduledoc """
  Best-effort SDL printer for an introspection result (docs/linear-sim.md §2, §3).

  The committed `schema_reference.json` is authoritative; this SDL exists only so
  schema changes are reviewable in PR diffs. It is intentionally not a complete
  SDL emitter (directives and descriptions are omitted) and nothing validates
  against it.
  """

  @header "# best-effort SDL generated from introspection JSON — JSON is authoritative, directives omitted\n"

  @doc "Renders an introspection map (data wrapper or bare `__schema`) to best-effort SDL."
  @spec print(map()) :: String.t()
  def print(%{"__schema" => schema}), do: print(schema)

  def print(%{"types" => types} = schema) do
    roots = """
    schema {
      query: #{get_in(schema, ["queryType", "name"]) || "Query"}
      mutation: #{get_in(schema, ["mutationType", "name"]) || "null"}
    }
    """

    body =
      types
      |> Enum.reject(&introspection_type?/1)
      |> Enum.sort_by(& &1["name"])
      |> Enum.map(&print_type/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    @header <> "\n" <> roots <> "\n" <> body <> "\n"
  end

  defp introspection_type?(%{"name" => "__" <> _}), do: true
  defp introspection_type?(_), do: false

  defp print_type(%{"kind" => "SCALAR", "name" => name}), do: "scalar #{name}\n"

  defp print_type(%{"kind" => "ENUM", "name" => name, "enumValues" => values}) do
    lines = (values || []) |> Enum.map(&"  #{&1["name"]}") |> Enum.join("\n")
    "enum #{name} {\n#{lines}\n}\n"
  end

  defp print_type(%{"kind" => "INPUT_OBJECT", "name" => name, "inputFields" => fields}) do
    lines =
      (fields || []) |> Enum.map(&"  #{&1["name"]}: #{print_ref(&1["type"])}") |> Enum.join("\n")

    "input #{name} {\n#{lines}\n}\n"
  end

  defp print_type(%{"kind" => "UNION", "name" => name, "possibleTypes" => types}) do
    members = (types || []) |> Enum.map_join(" | ", & &1["name"])
    "union #{name} = #{members}\n"
  end

  defp print_type(%{"kind" => kind, "name" => name, "fields" => fields})
       when kind in ["OBJECT", "INTERFACE"] do
    keyword = if kind == "OBJECT", do: "type", else: "interface"
    lines = (fields || []) |> Enum.map(&print_field/1) |> Enum.join("\n")
    "#{keyword} #{name} {\n#{lines}\n}\n"
  end

  defp print_type(_), do: ""

  defp print_field(%{"name" => name, "args" => args, "type" => type}) do
    "  #{name}#{print_args(args)}: #{print_ref(type)}"
  end

  defp print_args(args) when args in [nil, []], do: ""

  defp print_args(args) do
    "(" <> Enum.map_join(args, ", ", &"#{&1["name"]}: #{print_ref(&1["type"])}") <> ")"
  end

  defp print_ref(%{"kind" => "NON_NULL", "ofType" => inner}), do: print_ref(inner) <> "!"
  defp print_ref(%{"kind" => "LIST", "ofType" => inner}), do: "[" <> print_ref(inner) <> "]"
  defp print_ref(%{"name" => name}) when is_binary(name), do: name
  defp print_ref(_), do: "Unknown"
end
