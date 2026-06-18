defmodule Mix.Tasks.LinearSim.ReplayOperations do
  @moduledoc """
  Replays every curated operation against its deterministic scenario outside
  ExUnit (docs/linear-sim.md §7), as the `make compat` / CI entrypoint.

  For each operation it loads the scenario, runs the document via
  `Absinthe.run/3` with a context resolved by `LinearSim.Compat.Context` (mirroring
  the HTTP plug), and asserts `expected.paths` via `LinearSim.Compat.Paths` — the
  same path logic the HTTP replay test uses. Exits non-zero if any operation
  fails (unless its metadata sets `expected.allowErrors`).

      mix linear_sim.replay_operations
  """
  @shortdoc "Replay curated operations against scenarios via Absinthe.run/3"
  use Mix.Task

  alias LinearSim.Compat.{Context, Paths}
  alias LinearSim.Scenarios

  @schema LinearSimWeb.GraphQL.Schema

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    summary = replay_all([])

    Enum.each(summary.failures, fn failure ->
      Mix.shell().error("  [fail] #{failure.name}: #{failure.reason}")
    end)

    if summary.failures == [] do
      Mix.shell().info("Replayed #{summary.ok}/#{summary.total} curated operations successfully.")
    else
      Mix.raise("#{length(summary.failures)} of #{summary.total} operations failed replay.")
    end
  end

  @type failure :: %{name: String.t(), reason: String.t()}
  @type summary :: %{total: non_neg_integer(), ok: non_neg_integer(), failures: [failure()]}

  @doc """
  Replays curated operations and returns a summary. `:dirs` overrides the set of
  operation directories (defaults to `priv/linear/operations/curated/*`).
  """
  @spec replay_all(keyword()) :: summary()
  def replay_all(opts) do
    results = opts |> dirs() |> Enum.map(&replay_dir/1)
    failures = Enum.filter(results, &match?({:error, _}, &1)) |> Enum.map(fn {:error, f} -> f end)

    %{total: length(results), ok: length(results) - length(failures), failures: failures}
  end

  defp dirs(opts) do
    case Keyword.get(opts, :dirs) do
      nil ->
        [File.cwd!(), "priv", "linear", "operations", "curated", "*"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()

      dirs ->
        dirs
    end
  end

  defp replay_dir(dir) do
    name = Path.basename(dir)
    document = File.read!(Path.join(dir, "operation.graphql"))
    variables = read_json(Path.join(dir, "variables.json")) || %{}
    metadata = read_json(Path.join(dir, "metadata.json")) || %{}

    Scenarios.load!(metadata["scenario"] || Scenarios.default())

    case Absinthe.run(document, @schema,
           variables: variables,
           context: Context.from_auth(metadata["auth"]),
           operation_name: metadata["operationName"]
         ) do
      {:ok, result} ->
        evaluate(name, result, metadata)

      {:error, reason} ->
        {:error, %{name: name, reason: "absinthe error: #{inspect(reason)}"}}
    end
  end

  defp evaluate(name, result, metadata) do
    errors = Map.get(result, :errors, [])
    response = %{"data" => Map.get(result, :data), "errors" => errors}
    allow_errors? = get_in(metadata, ["expected", "allowErrors"]) == true
    expected_paths = get_in(metadata, ["expected", "paths"]) || %{}

    cond do
      not allow_errors? and errors != [] ->
        {:error, %{name: name, reason: "unexpected errors: #{inspect(errors)}"}}

      true ->
        case Paths.compare(response, expected_paths) do
          :ok ->
            {:ok, name}

          {:error, mismatches} ->
            {:error, %{name: name, reason: format_mismatches(mismatches)}}
        end
    end
  end

  defp format_mismatches(mismatches) do
    Enum.map_join(mismatches, "; ", fn {path, expected, actual} ->
      "expected #{path} == #{inspect(expected)}, got #{inspect(actual)}"
    end)
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, contents} -> Jason.decode!(contents)
      _ -> nil
    end
  end
end
