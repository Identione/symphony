import Config

# Bind the observability HTTP server to an OS-chosen ephemeral port at app
# boot so `mix test` (and `make all` / `make coverage`) does not contend with
# a host-side Symphony daemon for the WORKFLOW.md `server.port` (default
# 3453). `SymphonyElixir.Config.server_port/0` consults this override before
# the workflow value, and `HttpServer.start_link/1` runs during the
# Application supervision tree boot — too early for any per-test setup to
# intervene.
config :symphony_elixir, :server_port_override, 0
