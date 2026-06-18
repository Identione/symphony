defmodule Mix.Tasks.Linear.FetchSchema do
  @moduledoc """
  Fetches Linear's real GraphQL schema by introspecting
  `https://api.linear.app/graphql` and writes the reference snapshot
  (docs/linear-sim.md §2, §12):

      priv/linear/schema_reference.json      # authoritative introspection result
      priv/linear/schema_reference.graphql   # best-effort SDL, for PR diffs
      priv/linear/schema_metadata.json       # {source, endpoint, fetchedAt, notes}

  Requires `LINEAR_API_KEY`. Run deliberately (not on every CI build) — a schema
  update should be reviewed like a dependency bump:

      LINEAR_API_KEY=... mix linear.fetch_schema
  """
  @shortdoc "Introspect api.linear.app and write the reference schema snapshot"
  use Mix.Task

  alias LinearSim.Compat.SdlPrinter

  @endpoint "https://api.linear.app/graphql"

  @introspection_query """
  query IntrospectionQuery { __schema { queryType { name } mutationType { name } subscriptionType { name } types { ...FullType } directives { name locations args { ...InputValue } } } }
  fragment FullType on __Type { kind name fields(includeDeprecated: true) { name args { ...InputValue } type { ...TypeRef } isDeprecated deprecationReason } inputFields { ...InputValue } interfaces { ...TypeRef } enumValues(includeDeprecated: true) { name isDeprecated deprecationReason } possibleTypes { ...TypeRef } }
  fragment InputValue on __InputValue { name type { ...TypeRef } defaultValue }
  fragment TypeRef on __Type { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name ofType { kind name } } } } } } } }
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case fetch_and_write(token: System.get_env("LINEAR_API_KEY")) do
      {:ok, paths} ->
        Mix.shell().info(
          "Wrote Linear reference schema:\n  #{paths.json}\n  #{paths.sdl}\n  #{paths.metadata}"
        )

      {:error, :no_token} ->
        Mix.raise("LINEAR_API_KEY is not set — cannot introspect #{@endpoint}.")

      {:error, reason} ->
        Mix.raise("Failed to fetch Linear schema: #{inspect(reason)}")
    end
  end

  @typedoc "Absolute paths to the three written artifacts."
  @type paths :: %{json: String.t(), sdl: String.t(), metadata: String.t()}

  @doc """
  Introspects Linear and writes the three reference artifacts. Options:

    * `:token` — the Linear API key (required; `{:error, :no_token}` if blank)
    * `:out_dir` — output directory (default `priv/linear`)
    * `:now` — ISO-8601 timestamp for `fetchedAt` (default: current UTC)
    * `:req_options` — extra options merged into `Req.post/2` (e.g. a `Req.Test` plug)
  """
  @spec fetch_and_write(keyword()) :: {:ok, paths()} | {:error, term()}
  def fetch_and_write(opts) do
    with {:ok, token} <- fetch_token(opts),
         {:ok, schema} <- introspect(token, opts) do
      write_all(schema, opts)
    end
  end

  defp fetch_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :no_token}
    end
  end

  defp introspect(token, opts) do
    req_options =
      [
        json: %{query: @introspection_query},
        headers: [{"authorization", token}],
        receive_timeout: 30_000
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.post(@endpoint, req_options) do
      {:ok, %{body: %{"data" => %{"__schema" => _} = data}}} -> {:ok, data}
      {:ok, %{body: %{"errors" => errors}}} -> {:error, {:graphql_errors, errors}}
      {:ok, %{status: status}} -> {:error, {:unexpected_response, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_all(schema, opts) do
    dir = Keyword.get(opts, :out_dir, Path.join(["priv", "linear"]))
    now = Keyword.get(opts, :now) || DateTime.to_iso8601(DateTime.utc_now())

    paths = %{
      json: Path.join(dir, "schema_reference.json"),
      sdl: Path.join(dir, "schema_reference.graphql"),
      metadata: Path.join(dir, "schema_metadata.json")
    }

    metadata = %{
      "source" => "linear",
      "endpoint" => @endpoint,
      "fetchedAt" => now,
      "notes" => "Reference schema used for simulator compatibility checks"
    }

    File.mkdir_p!(dir)
    File.write!(paths.json, Jason.encode!(schema))
    File.write!(paths.sdl, SdlPrinter.print(schema))
    File.write!(paths.metadata, Jason.encode!(metadata, pretty: true))

    {:ok, paths}
  end
end
