defmodule LinearSim.Repo do
  use Ecto.Repo,
    otp_app: :linear_sim,
    adapter: Ecto.Adapters.SQLite3
end
