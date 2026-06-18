defmodule LinearSim.Webhooks do
  @moduledoc """
  Webhook replay control plane: signs and delivers a Linear-style webhook to a
  target URL and records the attempt as a `WebhookDelivery` row.

  Shared by the admin REST endpoint (`POST /admin/webhooks/replay`) and the
  dashboard's Webhooks LiveView so both follow exactly one code path.
  """
  alias LinearSim.Linear.WebhookDelivery
  alias LinearSim.Repo
  alias LinearSim.Webhooks.Delivery

  @doc """
  Delivers `event` (a decoded map with `type`/`action`) to `target_url`, signed
  with `secret`, and records the attempt. Returns `{:ok | :error, delivery}`
  where `delivery` is the persisted `WebhookDelivery`.
  """
  @spec replay(String.t(), String.t(), map()) ::
          {:ok, WebhookDelivery.t()} | {:error, WebhookDelivery.t()}
  def replay(target_url, secret, event) when is_binary(target_url) and is_map(event) do
    event_type = Map.get(event, "type", "Unknown")
    action = Map.get(event, "action", "unknown")

    case Delivery.deliver(target_url, secret, event) do
      {:ok, delivery} -> {:ok, record(target_url, event_type, action, delivery)}
      {:error, delivery} -> {:error, record(target_url, event_type, action, delivery)}
    end
  end

  defp record(target_url, event_type, action, delivery) do
    Repo.insert!(%WebhookDelivery{
      id: "delivery_" <> Ecto.UUID.generate(),
      target_url: target_url,
      event_type: event_type,
      action: action,
      payload_json: Map.get(delivery, :raw_body, ""),
      signature: Map.get(delivery, :signature),
      status: to_string(Map.get(delivery, :status)),
      response_status: Map.get(delivery, :response_status),
      response_body: stringify(Map.get(delivery, :response_body)),
      error_reason: Map.get(delivery, :reason)
    })
  end

  defp stringify(nil), do: nil
  defp stringify(body) when is_binary(body), do: body
  defp stringify(body), do: inspect(body)
end
