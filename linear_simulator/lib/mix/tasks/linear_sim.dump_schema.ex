defmodule Mix.Tasks.LinearSim.DumpSchema do
  @moduledoc """
  Dumps the simulator's GraphQL schema as SDL to `priv/linear_sim/schema.graphql`
  (docs/linear-sim.md §3). Commit the result so schema changes are reviewable in
  PRs. Run with: `mix linear_sim.dump_schema`.
  """
  @shortdoc "Writes the simulator GraphQL schema to priv/linear_sim/schema.graphql"
  use Mix.Task

  @output Path.join(["priv", "linear_sim", "schema.graphql"])

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("compile")
    sdl = Absinthe.Schema.to_sdl(LinearSimWeb.GraphQL.Schema)
    File.mkdir_p!(Path.dirname(@output))
    File.write!(@output, sdl)
    Mix.shell().info("Wrote simulator schema SDL to #{@output}")
  end
end
