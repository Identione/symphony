defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :state_type,
    :branch_name,
    :url,
    :assignee_id,
    # The issue's own GitHub PR URL, read from its Linear attachments (nil when
    # no PR is linked). Feeds the continuation context on agent re-runs.
    :pr_url,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    has_children: false,
    parent_id: nil,
    parent: nil,
    children: [],
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          state_type: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          pr_url: String.t() | nil,
          labels: [String.t()],
          assigned_to_worker: boolean(),
          has_children: boolean(),
          parent_id: String.t() | nil,
          parent: t() | nil,
          children: [t()],
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
