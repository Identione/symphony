defmodule LinearSimWeb.DashboardLiveTest do
  @moduledoc "End-to-end LiveView coverage for the simulator control dashboard."
  use LinearSimWeb.ConnCase, async: false

  alias LinearSim.{Mode, Scenarios}

  describe "Overview" do
    test "renders entity counts for the default scenario", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Overview"
      # basic_workspace seeds exactly 8 workflow states.
      assert html =~ "States"
      assert html =~ "BASIC_WORKSPACE"
    end

    test "sidebar exposes every section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      for label <- [
            "Overview",
            "Scenarios",
            "Entities",
            "Captured Operations",
            "Webhooks",
            "Settings"
          ] do
        assert html =~ label
      end
    end
  end

  describe "Scenarios" do
    test "lists all eight scenarios with the active one marked", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/scenarios")

      for name <- Scenarios.names() do
        assert html =~ name
      end

      assert html =~ "ACTIVE"
      assert html =~ "ERROR"
      assert html =~ "DATA"
    end

    test "loading a scenario updates the active state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/scenarios")

      html = view |> element("button[phx-value-name='many_issues']") |> render_click()

      assert Scenarios.current() == "many_issues"
      assert html =~ "Loaded"
    end

    test "response mode override sets the GraphQL mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/scenarios")

      view |> element("button[phx-value-mode='rate_limited']") |> render_click()

      assert Mode.get() == :rate_limited
    end
  end

  describe "Entities" do
    test "issues tab shows seeded issue ENG-1", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/entities")
      assert html =~ "ENG-1"
    end

    test "states tab lists workflow states", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")
      html = view |> element("button[phx-value-tab='states']") |> render_click()

      assert html =~ "In Progress"
      assert html =~ "Merging"
    end

    test "users tab shows the seeded user", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")
      html = view |> element("button[phx-value-tab='users']") |> render_click()

      assert html =~ "Håkan Niska"
    end

    @tag scenario: :empty_workspace
    test "empty workspace shows no issue rows", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/entities")
      assert html =~ "No rows for this scenario."
    end
  end

  describe "Captured operations" do
    test "renders an empty state when nothing is captured", %{conn: conn} do
      LinearSim.OperationCapture.clear()
      {:ok, _view, html} = live(conn, "/captured")
      assert html =~ "No operations captured yet"
    end
  end

  describe "Webhooks" do
    test "renders the replay form and an empty history", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/webhooks")

      assert html =~ "Replay webhook"
      assert html =~ "Target URL"
      assert html =~ "No deliveries yet."
    end
  end

  describe "Settings" do
    test "renders configuration sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Operation capture"
      assert html =~ "GraphQL logging"
      assert html =~ "Danger zone"
    end

    test "toggling operation capture flips the runtime config", %{conn: conn} do
      original = Application.get_env(:linear_sim, :operation_capture, [])

      try do
        Application.put_env(
          :linear_sim,
          :operation_capture,
          Keyword.put(original, :enabled, false)
        )

        {:ok, view, _html} = live(conn, "/settings")

        view
        |> element("button[phx-value-group='capture'][phx-value-field='enabled']")
        |> render_click()

        assert Application.get_env(:linear_sim, :operation_capture)[:enabled] == true
      after
        Application.put_env(:linear_sim, :operation_capture, original)
      end
    end
  end

  describe "Shell controls" do
    test "reset returns to the default scenario", %{conn: conn} do
      Scenarios.load!("many_issues")
      {:ok, view, _html} = live(conn, "/scenarios")

      view |> element("button[phx-click='shell:reset']") |> render_click()

      assert Scenarios.current() == Scenarios.default()
    end
  end
end
