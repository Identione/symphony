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

# Bind the default observability HttpServer to a random free port during the
# test suite so it doesn't collide with a daemon already on port 3453. Tests
# that need their own endpoint terminate this one first via
# `SymphonyElixir.TestSupport.stop_default_http_server/0`.
if config_env() == :test do
  config :symphony_elixir, :server_port_override, 0
end
