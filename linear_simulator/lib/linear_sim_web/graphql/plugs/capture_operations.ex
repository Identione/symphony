defmodule LinearSimWeb.GraphQL.Plugs.CaptureOperations do
  @moduledoc """
  Optionally writes incoming GraphQL operations to disk (docs/linear-sim.md §5).

  Disabled by default. Its primary purpose is discovering **agent ad-hoc
  operations** — documents generated at runtime by agents via symphony's
  `linear_graphql` tool (e.g. the observed `MoveIssue` mutation), which are not
  known upfront. Captured operations are raw evidence; promote useful ones into
  `priv/linear/operations/curated/`.

  Enable via config:

      config :linear_sim, :operation_capture,
        enabled: true,
        directory: "priv/linear/operations/captured",
        include_variables: true,
        redact_variables: ["accessToken", "apiKey", "password", "token"]
  """
  @behaviour Plug

  import Plug.Conn
  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = Application.get_env(:linear_sim, :operation_capture, [])

    if Keyword.get(config, :enabled, false) and is_binary(conn.params["query"]) do
      capture(conn, config)
    end

    conn
  end

  defp capture(conn, config) do
    dir = Keyword.get(config, :directory, "priv/linear/operations/captured")
    File.mkdir_p!(dir)

    op_name = conn.params["operationName"] || "anonymous"
    base = Path.join(dir, "#{timestamp()}-#{sanitize(op_name)}")

    File.write!(base <> ".graphql", conn.params["query"])

    if Keyword.get(config, :include_variables, true) do
      variables =
        redact(conn.params["variables"] || %{}, Keyword.get(config, :redact_variables, []))

      File.write!(base <> ".variables.json", Jason.encode!(variables, pretty: true))
    end

    File.write!(
      base <> ".metadata.json",
      Jason.encode!(
        %{
          operationName: op_name,
          capturedAt: DateTime.to_iso8601(DateTime.utc_now()),
          authToken: redact_auth(conn),
          source: "simulator_request_logger"
        },
        pretty: true
      )
    )
  rescue
    error ->
      # Capture is best-effort instrumentation; never break a request over it.
      Logger.warning("operation capture failed: #{Exception.message(error)}")
  end

  defp redact(variables, keys) when is_map(variables) do
    redact_set = MapSet.new(keys)

    Map.new(variables, fn {k, v} ->
      if MapSet.member?(redact_set, to_string(k)), do: {k, "[REDACTED]"}, else: {k, v}
    end)
  end

  defp redact(variables, _keys), do: variables

  defp redact_auth(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> "Bearer #{String.slice(token, 0, 8)}..."
      _ -> nil
    end
  end

  # Filesystem-safe, sortable timestamp (no colons): 20260617T193045Z.
  defp timestamp do
    DateTime.utc_now()
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/\.\d+/, "")
  end

  defp sanitize(name), do: String.replace(name, ~r/[^A-Za-z0-9_]/, "_")
end
