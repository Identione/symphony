defmodule LinearSimWeb.HealthController do
  @moduledoc "Liveness probe for the simulator."
  use LinearSimWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
