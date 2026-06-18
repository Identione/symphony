defmodule Mix.Tasks.LinearSim.ValidateOperations do
  @moduledoc """
  Validates every curated operation under `priv/linear/operations/curated/`
  against BOTH the simulator schema and the real Linear reference schema
  (docs/linear-sim.md §6), classifying each into the four-quadrant matrix:

      linear ok / sim ok    -> Good
      linear ok / sim fail  -> Simulator missing support   (REQUIRED failure)
      linear fail / sim ok  -> Stale/over-permissive sim    (advisory)
      linear fail / sim fail -> Captured op/vars wrong       (advisory, loud)

  The simulator check runs through Absinthe (parse + validate, no resolution).
  The reference check walks the committed introspection snapshot
  (`priv/linear/schema_reference.json`) via `LinearSim.Compat.OperationValidator`.
  If the snapshot is absent the reference check is skipped with a warning and only
  the simulator gate applies (the snapshot is fetched deliberately, not on every
  build — see `mix linear.fetch_schema`).

  Exits non-zero if any operation is invalid against the simulator. Run:

      mix linear_sim.validate_operations
  """
  @shortdoc "Validate curated operations against the simulator + Linear reference schemas"
  use Mix.Task

  alias LinearSim.Compat.{OperationValidator, ReferenceSchema}

  @schema LinearSimWeb.GraphQL.Schema

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    result = classify_all([])

    if result.reference == :skipped do
      Mix.shell().info("[warn] Linear reference snapshot absent — skipping reference validation.")
    end

    Enum.each(result.results, &report/1)

    if result.required_failures == [] do
      Mix.shell().info(
        "\nAll #{length(result.results)} curated operations validate against the simulator schema."
      )
    else
      Mix.raise(
        "#{length(result.required_failures)} of #{length(result.results)} operations failed simulator validation."
      )
    end
  end

  @type op_result :: %{
          name: String.t(),
          sim_ok?: boolean(),
          sim_errors: [String.t()],
          linear: :ok | :skipped | {:findings, [OperationValidator.finding()]},
          quadrant: quadrant()
        }
  @type quadrant ::
          :good
          | :simulator_missing_support
          | :stale_simulator_schema
          | :captured_op_wrong
          | :unknown
  @type classification :: %{
          reference: :loaded | :skipped,
          results: [op_result()],
          required_failures: [String.t()]
        }

  @doc """
  Validates curated operations against both schemas. Options:

    * `:dirs` — operation directories (default: `priv/linear/operations/curated/*`)
    * `:reference_path` — path to the Linear reference snapshot (default: the committed one)
  """
  @spec classify_all(keyword()) :: classification()
  def classify_all(opts) do
    {reference, reference_status} = load_reference(opts)
    results = opts |> dirs() |> Enum.map(&classify_dir(&1, reference))

    required =
      results |> Enum.filter(&(&1.quadrant == :simulator_missing_support)) |> Enum.map(& &1.name)

    %{reference: reference_status, results: results, required_failures: required}
  end

  @doc "Maps `{linear_ok?, sim_ok?}` to the docs §6 four-quadrant label."
  @spec quadrant(boolean(), boolean()) :: quadrant()
  def quadrant(true, true), do: :good
  def quadrant(true, false), do: :simulator_missing_support
  def quadrant(false, true), do: :stale_simulator_schema
  def quadrant(false, false), do: :captured_op_wrong

  defp load_reference(opts) do
    case ReferenceSchema.load_reference(reference_opts(opts)) do
      {:ok, schema} -> {schema, :loaded}
      {:error, _} -> {nil, :skipped}
    end
  end

  defp reference_opts(opts) do
    case Keyword.fetch(opts, :reference_path) do
      {:ok, path} -> [path: path]
      :error -> []
    end
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

  defp classify_dir(dir, reference) do
    name = Path.basename(dir)
    document = File.read!(Path.join(dir, "operation.graphql"))
    variables = read_variables(Path.join(dir, "variables.json"))
    operation_name = read_operation_name(Path.join(dir, "metadata.json"))

    sim_errors = simulator_errors(document, variables)
    sim_ok? = sim_errors == []

    linear = reference_outcome(reference, document, variables, operation_name)
    linear_ok? = linear in [:ok, :skipped]

    %{
      name: name,
      sim_ok?: sim_ok?,
      sim_errors: sim_errors,
      linear: linear,
      quadrant:
        if(linear == :skipped,
          do: simulator_only_quadrant(sim_ok?),
          else: quadrant(linear_ok?, sim_ok?)
        )
    }
  end

  defp simulator_only_quadrant(true), do: :good
  defp simulator_only_quadrant(false), do: :simulator_missing_support

  defp reference_outcome(nil, _doc, _vars, _op_name), do: :skipped

  defp reference_outcome(reference, document, variables, operation_name) do
    case OperationValidator.validate(document, variables, reference,
           operation_name: operation_name
         ) do
      %{ok?: true} -> :ok
      %{findings: findings} -> {:findings, findings}
    end
  end

  # Parse + validate against the simulator schema WITHOUT resolution, so no
  # resolvers run and no DB is needed. Schema-validity failures collect in
  # execution.validation_errors.
  defp simulator_errors(document, variables) do
    pipeline =
      @schema
      |> Absinthe.Pipeline.for_document(variables: variables)
      |> Absinthe.Pipeline.without(Absinthe.Phase.Document.Execution.Resolution)

    case Absinthe.Pipeline.run(document, pipeline) do
      {:ok, blueprint, _phases} -> validation_errors(blueprint)
      {:error, message, _phases} -> [to_string(message)]
    end
  end

  defp validation_errors(blueprint) do
    blueprint
    |> get_in([Access.key(:execution, %{}), Access.key(:validation_errors, [])])
    |> List.wrap()
    |> Enum.map(& &1.message)
  end

  defp report(%{quadrant: :good, name: name}), do: Mix.shell().info("  [ok]   #{name}")

  defp report(%{quadrant: :simulator_missing_support, name: name, sim_errors: errors}),
    do: Mix.shell().error("  [fail] #{name} (simulator): #{Enum.join(errors, "; ")}")

  defp report(%{quadrant: :stale_simulator_schema, name: name, linear: {:findings, findings}}),
    do:
      Mix.shell().info(
        "  [warn] #{name}: valid in simulator, invalid in Linear: #{inspect(findings)}"
      )

  defp report(%{quadrant: :captured_op_wrong, name: name}),
    do:
      Mix.shell().error(
        "  [fail*] #{name}: invalid in BOTH schemas (advisory — captured op/vars likely stale)"
      )

  defp report(%{name: name}), do: Mix.shell().info("  [ok]   #{name}")

  defp read_variables(path) do
    case File.read(path) do
      {:ok, contents} -> Jason.decode!(contents)
      _ -> %{}
    end
  end

  defp read_operation_name(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> Jason.decode!() |> Map.get("operationName")
      _ -> nil
    end
  end
end
