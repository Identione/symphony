defmodule LinearSimWeb.GraphQL.Types.AttachmentTypes do
  @moduledoc """
  GraphQL types, queries, and mutations for attachments.

  The link* mutations take top-level scalar args (NOT an input object) and error
  on a duplicate `(issue, url)`; `attachmentCreate` takes an input object and
  upserts — both matching live Linear (verified 2026-06-18). `metadata`/`source`
  are exposed for schema fidelity but resolve to constants (the simulator does
  not model Linear's GitHub enrichment).
  """
  use Absinthe.Schema.Notation

  alias LinearSimWeb.GraphQL.Resolvers.AttachmentResolver

  @desc "Git link kind for attachmentLinkGitHubPR (Linear's GitLinkKind)."
  enum :git_link_kind do
    value(:closes, as: "closes", name: "closes")
    value(:contributes, as: "contributes", name: "contributes")
    value(:links, as: "links", name: "links")
  end

  @desc "A link recorded on an issue (Linear's Attachment)."
  object :attachment do
    field :id, non_null(:id)
    field :title, non_null(:string)
    field :subtitle, :string
    field :url, non_null(:string)
    field :source_type, :string
    field :source, :json, resolve: fn _, _, _ -> {:ok, nil} end
    field :metadata, non_null(:json), resolve: fn _, _, _ -> {:ok, %{}} end
    field :archived_at, :datetime, resolve: fn _, _, _ -> {:ok, nil} end
    field :created_at, :datetime, resolve: &AttachmentResolver.created_at/3
    field :updated_at, :datetime
    field :creator, :user, resolve: &AttachmentResolver.creator/3
    field :issue, :issue, resolve: &AttachmentResolver.issue/3
  end

  object :attachment_edge do
    field :cursor, non_null(:string)
    field :node, :attachment
  end

  object :attachment_connection do
    field :nodes, list_of(:attachment)
    field :edges, list_of(:attachment_edge)
    field :page_info, non_null(:page_info)
  end

  @desc "Fields for creating an attachment (Linear's AttachmentCreateInput subset)."
  input_object :attachment_create_input do
    field :id, :string
    field :issue_id, non_null(:string)
    field :url, non_null(:string)
    field :title, non_null(:string)
    field :subtitle, :string
  end

  @desc "Fields for updating an attachment (Linear's AttachmentUpdateInput subset)."
  input_object :attachment_update_input do
    field :title, :string
    field :subtitle, :string
  end

  # --- Queries -----------------------------------------------------------

  object :attachment_queries do
    @desc "Fetch a single attachment by id."
    field :attachment, :attachment do
      arg(:id, non_null(:string))
      resolve(&AttachmentResolver.get/3)
    end

    # Identifier underscores to `attachments_for_url`, which the default adapter
    # maps to/from the external `attachmentsForURL` the client sends.
    @desc "List attachments matching a url (Linear's attachmentsForURL)."
    field :attachments_for_url, :attachment_connection do
      arg(:url, non_null(:string))
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&AttachmentResolver.for_url/3)
    end
  end

  # --- Mutations ---------------------------------------------------------
  #
  # Field identifiers are chosen so the default LanguageConventions adapter maps
  # the exact Linear field names the client sends to these identifiers
  # (e.g. `attachmentLinkGitHubPR` -> `attachment_link_git_hub_pr`). No `name:`
  # override — that would bypass the adapter and break query-time matching.

  object :attachment_mutations do
    @desc "Link a URL to an issue. Errors if the URL is already linked to the issue."
    field :attachment_link_url, :attachment_payload do
      arg(:url, non_null(:string))
      arg(:issue_id, non_null(:string))
      arg(:title, :string)
      arg(:create_as_user, :string)
      arg(:display_icon_url, :string)
      arg(:id, :string)
      resolve(&AttachmentResolver.link_url/3)
    end

    @desc "Link a GitHub PR to an issue. Errors if the URL is already linked."
    field :attachment_link_git_hub_pr, :attachment_payload do
      arg(:url, non_null(:string))
      arg(:issue_id, non_null(:string))
      arg(:title, :string)
      arg(:link_kind, :git_link_kind)
      arg(:create_as_user, :string)
      arg(:display_icon_url, :string)
      arg(:id, :string)
      resolve(&AttachmentResolver.link_github_pr/3)
    end

    @desc "Link a GitHub issue to a Linear issue. Errors if the URL is already linked."
    field :attachment_link_git_hub_issue, :attachment_payload do
      arg(:url, non_null(:string))
      arg(:issue_id, non_null(:string))
      arg(:title, :string)
      arg(:create_as_user, :string)
      arg(:display_icon_url, :string)
      arg(:id, :string)
      resolve(&AttachmentResolver.link_github_issue/3)
    end

    @desc "Create an attachment. Upserts on (issue, url)."
    field :attachment_create, :attachment_payload do
      arg(:input, non_null(:attachment_create_input))
      resolve(&AttachmentResolver.create/3)
    end

    @desc "Update an attachment's title/subtitle."
    field :attachment_update, :attachment_payload do
      arg(:id, non_null(:string))
      arg(:input, non_null(:attachment_update_input))
      resolve(&AttachmentResolver.update/3)
    end

    @desc "Delete an attachment by id."
    field :attachment_delete, :delete_payload do
      arg(:id, non_null(:string))
      resolve(&AttachmentResolver.delete/3)
    end
  end
end
