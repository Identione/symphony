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

  describe "Issue editing" do
    test "creating an issue via the form adds it to the workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")

      view |> element("button[phx-click='new_issue']") |> render_click()

      html =
        view
        |> form("form[phx-submit='save_issue']", %{
          "issue" => %{"title" => "Dashboard-created issue", "team_id" => "team_eng"}
        })
        |> render_submit()

      assert html =~ "Dashboard-created issue"
      # basic_workspace seeds ENG-1, so the new issue is ENG-2.
      assert html =~ "ENG-2"

      titles =
        LinearSim.Linear.default_organization()
        |> LinearSim.Linear.list_issues(%{})
        |> Enum.map(& &1.title)

      assert "Dashboard-created issue" in titles
    end

    test "submitting a blank title shows a validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")

      view |> element("button[phx-click='new_issue']") |> render_click()

      html =
        view
        |> form("form[phx-submit='save_issue']", %{
          "issue" => %{"title" => "", "team_id" => "team_eng"}
        })
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "editing an issue updates its title", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")

      view
      |> element("button[phx-value-id='issue_eng_1'][phx-click='edit_issue']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit='save_issue']", %{"issue" => %{"title" => "Renamed via UI"}})
        |> render_submit()

      assert html =~ "Renamed via UI"
      refute html =~ "Build Linear simulator"
    end

    test "assigning labels via the form persists and shows in the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")

      view
      |> element("button[phx-value-id='issue_eng_1'][phx-click='edit_issue']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit='save_issue']", %{
          "issue" => %{"label_ids" => ["label_bug", "label_feature"]}
        })
        |> render_submit()

      # The Labels column now renders the assigned label names.
      assert html =~ "Bug"
      assert html =~ "Feature"

      labels =
        LinearSim.Linear.default_organization()
        |> LinearSim.Linear.list_issues(%{})
        |> hd()
        |> Map.fetch!(:labels)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert labels == ["Bug", "Feature"]
    end

    test "the new-issue form exposes the seeded labels as options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")
      html = view |> element("button[phx-click='new_issue']") |> render_click()

      assert html =~ "Labels"
      assert html =~ "Improvement"
    end

    test "setting a parent via the form makes the issue a sub-issue", %{conn: conn} do
      org = LinearSim.Linear.default_organization()
      [team] = LinearSim.Linear.list_teams(org)

      {:ok, child} =
        LinearSim.Linear.create_issue(org, %{"team_id" => team.id, "title" => "Child"})

      {:ok, view, _html} = live(conn, "/entities")

      view
      |> element("button[phx-value-id='#{child.id}'][phx-click='edit_issue']")
      |> render_click()

      view
      |> form("form[phx-submit='save_issue']", %{"issue" => %{"parent_id" => "issue_eng_1"}})
      |> render_submit()

      assert LinearSim.Linear.get_issue_by_id_or_identifier(org, child.id).parent_id ==
               "issue_eng_1"
    end

    test "adding and removing a relation in the edit modal persists live", %{conn: conn} do
      org = LinearSim.Linear.default_organization()
      [team] = LinearSim.Linear.list_teams(org)

      {:ok, other} =
        LinearSim.Linear.create_issue(org, %{"team_id" => team.id, "title" => "Other"})

      {:ok, view, _html} = live(conn, "/entities")

      view
      |> element("button[phx-value-id='issue_eng_1'][phx-click='edit_issue']")
      |> render_click()

      html =
        view
        |> form("form[phx-submit='add_relation']", %{
          "relation" => %{"type" => "blocks", "related_issue_id" => other.id}
        })
        |> render_submit()

      assert html =~ "blocks"
      assert html =~ other.identifier

      eng1 = LinearSim.Linear.get_issue_by_id_or_identifier(org, "issue_eng_1")
      assert [%{type: "blocks", related_issue_id: rid}] = eng1.relations
      assert rid == other.id

      # Remove it again via the live × button.
      [relation] = eng1.relations

      view
      |> element("button[phx-click='remove_relation'][phx-value-id='#{relation.id}']")
      |> render_click()

      assert LinearSim.Linear.get_issue_by_id_or_identifier(org, "issue_eng_1").relations == []
    end

    test "deleting an issue removes it from the table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")

      assert render(view) =~ "ENG-1"

      html =
        view
        |> element("button[phx-value-id='issue_eng_1'][phx-click='delete_issue']")
        |> render_click()

      refute html =~ "ENG-1"
      assert html =~ "No rows for this scenario."
      assert LinearSim.Linear.list_issues(LinearSim.Linear.default_organization(), %{}) == []
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
