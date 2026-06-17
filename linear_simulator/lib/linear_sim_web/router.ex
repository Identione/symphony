defmodule LinearSimWeb.Router do
  use LinearSimWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Linear-compatible GraphQL endpoint. Context resolves the bearer token into
  # the Absinthe context; the request logger then records the (redacted) request.
  pipeline :graphql do
    plug :accepts, ["json"]
    plug LinearSimWeb.GraphQL.Plugs.ResponseMode
    plug LinearSimWeb.GraphQL.Plugs.Context
    plug LinearSimWeb.GraphQL.Plugs.RequestLogger
    plug LinearSimWeb.GraphQL.Plugs.CaptureOperations
  end

  scope "/" do
    pipe_through :api

    get "/health", LinearSimWeb.HealthController, :index
  end

  # Admin control plane — reset/load scenarios, inspect state. Separate from the
  # simulated Linear GraphQL endpoint.
  scope "/admin", LinearSimWeb do
    pipe_through :api

    post "/reset", AdminController, :reset
    post "/scenario/:name", AdminController, :scenario
    post "/webhooks/replay", AdminController, :replay_webhook
    get "/state", AdminController, :state
  end

  scope "/" do
    pipe_through :graphql

    forward "/graphql", Absinthe.Plug, schema: LinearSimWeb.GraphQL.Schema
  end
end
