defmodule Mix.Tasks.LinearSim.DumpSchema do
  @moduledoc """
  Dumps the simulator's GraphQL schema to `priv/linear_sim/` as both SDL
  (`schema.graphql`) and an introspection result (`schema.json`)
  (docs/linear-sim.md §3). Commit the results so schema changes are reviewable in
  PRs; the JSON is the symmetric artifact to the Linear reference snapshot and is
  what the compatibility report diffs against. Run with: `mix linear_sim.dump_schema`.
  """
  @shortdoc "Writes the simulator GraphQL schema to priv/linear_sim/{schema.graphql,schema.json}"
  use Mix.Task

  @schema LinearSimWeb.GraphQL.Schema

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    {:ok, paths} = dump()
    Mix.shell().info("Wrote simulator schema to:\n  #{paths.sdl}\n  #{paths.json}")
  end

  @typedoc "Absolute paths to the written simulator schema artifacts."
  @type paths :: %{sdl: String.t(), json: String.t()}

  @doc "Writes the simulator SDL + introspection JSON. `:out_dir` defaults to `priv/linear_sim`."
  @spec dump(keyword()) :: {:ok, paths()} | {:error, term()}
  def dump(opts \\ []) do
    dir = Keyword.get(opts, :out_dir, Path.join(["priv", "linear_sim"]))
    paths = %{sdl: Path.join(dir, "schema.graphql"), json: Path.join(dir, "schema.json")}

    with {:ok, %{data: data}} <- Absinthe.Schema.introspect(@schema) do
      File.mkdir_p!(dir)
      File.write!(paths.sdl, Absinthe.Schema.to_sdl(@schema))
      File.write!(paths.json, Jason.encode!(data, pretty: true))
      {:ok, paths}
    end
  end
end
