defmodule LinearSimWeb.GraphQL.Errors do
  @moduledoc """
  Central changeset-to-GraphQL error formatter (docs/linear-sim.md §12). Every
  mutation validation failure passes through here so the error shape stays
  consistent: message + extensions.code + extensions.field.
  """

  @doc "Converts an Ecto changeset into a list of GraphQL error maps."
  @spec changeset_errors(Ecto.Changeset.t()) :: [map()]
  def changeset_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message ->
        %{
          message: "#{field} #{message}",
          extensions: %{code: "VALIDATION_ERROR", field: to_string(field)}
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
