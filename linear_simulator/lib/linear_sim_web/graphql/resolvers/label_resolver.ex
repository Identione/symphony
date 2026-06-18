defmodule LinearSimWeb.GraphQL.Resolvers.LabelResolver do
  @moduledoc "Resolvers for the issueLabels query and issueLabelCreate mutation."

  alias LinearSim.GraphQL.Connection
  alias LinearSim.Linear
  alias LinearSimWeb.GraphQL.Errors

  @doc "Resolves the `issueLabels` query into a connection."
  @spec list(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def list(_parent, args, resolution) do
    {:ok, Connection.from_nodes(Linear.list_labels(org(resolution)), args)}
  end

  @doc "Resolves the `issueLabelCreate` mutation."
  @spec create(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def create(_parent, %{input: input}, resolution) do
    case Linear.create_label(org(resolution), input) do
      {:ok, label} -> {:ok, %{success: true, issue_label: label}}
      {:error, %Ecto.Changeset{} = cs} -> {:error, Errors.changeset_errors(cs)}
    end
  end

  defp org(%{context: %{current_organization: org}}), do: org
  defp org(_), do: nil
end
