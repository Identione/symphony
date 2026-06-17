defmodule LinearSimWeb.GraphQL.Plugs.RequestLogger do
  @moduledoc """
  Logs incoming GraphQL requests in dev/test so it is easy to see what the
  client is actually sending (docs/linear-sim.md §11). The Authorization header
  is redacted; full secrets are never logged.
  """
  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = Application.get_env(:linear_sim, :graphql_logging, [])

    if Keyword.get(config, :enabled, false) do
      Logger.info("GraphQL request",
        operation_name: get_in(conn.params, ["operationName"]),
        query: maybe_query(conn, config),
        variables: maybe_variables(conn, config),
        authorization: redact_auth(conn),
        current_user_id: context_id(conn, :current_user),
        current_organization_id: context_id(conn, :current_organization)
      )
    end

    conn
  end

  defp maybe_query(conn, config) do
    if Keyword.get(config, :log_query, false), do: get_in(conn.params, ["query"])
  end

  defp maybe_variables(conn, config) do
    if Keyword.get(config, :log_variables, false), do: get_in(conn.params, ["variables"])
  end

  defp redact_auth(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> "Bearer #{String.slice(token, 0, 8)}..."
      [other | _] -> "#{String.slice(other, 0, 8)}..."
      _ -> nil
    end
  end

  defp context_id(conn, key) do
    case get_in(conn.private, [:absinthe, :context, key]) do
      %{id: id} -> id
      _ -> nil
    end
  end
end
