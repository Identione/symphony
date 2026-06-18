defmodule LinearSimWeb.AdminController do
  @moduledoc """
  Out-of-band control plane for the simulator (docs/linear-sim.md §4, §18).
  Kept separate from the simulated Linear GraphQL endpoint.
  """
  use LinearSimWeb, :controller

  alias LinearSim.Repo
  alias LinearSim.Linear.{Comment, Issue, Organization, Team, User, WorkflowState}
  alias LinearSim.Linear.WebhookDelivery
  alias LinearSim.Scenarios
  alias LinearSim.Webhooks.Delivery

  @doc "Resets the simulator to the default scenario."
  def reset(conn, _params) do
    :ok = Scenarios.reset!()
    json(conn, %{ok: true, scenario: "basic_workspace"})
  end

  @doc "Loads a named scenario."
  def scenario(conn, %{"name" => name}) do
    case Scenarios.load(name) do
      :ok ->
        json(conn, %{ok: true, scenario: name})

      {:error, :unknown_scenario} ->
        conn
        |> put_status(:not_found)
        |> json(%{ok: false, error: "Unknown scenario", known: Scenarios.names()})
    end
  end

  @doc """
  Delivers a Linear-style webhook to a target URL and records the attempt.
  Expects `targetUrl`, `secret`, and an `event` object (`type`, `action`, ...).
  """
  def replay_webhook(conn, %{"targetUrl" => target_url, "event" => event} = params) do
    secret = Map.get(params, "secret", "")
    event_type = Map.get(event, "type", "Unknown")
    action = Map.get(event, "action", "unknown")

    case Delivery.deliver(target_url, secret, event) do
      {:ok, delivery} ->
        record_delivery(target_url, event_type, action, delivery)

        conn
        |> put_status(:ok)
        |> json(%{ok: true, delivery: sanitize(delivery)})

      {:error, delivery} ->
        record_delivery(target_url, event_type, action, delivery)

        conn
        |> put_status(:bad_gateway)
        |> json(%{ok: false, delivery: sanitize(delivery)})
    end
  end

  def replay_webhook(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{ok: false, error: "targetUrl and event are required"})
  end

  @doc "Dumps a coarse count of current simulator state for debugging."
  def state(conn, _params) do
    json(conn, %{
      ok: true,
      counts: %{
        organizations: Repo.aggregate(Organization, :count),
        users: Repo.aggregate(User, :count),
        teams: Repo.aggregate(Team, :count),
        workflow_states: Repo.aggregate(WorkflowState, :count),
        issues: Repo.aggregate(Issue, :count),
        comments: Repo.aggregate(Comment, :count),
        webhook_deliveries: Repo.aggregate(WebhookDelivery, :count)
      }
    })
  end

  defp record_delivery(target_url, event_type, action, delivery) do
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

  # The raw response body may be a map (decoded JSON); store a string form.
  defp stringify(nil), do: nil
  defp stringify(body) when is_binary(body), do: body
  defp stringify(body), do: inspect(body)

  # Avoid leaking the full raw body / decoded structures back over the admin API.
  defp sanitize(delivery), do: Map.drop(delivery, [:raw_body, :response_body])
end
