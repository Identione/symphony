defmodule LinearSimWeb.GraphQL.Resolvers.CommentResolver do
  @moduledoc "Resolvers for comment fields and the comment mutations."

  alias LinearSim.Linear
  alias LinearSimWeb.GraphQL.Errors

  @doc "Maps the comment's insertion timestamp to Linear's `createdAt`."
  @spec created_at(map(), map(), Absinthe.Resolution.t()) :: {:ok, DateTime.t() | nil}
  def created_at(%{inserted_at: ts}, _args, _resolution), do: {:ok, ts}

  @doc "Resolves a comment's author (nil for system/unattributed comments)."
  @spec user(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def user(%{user: %Ecto.Association.NotLoaded{}}, _args, _resolution), do: {:ok, nil}
  def user(%{user: user}, _args, _resolution), do: {:ok, user}

  @doc "Resolves the `commentCreate` mutation."
  @spec create(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def create(_parent, %{input: %{issue_id: issue_id, body: body}}, resolution) do
    attrs = %{
      id: "comment_" <> Ecto.UUID.generate(),
      issue_id: issue_id,
      body: body,
      user_id: current_user_id(resolution)
    }

    case Linear.create_comment(attrs) do
      {:ok, comment} -> {:ok, %{success: true, comment: comment}}
      {:error, %Ecto.Changeset{} = cs} -> {:error, Errors.changeset_errors(cs)}
    end
  end

  @doc "Resolves the `commentUpdate` mutation."
  @spec update(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def update(_parent, %{id: id, input: %{body: body}}, _resolution) do
    case Linear.update_comment(id, %{body: body}) do
      {:ok, comment} -> {:ok, %{success: true, comment: comment}}
      {:error, :not_found} -> {:error, "Comment not found"}
      {:error, %Ecto.Changeset{} = cs} -> {:error, Errors.changeset_errors(cs)}
    end
  end

  defp current_user_id(%{context: %{current_user: %{id: id}}}), do: id
  defp current_user_id(_), do: nil
end
