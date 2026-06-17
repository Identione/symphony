# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     LinearSim.Repo.insert!(%LinearSim.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Load the default scenario so a freshly created dev database is immediately
# pollable by symphony (project slug "roadmap", state "Todo", token "user_hakan").
LinearSim.Scenarios.reset!()
IO.puts("Seeded default scenario: basic_workspace")
