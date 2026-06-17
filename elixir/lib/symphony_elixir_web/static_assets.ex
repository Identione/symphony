defmodule SymphonyElixirWeb.StaticAssets do
  @moduledoc false

  @dashboard_css_path Path.expand("../../priv/static/dashboard.css", __DIR__)
  @dashboard_js_path Path.expand("../../priv/static/dashboard.js", __DIR__)
  @phoenix_html_js_path Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @phoenix_js_path Application.app_dir(:phoenix, "priv/static/phoenix.js")
  @phoenix_live_view_js_path Application.app_dir(:phoenix_live_view, "priv/static/phoenix_live_view.js")
  @cytoscape_js_path Path.expand("../../priv/static/vendor/cytoscape/cytoscape.min.js", __DIR__)
  @dagre_js_path Path.expand("../../priv/static/vendor/dagre/dagre.min.js", __DIR__)
  @cytoscape_dagre_js_path Path.expand("../../priv/static/vendor/cytoscape-dagre/cytoscape-dagre.js", __DIR__)
  @layout_base_js_path Path.expand("../../priv/static/vendor/layout-base/layout-base.js", __DIR__)
  @cose_base_js_path Path.expand("../../priv/static/vendor/cose-base/cose-base.js", __DIR__)
  @cytoscape_fcose_js_path Path.expand("../../priv/static/vendor/cytoscape-fcose/cytoscape-fcose.js", __DIR__)

  @external_resource @dashboard_css_path
  @external_resource @dashboard_js_path
  @external_resource @phoenix_html_js_path
  @external_resource @phoenix_js_path
  @external_resource @phoenix_live_view_js_path
  @external_resource @cytoscape_js_path
  @external_resource @dagre_js_path
  @external_resource @cytoscape_dagre_js_path
  @external_resource @layout_base_js_path
  @external_resource @cose_base_js_path
  @external_resource @cytoscape_fcose_js_path

  @dashboard_css File.read!(@dashboard_css_path)
  @dashboard_js File.read!(@dashboard_js_path)
  @phoenix_html_js File.read!(@phoenix_html_js_path)
  @phoenix_js File.read!(@phoenix_js_path)
  @phoenix_live_view_js File.read!(@phoenix_live_view_js_path)
  @cytoscape_js File.read!(@cytoscape_js_path)
  @dagre_js File.read!(@dagre_js_path)
  @cytoscape_dagre_js File.read!(@cytoscape_dagre_js_path)
  @layout_base_js File.read!(@layout_base_js_path)
  @cose_base_js File.read!(@cose_base_js_path)
  @cytoscape_fcose_js File.read!(@cytoscape_fcose_js_path)

  @assets %{
    "/dashboard.css" => {"text/css", @dashboard_css},
    "/dashboard.js" => {"application/javascript", @dashboard_js},
    "/vendor/phoenix_html/phoenix_html.js" => {"application/javascript", @phoenix_html_js},
    "/vendor/phoenix/phoenix.js" => {"application/javascript", @phoenix_js},
    "/vendor/phoenix_live_view/phoenix_live_view.js" => {"application/javascript", @phoenix_live_view_js},
    "/vendor/cytoscape/cytoscape.min.js" => {"application/javascript", @cytoscape_js},
    "/vendor/dagre/dagre.min.js" => {"application/javascript", @dagre_js},
    "/vendor/cytoscape-dagre/cytoscape-dagre.js" => {"application/javascript", @cytoscape_dagre_js},
    "/vendor/layout-base/layout-base.js" => {"application/javascript", @layout_base_js},
    "/vendor/cose-base/cose-base.js" => {"application/javascript", @cose_base_js},
    "/vendor/cytoscape-fcose/cytoscape-fcose.js" => {"application/javascript", @cytoscape_fcose_js}
  }

  @spec fetch(String.t()) :: {:ok, String.t(), binary()} | :error
  def fetch(path) when is_binary(path) do
    case Map.fetch(@assets, path) do
      {:ok, {content_type, body}} -> {:ok, content_type, body}
      :error -> :error
    end
  end
end
