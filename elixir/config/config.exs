import Config

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

# Tests rewrite WORKFLOW.md per-suite via TestSupport, but the application
# boots once at the start of `mix test` against the project's real
# WORKFLOW.md — which sets `server.port: 3453`. That collides with the host's
# Symphony daemon on the same port. Pin the override to `0` (random ephemeral
# port) under `:test` so the boot-time HttpServer either picks a free port or
# is short-circuited by the per-test workflow that sets `server_port: nil`.
if config_env() == :test do
  config :symphony_elixir, server_port_override: 0
end
