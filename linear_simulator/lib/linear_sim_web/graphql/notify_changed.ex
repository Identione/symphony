defmodule LinearSimWeb.GraphQL.NotifyChanged do
  @moduledoc """
  Absinthe middleware appended to every mutation field. After a mutation
  resolves without errors it broadcasts `:sim_changed` so open dashboard
  LiveViews refresh without a manual browser reload.

  Web-UI mutations call `LinearSimWeb.Shell.notify_changed/0` directly; this
  closes the same gap for GraphQL-API mutations (the path Symphony uses).
  """
  @behaviour Absinthe.Middleware

  alias LinearSimWeb.Shell

  @impl Absinthe.Middleware
  def call(%Absinthe.Resolution{errors: []} = resolution, _config) do
    Shell.notify_changed()
    resolution
  end

  def call(resolution, _config), do: resolution
end
