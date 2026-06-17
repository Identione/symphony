defmodule LinearSim.Linear.WebhookDelivery do
  @moduledoc "A record of an outbound simulated Linear webhook delivery attempt."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "webhook_deliveries" do
    field :target_url, :string
    field :event_type, :string
    field :action, :string
    field :payload_json, :string
    field :signature, :string
    field :status, :string
    field :response_status, :integer
    field :response_body, :string
    field :error_reason, :string

    timestamps()
  end

  @doc false
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :id,
      :target_url,
      :event_type,
      :action,
      :payload_json,
      :signature,
      :status,
      :response_status,
      :response_body,
      :error_reason
    ])
    |> validate_required([:id, :target_url, :event_type, :action, :payload_json, :status])
  end
end
