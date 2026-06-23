defmodule LinearSimWeb.DashboardLiveTest do
  @moduledoc "End-to-end LiveView coverage for the simulator control dashboard."
  use LinearSimWeb.ConnCase, async: false

  alias LinearSim.{Mode, Scenarios}

  describe "Overview" do
    test "renders entity counts for the default scenario", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Overview"
      # basic_workspace seeds the full IDE-team workflow states (10).
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

  describe "Issue browser enhancements" do
    test "clicking the issue identifier opens the edit modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")

      html =
        view
        |> element("button[phx-click='edit_issue']", "ENG-1")
        |> render_click()

      assert html =~ "Edit ENG-1"
    end

    test "the issues table shows the project an issue is on", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/entities")

      # basic_workspace puts ENG-1 on the "Roadmap" project.
      assert html =~ "Roadmap"
    end

    test "the issues table shows blocking and blocked-by relations", %{conn: conn} do
      org = LinearSim.Linear.default_organization()

      {:ok, blocked} =
        LinearSim.Linear.create_issue(org, %{"title" => "Blocked thing", "team_id" => "team_eng"})

      {:ok, _rel} =
        LinearSim.Linear.create_issue_relation(%{
          "issue_id" => "issue_eng_1",
          "type" => "blocks",
          "related_issue_id" => blocked.id
        })

      {:ok, _view, html} = live(conn, "/entities")

      # ENG-1 blocks the new issue; the new issue is blocked by ENG-1.
      assert html =~ "blocks #{blocked.identifier}"
      assert html =~ "blocked by ENG-1"
    end

    test "the edit modal shows the issue's activity (comments)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/entities")

      html =
        view
        |> element("button[phx-click='edit_issue']", "ENG-1")
        |> render_click()

      # ENG-1 carries a seeded "Symphony Workpad" comment authored by the seeded user.
      assert html =~ "Activity"
      assert html =~ "Symphony Workpad"
      assert html =~ "Håkan Niska"
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
      |> element("button[phx-value-id='issue_eng_1'][phx-click='edit_issue']", "edit")
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
      |> element("button[phx-value-id='issue_eng_1'][phx-click='edit_issue']", "edit")
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
      |> element("button[phx-value-id='#{child.id}'][phx-click='edit_issue']", "edit")
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
      |> element("button[phx-value-id='issue_eng_1'][phx-click='edit_issue']", "edit")
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

  describe "Unsupported operations counter" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "linear_sim_unsupported_dash_#{System.unique_integer([:positive])}.jsonl"
        )

      File.rm(path)
      previous = Application.get_env(:linear_sim, :unsupported_operations)
      Application.put_env(:linear_sim, :unsupported_operations, enabled: true, path: path)

      on_exit(fn ->
        File.rm(path)

        if previous,
          do: Application.put_env(:linear_sim, :unsupported_operations, previous),
          else: Application.delete_env(:linear_sim, :unsupported_operations)
      end)

      {:ok, path: path}
    end

    defp write_gaps(path, names) do
      contents =
        Enum.map_join(names, "", fn name ->
          Jason.encode!(%{operationName: name, errors: ["e"], query: "q", capturedAt: "t"}) <>
            "\n"
        end)

      File.write!(path, contents)
    end

    test "shows a badge with the count when there are unsupported operations", %{
      conn: conn,
      path: path
    } do
      write_gaps(path, ["A", "B"])

      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#unsupported-badge")
      assert render(view) =~ "2"
    end

    test "hides the badge when there are none", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#unsupported-badge")
    end

    test "overview Current state lists the unsupported count", %{conn: conn, path: path} do
      write_gaps(path, ["A", "B", "C"])

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Unsupported ops"
      assert html =~ "3"
    end

    test "clicking the badge opens a modal listing the calls as pretty JSON", %{
      conn: conn,
      path: path
    } do
      write_gaps(path, ["GetCycles"])

      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#unsupported-modal")

      html = view |> element("#unsupported-badge") |> render_click()

      assert has_element?(view, "#unsupported-modal")
      assert html =~ "GetCycles"
      # Pretty-printed JSON: indented keys on their own lines.
      assert html =~ "&quot;operationName&quot;: &quot;GetCycles&quot;"

      # Closing hides it again.
      view
      |> element("#unsupported-modal button[phx-click='shell:hide_unsupported']")
      |> render_click()

      refute has_element?(view, "#unsupported-modal")
    end

    test "the count auto-updates when a new unsupported call arrives (no refresh)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#unsupported-badge")

      # A brand-new unsupported operation hits the GraphQL endpoint over a
      # separate connection; the recorder broadcasts and the open view updates.
      Phoenix.ConnTest.build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer user_hakan")
      |> post("/graphql", %{"query" => "query Live { viewer { id ghostField } }"})

      assert render(view) =~ "1 unsupported"
      assert has_element?(view, "#unsupported-badge")
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
