defmodule LinearSim.OperationCapture do
  @moduledoc """
  Read/manage side of operation capture (docs/linear-sim.md §5). The write side
  lives in `LinearSimWeb.GraphQL.Plugs.CaptureOperations`; this module lets the
  dashboard list captured operations, inspect them, clear them, and promote a
  capture into the curated corpus.

  Each capture is a trio on disk sharing a basename:

      <timestamp>-<OperationName>.graphql
      <timestamp>-<OperationName>.variables.json
      <timestamp>-<OperationName>.metadata.json
  """

  @type capture :: %{
          basename: String.t(),
          operation_name: String.t(),
          kind: :query | :mutation | :unknown,
          captured_at: String.t() | nil,
          query: String.t(),
          variables: String.t() | nil
        }

  @doc "Directory captures are written to (from config)."
  @spec directory() :: String.t()
  def directory do
    :linear_sim
    |> Application.get_env(:operation_capture, [])
    |> Keyword.get(:directory, "priv/linear/operations/captured")
  end

  @doc "Whether automatic capture is currently enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    :linear_sim
    |> Application.get_env(:operation_capture, [])
    |> Keyword.get(:enabled, false)
  end

  @doc "Lists captured operations, most recent first."
  @spec list() :: [capture()]
  def list do
    dir = directory()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".graphql"))
        |> Enum.map(&String.replace_suffix(&1, ".graphql", ""))
        |> Enum.sort(:desc)
        |> Enum.map(&load(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp load(dir, basename) do
    query = read(Path.join(dir, basename <> ".graphql")) || ""
    variables = read(Path.join(dir, basename <> ".variables.json"))
    metadata = read(Path.join(dir, basename <> ".metadata.json"))

    %{
      basename: basename,
      operation_name: operation_name(basename, metadata),
      kind: kind(query),
      captured_at: captured_at(metadata),
      query: query,
      variables: variables
    }
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _} -> nil
    end
  end

  defp operation_name(basename, metadata) do
    with json when is_binary(json) <- metadata,
         {:ok, %{"operationName" => name}} when is_binary(name) <- Jason.decode(json) do
      name
    else
      _ -> basename |> String.split("-", parts: 2) |> List.last()
    end
  end

  defp captured_at(metadata) do
    with json when is_binary(json) <- metadata,
         {:ok, %{"capturedAt" => at}} <- Jason.decode(json) do
      at
    else
      _ -> nil
    end
  end

  defp kind(query) do
    cond do
      Regex.match?(~r/^\s*mutation\b/, query) -> :mutation
      Regex.match?(~r/^\s*(query|\{)/, query) -> :query
      true -> :unknown
    end
  end

  @doc "Deletes all captured operations. Returns the number of trios removed."
  @spec clear() :: non_neg_integer()
  def clear do
    dir = directory()

    case File.ls(dir) do
      {:ok, files} ->
        Enum.each(files, &File.rm(Path.join(dir, &1)))
        files |> Enum.count(&String.ends_with?(&1, ".graphql"))

      {:error, _} ->
        0
    end
  end

  @doc """
  Promotes a captured operation into the curated corpus at
  `priv/linear/operations/curated/<OperationName>/`, copying the `.graphql` and
  `.variables.json` files. Returns `{:ok, dest_dir}` or `{:error, reason}`.
  """
  @spec promote(String.t()) :: {:ok, String.t()} | {:error, term()}
  def promote(basename) do
    dir = directory()
    graphql = Path.join(dir, basename <> ".graphql")

    if File.exists?(graphql) do
      op_name = basename |> String.split("-", parts: 2) |> List.last()
      dest = Path.join(["priv", "linear", "operations", "curated", op_name])
      File.mkdir_p!(dest)
      File.cp!(graphql, Path.join(dest, "operation.graphql"))

      vars = Path.join(dir, basename <> ".variables.json")
      if File.exists?(vars), do: File.cp!(vars, Path.join(dest, "variables.json"))

      {:ok, dest}
    else
      {:error, :not_found}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
