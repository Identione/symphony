defmodule LinearSim.Compat.OperationValidator do
  @moduledoc """
  Validates a single GraphQL operation against an indexed schema
  (docs/linear-sim.md §6, §10).

  Parsing is done by Absinthe (`Absinthe.Phase.Parse`); the selection-set walk
  is pure Elixir over `LinearSim.Compat.ReferenceSchema`. This deliberately does
  *not* reimplement full GraphQL validation — it answers the compatibility
  question "do the types/fields/arguments/input-fields/enum values this operation
  references exist in the target schema?", which is exactly the four-quadrant
  check in docs §6. Full simulator-side validation still runs through Absinthe in
  `mix linear_sim.validate_operations`.
  """

  alias LinearSim.Compat.ReferenceSchema

  @type finding ::
          {:parse_error, String.t()}
          | {:no_operation, String.t()}
          | {:missing_type, String.t()}
          | {:missing_field, String.t(), String.t()}
          | {:missing_argument, String.t(), String.t(), String.t()}
          | {:missing_input_field, String.t(), String.t()}
          | {:missing_enum_value, String.t(), String.t()}

  @type result :: %{
          schema: ReferenceSchema.source(),
          findings: [finding()],
          ok?: boolean()
        }

  @doc """
  Validates `document` (with its `variables`) against `schema`. `opts` may carry
  `:operation_name` to disambiguate a multi-operation document.
  """
  @spec validate(String.t(), map(), ReferenceSchema.t(), keyword()) :: result()
  def validate(document, variables, schema, opts \\ []) do
    findings =
      case Absinthe.Phase.Parse.run(document) do
        {:ok, %{input: %Absinthe.Language.Document{definitions: defs}}} ->
          validate_definitions(defs, variables, schema, opts[:operation_name])

        {:error, blueprint} ->
          [{:parse_error, parse_error_message(blueprint)}]
      end

    %{schema: schema.source, findings: Enum.uniq(findings), ok?: findings == []}
  end

  defp validate_definitions(defs, variables, schema, operation_name) do
    operations = Enum.filter(defs, &match?(%Absinthe.Language.OperationDefinition{}, &1))

    case pick_operation(operations, operation_name) do
      nil ->
        [{:no_operation, operation_name || "(anonymous)"}]

      operation ->
        root = ReferenceSchema.root_type(schema, operation_type(operation))

        if root do
          walk_selections(operation.selection_set, root, schema) ++
            walk_variables(operation.variable_definitions, variables, schema)
        else
          [{:missing_type, to_string(operation_type(operation))}]
        end
    end
  end

  defp pick_operation(operations, nil), do: List.first(operations)

  defp pick_operation(operations, name),
    do: Enum.find(operations, &(&1.name == name))

  defp operation_type(%{operation: :mutation}), do: :mutation
  defp operation_type(_), do: :query

  # --- selection set walking -------------------------------------------------

  defp walk_selections(nil, _type, _schema), do: []

  defp walk_selections(%Absinthe.Language.SelectionSet{selections: selections}, type, schema) do
    Enum.flat_map(selections, &walk_selection(&1, type, schema))
  end

  defp walk_selection(%Absinthe.Language.Field{} = field, type, schema) do
    case field_def(type, field.name) do
      nil ->
        [{:missing_field, type.name, field.name}]

      defn ->
        arg_findings(field, type, defn) ++
          descend(field, defn, schema)
    end
  end

  defp walk_selection(%Absinthe.Language.InlineFragment{} = frag, type, schema) do
    target = fragment_type(frag, type, schema)
    walk_selections(frag.selection_set, target, schema)
  end

  # Fragment spreads reference named fragments we don't resolve here; curated
  # operations don't use them. Skip rather than false-flag.
  defp walk_selection(_other, _type, _schema), do: []

  defp field_def(%{fields: fields}, name), do: Map.get(fields, name)

  defp arg_findings(field, type, defn) do
    Enum.flat_map(field.arguments, fn arg ->
      if Map.has_key?(defn.args, arg.name),
        do: [],
        else: [{:missing_argument, type.name, field.name, arg.name}]
    end)
  end

  defp descend(field, defn, schema) do
    next_name = ReferenceSchema.named_type(defn.type_ref)
    next_type = ReferenceSchema.lookup_type(schema, next_name)

    cond do
      field.selection_set == nil -> []
      next_type == nil -> [{:missing_type, to_string(next_name)}]
      true -> walk_selections(field.selection_set, next_type, schema)
    end
  end

  defp fragment_type(%{type_condition: %Absinthe.Language.NamedType{name: name}}, _type, schema),
    do: ReferenceSchema.lookup_type(schema, name) || %{name: name, fields: %{}}

  defp fragment_type(_frag, type, _schema), do: type

  # --- variable / input-object validation ------------------------------------

  defp walk_variables(nil, _variables, _schema), do: []

  defp walk_variables(definitions, variables, schema) do
    Enum.flat_map(definitions, fn definition ->
      name = definition.variable.name
      type_name = named_type_from_ast(definition.type)
      value = Map.get(variables || %{}, name)
      validate_input_value(type_name, value, schema)
    end)
  end

  defp validate_input_value(_type_name, nil, _schema), do: []

  defp validate_input_value(type_name, values, schema) when is_list(values),
    do: Enum.flat_map(values, &validate_input_value(type_name, &1, schema))

  defp validate_input_value(type_name, value, schema) do
    case ReferenceSchema.lookup_type(schema, type_name) do
      %{kind: :input_object, input_fields: input_fields} when is_map(value) ->
        Enum.flat_map(value, fn {key, child} ->
          case Map.get(input_fields, key) do
            nil ->
              [{:missing_input_field, type_name, key}]

            arg ->
              validate_input_value(ReferenceSchema.named_type(arg.type_ref), child, schema)
          end
        end)

      %{kind: :enum, enum_values: enum_values} when is_binary(value) ->
        if MapSet.member?(enum_values, value),
          do: [],
          else: [{:missing_enum_value, type_name, value}]

      _ ->
        []
    end
  end

  defp named_type_from_ast(%Absinthe.Language.NonNullType{type: inner}),
    do: named_type_from_ast(inner)

  defp named_type_from_ast(%Absinthe.Language.ListType{type: inner}),
    do: named_type_from_ast(inner)

  defp named_type_from_ast(%Absinthe.Language.NamedType{name: name}), do: name
  defp named_type_from_ast(_), do: nil

  defp parse_error_message(%{execution: %{validation_errors: [%{message: message} | _]}}),
    do: message

  defp parse_error_message(_), do: "parse error"
end
