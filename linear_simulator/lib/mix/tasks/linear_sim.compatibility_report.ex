defmodule Mix.Tasks.LinearSim.CompatibilityReport do
  @moduledoc """
  Aggregates the compatibility signals — dual-schema validation, replay, and
  schema drift — into `tmp/linear_sim/compatibility_report.{txt,json}`
  (docs/linear-sim.md §8).

      mix linear_sim.compatibility_report

  Run after `mix linear_sim.dump_schema` so the simulator schema artifact is
  fresh. The Linear reference column reads the committed snapshot (or reports
  `skipped` if absent — see `mix linear.fetch_schema`).
  """
  @shortdoc "Write the simulator/Linear compatibility report to tmp/linear_sim/"
  use Mix.Task

  alias LinearSim.Compat.{OperationValidator, ReferenceSchema, Report}
  alias Mix.Tasks.LinearSim.{ReplayOperations, ValidateOperations}

  @schema LinearSimWeb.GraphQL.Schema

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    {:ok, paths, _report} = write([])
    Mix.shell().info("Wrote compatibility report:\n  #{paths.txt}\n  #{paths.json}")
  end

  @type paths :: %{txt: String.t(), json: String.t()}

  @doc "Builds the report and writes both artifacts. `:out_dir` defaults to `tmp/linear_sim`."
  @spec write(keyword()) :: {:ok, paths(), Report.t()}
  def write(opts) do
    report = build_report(opts)
    dir = Keyword.get(opts, :out_dir, Path.join(["tmp", "linear_sim"]))

    paths = %{
      txt: Path.join(dir, "compatibility_report.txt"),
      json: Path.join(dir, "compatibility_report.json")
    }

    File.mkdir_p!(dir)
    File.write!(paths.txt, Report.to_text(report))
    File.write!(paths.json, Report.to_json(report))

    {:ok, paths, report}
  end

  @doc "Gathers all signals and returns the built report struct."
  @spec build_report(keyword()) :: Report.t()
  def build_report(opts) do
    validate = ValidateOperations.classify_all(validate_opts(opts))
    replay = ReplayOperations.replay_all(replay_opts(opts))
    {:ok, simulator} = ReferenceSchema.from_simulator(@schema)
    reference = load_reference(validate.reference, opts)

    Report.build(%{
      curated_count: length(validate.results),
      reference: validate.reference,
      validate_results:
        Enum.map(validate.results, fn r ->
          %{sim_ok?: r.sim_ok?, linear_ok?: r.linear in [:ok, :skipped]}
        end),
      replay: %{total: replay.total, ok: replay.ok},
      missing_simulator_fields: missing_simulator_fields(dirs(opts), simulator),
      stale_simulator_fields: stale_simulator_fields(simulator, reference),
      behavioral_gaps: behavioral_gaps(dirs(opts))
    })
  end

  defp validate_opts(opts), do: Keyword.take(opts, [:dirs, :reference_path])
  defp replay_opts(opts), do: Keyword.take(opts, [:dirs])

  defp load_reference(:skipped, _opts), do: nil

  defp load_reference(:loaded, opts) do
    case ReferenceSchema.load_reference(Keyword.take(opts, [:path])) do
      {:ok, schema} -> schema
      _ -> nil
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

  # Structured missing-field findings from validating each curated op against the
  # simulator's own schema, annotated by the operation that needs them.
  defp missing_simulator_fields(dirs, simulator) do
    Enum.flat_map(dirs, fn dir ->
      name = Path.basename(dir)
      document = File.read!(Path.join(dir, "operation.graphql"))
      variables = read_json(Path.join(dir, "variables.json")) || %{}
      operation_name = dir |> read_metadata() |> Map.get("operationName")

      OperationValidator.validate(document, variables, simulator, operation_name: operation_name).findings
      |> Enum.flat_map(&describe_finding(&1, name))
    end)
  end

  defp describe_finding({:missing_field, type, field}, op), do: ["#{type}.#{field} used by #{op}"]

  defp describe_finding({:missing_input_field, type, field}, op),
    do: ["#{type}.#{field} used by #{op}"]

  defp describe_finding({:missing_enum_value, type, value}, op),
    do: ["#{type}.#{value} used by #{op}"]

  defp describe_finding(_other, _op), do: []

  # Simulator object/input fields absent from the Linear reference (advisory drift).
  defp stale_simulator_fields(_simulator, nil), do: []

  defp stale_simulator_fields(simulator, reference) do
    simulator.types
    |> Enum.reject(fn {type_name, _} -> String.starts_with?(type_name, "__") end)
    |> Enum.flat_map(fn {type_name, sim_type} ->
      case ReferenceSchema.lookup_type(reference, type_name) do
        nil -> []
        ref_type -> stale_members(type_name, sim_type, ref_type)
      end
    end)
    |> Enum.sort()
  end

  defp stale_members(type_name, sim_type, ref_type) do
    sim_members = Map.keys(sim_type.fields) ++ Map.keys(sim_type.input_fields)
    ref_members = MapSet.new(Map.keys(ref_type.fields) ++ Map.keys(ref_type.input_fields))

    sim_members
    |> Enum.reject(&MapSet.member?(ref_members, &1))
    |> Enum.map(&"#{type_name}.#{&1}")
  end

  defp behavioral_gaps(dirs) do
    Enum.flat_map(dirs, fn dir ->
      metadata = read_metadata(dir)
      name = Map.get(metadata, "name", Path.basename(dir))

      metadata
      |> get_in(["compatibility", "knownDifferences"])
      |> List.wrap()
      |> Enum.map(&"#{name}: #{&1}")
    end)
  end

  defp read_metadata(dir), do: read_json(Path.join(dir, "metadata.json")) || %{}

  defp read_json(path) do
    case File.read(path) do
      {:ok, contents} -> Jason.decode!(contents)
      _ -> nil
    end
  end
end
