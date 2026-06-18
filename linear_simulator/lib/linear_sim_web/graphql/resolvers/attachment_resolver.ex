defmodule LinearSimWeb.GraphQL.Resolvers.AttachmentResolver do
  @moduledoc """
  Resolvers for attachment fields, queries, and mutations.

  The three `link_*` mutations share one path (`Linear.link_url/1`) and surface a
  duplicate `(issue, url)` as a GraphQL error mirroring prod's
  "This URL has already been linked with <ID>."; `create/3` upserts via
  `Linear.create_attachment/1`.
  """

  alias LinearSim.GraphQL.Connection
  alias LinearSim.Linear
  alias LinearSimWeb.GraphQL.Errors

  @doc "Maps the attachment's insertion timestamp to Linear's `createdAt`."
  @spec created_at(map(), map(), Absinthe.Resolution.t()) :: {:ok, DateTime.t() | nil}
  def created_at(%{inserted_at: ts}, _args, _resolution), do: {:ok, ts}

  @doc "Resolves an attachment's creator (nil when unset/not loaded)."
  @spec creator(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def creator(%{creator: %Ecto.Association.NotLoaded{}}, _args, _resolution), do: {:ok, nil}
  def creator(%{creator: creator}, _args, _resolution), do: {:ok, creator}

  @doc "Resolves an attachment's owning issue."
  @spec issue(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def issue(%{issue: %Ecto.Association.NotLoaded{}}, _args, _resolution), do: {:ok, nil}
  def issue(%{issue: issue}, _args, _resolution), do: {:ok, issue}

  @doc "Resolves an issue's attachments connection."
  @spec attachments(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def attachments(issue, args, _resolution),
    do: {:ok, Connection.from_nodes(Linear.list_attachments(issue.id), args)}

  @doc "Resolves the `attachment(id:)` query."
  @spec get(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def get(_parent, %{id: id}, _resolution), do: {:ok, Linear.get_attachment(id)}

  @doc "Resolves the `attachmentsForURL` query into a connection."
  @spec for_url(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def for_url(_parent, %{url: url} = args, resolution),
    do: {:ok, Connection.from_nodes(Linear.list_attachments_for_url(org(resolution), url), args)}

  @doc "Resolves the `attachmentLinkURL` mutation."
  @spec link_url(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def link_url(_parent, args, _resolution), do: do_link(args, nil)

  @doc "Resolves the `attachmentLinkGitHubPR` mutation."
  @spec link_github_pr(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def link_github_pr(_parent, args, _resolution), do: do_link(args, "github")

  @doc "Resolves the `attachmentLinkGitHubIssue` mutation."
  @spec link_github_issue(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, term()}
  def link_github_issue(_parent, args, _resolution), do: do_link(args, "github")

  @doc "Resolves the `attachmentCreate` mutation (upsert)."
  @spec create(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def create(_parent, %{input: input}, _resolution) do
    input |> Linear.create_attachment() |> to_payload()
  end

  @doc "Resolves the `attachmentUpdate` mutation."
  @spec update(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def update(_parent, %{id: id, input: input}, _resolution) do
    case Linear.update_attachment(id, input) do
      {:error, :not_found} -> {:error, "Attachment not found"}
      result -> to_payload(result)
    end
  end

  @doc "Resolves the `attachmentDelete` mutation."
  @spec delete(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def delete(_parent, %{id: id}, _resolution) do
    case Linear.delete_attachment(id) do
      {:ok, attachment} -> {:ok, %{success: true, entity_id: attachment.id}}
      {:error, :not_found} -> {:error, "Attachment not found"}
    end
  end

  defp do_link(args, source_type) do
    args
    |> Map.take([:url, :issue_id, :title, :id])
    |> Map.put(:source_type, source_type)
    |> Linear.link_url()
    |> case do
      {:error, {:already_linked, identifier}} ->
        {:error, "This URL has already been linked with #{identifier}."}

      result ->
        to_payload(result)
    end
  end

  defp to_payload({:ok, attachment}), do: {:ok, %{success: true, attachment: attachment}}
  defp to_payload({:error, :issue_not_found}), do: {:error, "Issue not found"}
  defp to_payload({:error, %Ecto.Changeset{} = cs}), do: {:error, Errors.changeset_errors(cs)}

  defp org(%{context: %{current_organization: org}}), do: org
  defp org(_), do: nil
end
