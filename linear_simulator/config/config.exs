# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :linear_sim,
  ecto_repos: [LinearSim.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :linear_sim, LinearSimWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: LinearSimWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: LinearSim.PubSub,
  live_view: [signing_salt: "ScW0QfbA"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# GraphQL request logging for developer observability (docs/linear-sim.md §11).
# The Authorization header is always redacted; full secrets are never logged.
config :linear_sim, :graphql_logging,
  enabled: true,
  log_query: true,
  log_variables: true,
  redact_authorization: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
