defmodule Mix.Tasks.LinearSim.ValidateOperations do
  @moduledoc """
  Validates every curated operation under `priv/linear/operations/curated/`
  against the simulator's GraphQL schema, using Absinthe — no Node dependency
  (docs/linear-sim.md §6).

  This checks that each operation is *legal* against the schema (fields,
  arguments, types). It does not execute the operation — replay tests
  (`test/linear_sim_web/operation_replay_test.exs`) cover behaviour.

  Exits non-zero if any operation fails validation. Run:

      mix linear_sim.validate_operations

  Validating against the real Linear reference schema additionally would require
  a `mix linear.fetch_schema` that introspects `https://api.linear.app/graphql`
  with a real token — out of scope here and documented as future work.
  """
  @shortdoc "Validate curated operations against the simulator schema"
  use Mix.Task

  @schema LinearSimWeb.GraphQL.Schema

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")

    dirs =
      [File.cwd!(), "priv", "linear", "operations", "curated", "*"]
      |> Path.join()
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.sort()

    if dirs == [] do
      Mix.raise("No curated operations found under priv/linear/operations/curated/")
    end

    results = Enum.map(dirs, &validate_dir/1)
    failures = Enum.filter(results, fn {_name, errors} -> errors != [] end)

    Enum.each(results, fn
      {name, []} -> Mix.shell().info("  [ok]   #{name}")
      {name, errors} -> Mix.shell().error("  [fail] #{name}: #{Enum.join(errors, "; ")}")
    end)

    if failures == [] do
      Mix.shell().info(
        "\nAll #{length(results)} curated operations validate against the simulator schema."
      )
    else
      Mix.raise("#{length(failures)} of #{length(results)} operations failed validation.")
    end
  end

  defp validate_dir(dir) do
    name = Path.basename(dir)
    document = File.read!(Path.join(dir, "operation.graphql"))
    variables = read_variables(Path.join(dir, "variables.json"))

    # Parse + validate against the schema WITHOUT the resolution phase, so no
    # resolvers run (and no DB is needed). Schema-validity failures (unknown
    # field/argument/type, etc.) collect in execution.validation_errors.
    pipeline =
      @schema
      |> Absinthe.Pipeline.for_document(variables: variables)
      |> Absinthe.Pipeline.without(Absinthe.Phase.Document.Execution.Resolution)

    case Absinthe.Pipeline.run(document, pipeline) do
      {:ok, blueprint, _phases} ->
        {name, validation_errors(blueprint)}

      {:error, message, _phases} ->
        {name, [to_string(message)]}
    end
  end

  defp validation_errors(blueprint) do
    blueprint
    |> get_in([Access.key(:execution, %{}), Access.key(:validation_errors, [])])
    |> List.wrap()
    |> Enum.map(& &1.message)
  end

  defp read_variables(path) do
    case File.read(path) do
      {:ok, contents} -> Jason.decode!(contents)
      _ -> %{}
    end
  end
end
