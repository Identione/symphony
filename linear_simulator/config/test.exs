import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# File-backed SQLite with explicit scenario reset rather than the SQL sandbox
# (docs/linear-sim.md §5–6). pool_size: 1 minimises SQLite lock contention.
# Tests that touch simulator state must `use ... async: false` and reset to a
# known scenario in setup — ConnCase enforces this.
config :linear_sim, LinearSim.Repo,
  database: Path.expand("../linear_sim_test.db", __DIR__),
  pool_size: 1,
  busy_timeout: 5_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :linear_sim, LinearSimWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "pgMrDsbLUJ1mgQVAK+JduwFcuVrRMcf3c7AVJTdb6FOoQ3PUrOMPf2Q6f6bKW7PD",
  server: false

# Keep unsupported-operation recording out of priv/ during tests — its own test
# overrides this path per-run; everything else writes to a throwaway temp file.
config :linear_sim, :unsupported_operations,
  enabled: true,
  path: Path.join(System.tmp_dir!(), "linear_sim_unsupported_test.jsonl"),
  redact_variables: ["accessToken", "apiKey", "password", "token"]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
