defmodule LinearSimWeb.GraphQL.Types.CommonTypes do
  @moduledoc "Shared GraphQL types: page info, filter comparators, order enum, payloads."
  use Absinthe.Schema.Notation

  @desc "Relay page info."
  object :page_info do
    field :start_cursor, :string
    field :end_cursor, :string
    field :has_previous_page, non_null(:boolean)
    field :has_next_page, non_null(:boolean)
  end

  @desc "Ordering for paginated connections (Linear's PaginationOrderBy)."
  enum :pagination_order_by do
    # Linear uses camelCase enum literals (createdAt/updatedAt), not the GraphQL
    # SCREAMING_SNAKE convention, so the external names are pinned explicitly.
    value(:created_at, as: :created_at, name: "createdAt")
    value(:updated_at, as: :updated_at, name: "updatedAt")
  end

  @desc "String comparator subset used by symphony filters."
  input_object :string_comparator do
    field :eq, :string
    field :in, list_of(non_null(:string))
  end

  @desc "ID comparator subset used by symphony filters."
  input_object :id_comparator do
    field :eq, :id
    field :in, list_of(non_null(:id))
  end

  @desc "commentCreate / commentUpdate payload."
  object :comment_payload do
    field :success, non_null(:boolean)
    field :comment, :comment
  end

  @desc "issueCreate / issueUpdate payload."
  object :issue_payload do
    field :success, non_null(:boolean)
    field :issue, :issue
  end

  @desc "issueArchive / issueDelete payload (Linear's IssueArchivePayload)."
  object :issue_archive_payload do
    field :success, non_null(:boolean)
    field :entity, :issue
  end

  @desc "issueLabelCreate payload (Linear's IssueLabelPayload)."
  object :issue_label_payload do
    field :success, non_null(:boolean)
    field :issue_label, :label
  end

  @desc "issueRelationCreate payload (Linear's IssueRelationPayload)."
  object :issue_relation_payload do
    field :success, non_null(:boolean)
    field :issue_relation, :issue_relation
  end

  @desc "Generic delete payload (Linear's DeletePayload)."
  object :delete_payload do
    field :success, non_null(:boolean)
    field :entity_id, :id
  end
end
