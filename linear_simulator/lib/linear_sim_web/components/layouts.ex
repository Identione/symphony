defmodule LinearSimWeb.Layouts do
  @moduledoc """
  Holds the dashboard's root and app layouts.

  The root layout pulls Tailwind (Play CDN) and the prebuilt LiveView client —
  there is no JS build step for this developer-facing simulator UI.
  """
  use LinearSimWeb, :html

  embed_templates "layouts/*"
end
