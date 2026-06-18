defmodule LinearSimWeb.GraphQL.UnsupportedRecorder do
  @moduledoc """
  Records GraphQL operations the simulator's schema **cannot handle** to a single
  JSONL file, so missing operations are easy to find and implement (docs/linear-sim.md).

  Unlike `LinearSimWeb.GraphQL.Plugs.CaptureOperations` — which records *every*
  incoming operation for corpus promotion — this only records the failures, and
  only the ones caused by the schema, not by business logic.

  ## Classifier

  Run as `Absinthe.Plug`'s `:before_send` hook, this sees the resolved result.
  Absinthe attaches a `:path` to **resolution** errors (e.g. changeset/not-found
  returned from a resolver) but leaves validation/parse errors (unknown
  field/argument/enum/type) without one. So an error map lacking `:path` means the
  schema couldn't handle that part of the operation — those are what we record.

  Enable via config (on by default; tests point `:path` at a temp file):

      config :linear_sim, :unsupported_operations,
        enabled: true,
        path: "priv/linear/operations/unsupported.jsonl",
        redact_variables: ["accessToken", "apiKey", "password", "token"]

  Entries are deduplicated by signature (operation name + the set of error
  messages) so a polling agent hitting the same gap repeatedly yields one line.
  """
  require Logger

  @default_path "priv/linear/operations/unsupported.jsonl"

  @spec record(Plug.Conn.t(), Absinthe.Blueprint.t()) :: Plug.Conn.t()
  def record(conn, %Absinthe.Blueprint{} = blueprint) do
    config = Application.get_env(:linear_sim, :unsupported_operations, [])

    if Keyword.get(config, :enabled, false) do
      maybe_write(conn, blueprint, config)
    end

    conn
  rescue
    error ->
      # Recording is best-effort instrumentation; never break a response over it.
      Logger.warning("unsupported-operation recording failed: #{Exception.message(error)}")
      conn
  end

  def record(conn, _blueprint), do: conn

  @doc "Whether unsupported-operation recording is currently enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    :linear_sim
    |> Application.get_env(:unsupported_operations, [])
    |> Keyword.get(:enabled, false)
  end

  @doc "Path of the JSONL file unsupported operations are recorded to (from config)."
  @spec path() :: String.t()
  def path do
    :linear_sim
    |> Application.get_env(:unsupported_operations, [])
    |> Keyword.get(:path, @default_path)
  end

  @doc "Number of distinct unsupported operations recorded so far."
  @spec count() :: non_neg_integer()
  def count do
    case File.read(path()) do
      {:ok, contents} -> contents |> String.split("\n", trim: true) |> length()
      {:error, _} -> 0
    end
  end

  @doc """
  Returns the recorded unsupported operations, most recent first, as decoded
  maps (the keys written by `record/2`: capturedAt, operationName, errors,
  query, variables). Malformed lines are skipped.
  """
  @spec list() :: [map()]
  def list do
    case File.read(path()) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, map} -> [map]
            _ -> []
          end
        end)
        |> Enum.reverse()

      {:error, _} ->
        []
    end
  end

  defp maybe_write(conn, blueprint, config) do
    messages =
      blueprint.result
      |> Map.get(:errors, [])
      |> Enum.reject(&Map.has_key?(&1, :path))
      |> Enum.map(&to_string(&1[:message] || &1["message"] || ""))
      |> Enum.reject(&(&1 == ""))

    if messages != [] and write_entry(operation_name(conn, blueprint), messages, conn, config) do
      # A new gap appeared — refresh any open dashboard so its counter updates live.
      LinearSimWeb.Shell.notify_changed()
    end
  end

  # The operation name usually lives in the parsed document, not in conn.params
  # (clients embed it in the query). Fall back to params, then to "anonymous".
  defp operation_name(conn, blueprint) do
    blueprint_name = blueprint |> Map.get(:operations, []) |> Enum.find_value(& &1.name)
    conn.params["operationName"] || blueprint_name || "anonymous"
  end

  # Returns true when a new line was written, false when deduplicated away.
  defp write_entry(op_name, messages, conn, config) do
    path = Keyword.get(config, :path, @default_path)
    signature = {op_name, MapSet.new(messages)}

    if recorded?(path, signature) do
      false
    else
      File.mkdir_p!(Path.dirname(path))

      variables =
        redact(conn.params["variables"] || %{}, Keyword.get(config, :redact_variables, []))

      entry = %{
        capturedAt: DateTime.to_iso8601(DateTime.utc_now()),
        operationName: op_name,
        errors: messages,
        query: conn.params["query"],
        variables: variables
      }

      File.write!(path, Jason.encode!(entry) <> "\n", [:append])
      true
    end
  end

  defp recorded?(path, signature) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line ->
          case Jason.decode(line) do
            {:ok, %{"operationName" => name, "errors" => errors}} ->
              {name, MapSet.new(errors)} == signature

            _ ->
              false
          end
        end)

      {:error, :enoent} ->
        false
    end
  end

  defp redact(variables, keys) when is_map(variables) do
    redact_set = MapSet.new(keys)

    Map.new(variables, fn {k, v} ->
      if MapSet.member?(redact_set, to_string(k)), do: {k, "[REDACTED]"}, else: {k, v}
    end)
  end

  defp redact(variables, _keys), do: variables
end
