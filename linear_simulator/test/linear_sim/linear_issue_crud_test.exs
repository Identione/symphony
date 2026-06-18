defmodule LinearSim.LinearIssueCrudTest do
  @moduledoc """
  Context-level coverage for creating, updating, and deleting issues — the
  operations the Entities dashboard exposes for editing the simulated workspace.
  """
  use LinearSim.DataCase, async: false

  alias LinearSim.Linear

  setup do
    org = Linear.default_organization()
    [team] = Linear.list_teams(org)
    states = Linear.list_workflow_states(org)
    labels = Linear.list_labels(org)
    %{org: org, team: team, states: states, labels: labels}
  end

  defp label_ids(issue), do: issue.labels |> Enum.map(& &1.id) |> Enum.sort()

  defp reload_issue(org, id), do: Linear.get_issue_by_id_or_identifier(org, id)

  describe "create_issue/2" do
    test "creates an issue with an auto-assigned identifier and number", %{
      org: org,
      team: team,
      states: states
    } do
      todo = Enum.find(states, &(&1.name == "Todo"))

      attrs = %{
        "team_id" => team.id,
        "title" => "Wire up the widget",
        "description" => "Make it go",
        "state_id" => todo.id,
        "priority" => "2"
      }

      assert {:ok, issue} = Linear.create_issue(org, attrs)
      assert issue.title == "Wire up the widget"
      assert issue.description == "Make it go"
      assert issue.priority == 2
      assert issue.state_id == todo.id
      assert issue.team_id == team.id
      assert issue.organization_id == org.id
      # basic_workspace seeds ENG-1, so the next number is 2.
      assert issue.number == 2
      assert issue.identifier == "ENG-2"
      assert issue.url =~ "ENG-2"
      assert issue.branch_name =~ "eng-2"
      assert is_binary(issue.id)
    end

    test "increments the number per team across successive creates", %{
      org: org,
      team: team
    } do
      assert {:ok, first} = Linear.create_issue(org, %{"team_id" => team.id, "title" => "One"})
      assert {:ok, second} = Linear.create_issue(org, %{"team_id" => team.id, "title" => "Two"})

      assert first.identifier == "ENG-2"
      assert second.identifier == "ENG-3"
    end

    test "treats blank optional foreign keys as nil rather than failing", %{
      org: org,
      team: team
    } do
      attrs = %{
        "team_id" => team.id,
        "title" => "Unassigned",
        "state_id" => "",
        "assignee_id" => "",
        "project_id" => "",
        "priority" => ""
      }

      assert {:ok, issue} = Linear.create_issue(org, attrs)
      assert issue.state_id == nil
      assert issue.assignee_id == nil
      assert issue.project_id == nil
      assert issue.priority == nil
    end

    test "rejects a blank title with a changeset error", %{org: org, team: team} do
      assert {:error, changeset} =
               Linear.create_issue(org, %{"team_id" => team.id, "title" => ""})

      assert "can't be blank" in errors_on(changeset).title
    end

    test "rejects a missing team with a changeset error", %{org: org} do
      assert {:error, changeset} = Linear.create_issue(org, %{"title" => "No team"})
      assert errors_on(changeset).team_id != []
    end

    test "rejects a non-existent FK reference with a changeset error (no crash)", %{
      org: org,
      team: team
    } do
      assert {:error, changeset} =
               Linear.create_issue(org, %{
                 "team_id" => team.id,
                 "title" => "Bad parent",
                 "parent_id" => "issue_ghost"
               })

      assert errors_on(changeset).parent_id != []
    end

    test "appears in list_issues after creation", %{org: org, team: team} do
      assert {:ok, issue} = Linear.create_issue(org, %{"team_id" => team.id, "title" => "Listed"})
      identifiers = org |> Linear.list_issues(%{}) |> Enum.map(& &1.identifier)
      assert issue.identifier in identifiers
    end
  end

  describe "update_issue/2 (general fields)" do
    test "updates title, description, priority and assignee", %{org: org} do
      [issue] = Linear.list_issues(org, %{})
      user = Linear.default_user()

      attrs = %{
        "title" => "Renamed",
        "description" => "New body",
        "priority" => "1",
        "assignee_id" => user.id
      }

      assert {:ok, updated} = Linear.update_issue(issue.id, attrs)
      assert updated.title == "Renamed"
      assert updated.description == "New body"
      assert updated.priority == 1
      assert updated.assignee_id == user.id
    end

    test "clears the assignee when given a blank value", %{org: org} do
      [issue] = Linear.list_issues(org, %{})
      assert issue.assignee_id != nil

      assert {:ok, updated} = Linear.update_issue(issue.id, %{"assignee_id" => ""})
      assert updated.assignee_id == nil
    end

    test "returns :not_found for an unknown id" do
      assert {:error, :not_found} = Linear.update_issue("nope", %{"title" => "x"})
    end

    test "rejects a non-existent assignee reference with a changeset error", %{org: org} do
      [issue] = Linear.list_issues(org, %{})

      assert {:error, changeset} = Linear.update_issue(issue.id, %{"assignee_id" => "user_ghost"})
      assert errors_on(changeset).assignee_id != []
    end
  end

  describe "labels" do
    test "base workspace seeds workspace labels", %{labels: labels} do
      names = labels |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Bug", "Feature", "Improvement"]
    end

    test "create_label adds an org label", %{org: org} do
      assert {:ok, label} = Linear.create_label(org, %{"name" => "Spike", "color" => "#000000"})
      assert label.name == "Spike"
      assert label.id in Enum.map(Linear.list_labels(org), & &1.id)
    end

    test "add_issue_label / remove_issue_label attach and detach (idempotent)", %{org: org} do
      [issue] = Linear.list_issues(org, %{})

      assert {:ok, _} = Linear.add_issue_label(issue.id, "label_bug")
      assert {:ok, _} = Linear.add_issue_label(issue.id, "label_bug")
      assert label_ids(reload_issue(org, issue.id)) == ["label_bug"]

      assert {:ok, _} = Linear.add_issue_label(issue.identifier, "label_feature")
      assert label_ids(reload_issue(org, issue.id)) == ["label_bug", "label_feature"]

      assert {:ok, _} = Linear.remove_issue_label(issue.id, "label_bug")
      assert label_ids(reload_issue(org, issue.id)) == ["label_feature"]
      # Removing a non-attached label still succeeds.
      assert {:ok, _} = Linear.remove_issue_label(issue.id, "label_bug")
    end

    test "add_issue_label returns :not_found for unknown issue or label", %{org: org} do
      [issue] = Linear.list_issues(org, %{})
      assert {:error, :not_found} = Linear.add_issue_label("nope", "label_bug")
      assert {:error, :not_found} = Linear.add_issue_label(issue.id, "label_nope")
    end

    test "update_issue label_ids replaces the full set", %{org: org} do
      [issue] = Linear.list_issues(org, %{})
      {:ok, _} = Linear.add_issue_label(issue.id, "label_bug")

      assert {:ok, _} =
               Linear.update_issue(issue.id, %{
                 "label_ids" => ["label_feature", "label_improvement"]
               })

      assert label_ids(reload_issue(org, issue.id)) == ["label_feature", "label_improvement"]

      # Empty list clears all labels.
      assert {:ok, _} = Linear.update_issue(issue.id, %{"label_ids" => []})
      assert label_ids(reload_issue(org, issue.id)) == []
    end

    test "update_issue added/removed_label_ids apply incrementally", %{org: org} do
      [issue] = Linear.list_issues(org, %{})
      {:ok, _} = Linear.add_issue_label(issue.id, "label_bug")

      assert {:ok, _} =
               Linear.update_issue(issue.id, %{
                 "added_label_ids" => ["label_feature"],
                 "removed_label_ids" => ["label_bug"]
               })

      assert label_ids(reload_issue(org, issue.id)) == ["label_feature"]
    end

    test "create_issue accepts label_ids and parent_id/cycle_id passthrough", %{
      org: org,
      team: team
    } do
      [parent] = Linear.list_issues(org, %{})

      assert {:ok, issue} =
               Linear.create_issue(org, %{
                 "team_id" => team.id,
                 "title" => "Labeled child",
                 "parent_id" => parent.id,
                 "label_ids" => ["label_bug", "label_improvement"]
               })

      assert issue.parent_id == parent.id
      assert label_ids(reload_issue(org, issue.id)) == ["label_bug", "label_improvement"]
    end
  end

  describe "relations and sub-issues" do
    setup %{org: org, team: team} do
      {:ok, blocker} = Linear.create_issue(org, %{"team_id" => team.id, "title" => "Blocker"})
      %{blocker: blocker}
    end

    test "create_issue_relation links two issues (by identifier) and preloads on the target", %{
      org: org,
      blocker: blocker
    } do
      [target] = Enum.filter(Linear.list_issues(org, %{}), &(&1.identifier == "ENG-1"))

      assert {:ok, relation} =
               Linear.create_issue_relation(%{
                 "type" => "blocks",
                 "issue_id" => blocker.identifier,
                 "related_issue_id" => target.identifier
               })

      assert relation.type == "blocks"
      assert relation.issue_id == blocker.id
      assert relation.related_issue_id == target.id

      # The target sees it as an inverse relation (symphony's blocker check).
      reloaded = Linear.get_issue_by_id_or_identifier(org, target.id)
      assert [%{type: "blocks"}] = reloaded.inverse_relations
      # The source sees it as an outgoing relation.
      source = Linear.get_issue_by_id_or_identifier(org, blocker.id)
      assert [%{type: "blocks", related_issue_id: rid}] = source.relations
      assert rid == target.id
    end

    test "create_issue_relation rejects an unknown issue", %{blocker: blocker} do
      assert {:error, :not_found} =
               Linear.create_issue_relation(%{
                 "type" => "blocks",
                 "issue_id" => blocker.id,
                 "related_issue_id" => "issue_ghost"
               })
    end

    test "create_issue_relation rejects an invalid type", %{org: org, blocker: blocker} do
      [target] = Enum.filter(Linear.list_issues(org, %{}), &(&1.identifier == "ENG-1"))

      assert {:error, changeset} =
               Linear.create_issue_relation(%{
                 "type" => "bogus",
                 "issue_id" => blocker.id,
                 "related_issue_id" => target.id
               })

      assert errors_on(changeset).type != []
    end

    test "delete_issue_relation removes the link", %{org: org, blocker: blocker} do
      [target] = Enum.filter(Linear.list_issues(org, %{}), &(&1.identifier == "ENG-1"))

      {:ok, relation} =
        Linear.create_issue_relation(%{
          "type" => "related",
          "issue_id" => blocker.id,
          "related_issue_id" => target.id
        })

      assert {:ok, _} = Linear.delete_issue_relation(relation.id)
      assert {:error, :not_found} = Linear.delete_issue_relation(relation.id)
      assert Linear.get_issue_by_id_or_identifier(org, blocker.id).relations == []
    end

    test "sub-issues: setting parent_id exposes parent and children", %{
      org: org,
      team: team,
      blocker: parent
    } do
      {:ok, child} =
        Linear.create_issue(org, %{
          "team_id" => team.id,
          "title" => "Child",
          "parent_id" => parent.id
        })

      assert Linear.get_issue_by_id_or_identifier(org, child.id).parent.id == parent.id

      child_ids =
        Linear.get_issue_by_id_or_identifier(org, parent.id).children |> Enum.map(& &1.id)

      assert child.id in child_ids
    end
  end

  describe "archive_issue/1" do
    test "soft-archives the issue and hides it from list_issues", %{org: org} do
      [issue] = Linear.list_issues(org, %{})
      assert issue.archived_at == nil

      assert {:ok, archived} = Linear.archive_issue(issue.id)
      assert %DateTime{} = archived.archived_at

      # Excluded from the default listing...
      assert Linear.list_issues(org, %{}) == []
      # ...but still fetchable directly by id (Linear keeps archived issues).
      assert Linear.get_issue_by_id_or_identifier(org, issue.id).id == issue.id
    end

    test "returns :not_found for an unknown id" do
      assert {:error, :not_found} = Linear.archive_issue("nope")
    end
  end

  describe "delete_issue/1" do
    test "removes the issue and its comments", %{org: org} do
      [issue] = Linear.list_issues(org, %{})
      assert Linear.list_comments(issue.id) != []

      assert {:ok, _deleted} = Linear.delete_issue(issue.id)
      assert Linear.list_issues(org, %{}) == []
      assert Linear.list_comments(issue.id) == []
    end

    test "deletes by ticket identifier too (not just internal id)", %{org: org} do
      [issue] = Linear.list_issues(org, %{})

      assert {:ok, _deleted} = Linear.delete_issue(issue.identifier)
      assert Linear.list_issues(org, %{}) == []
    end

    test "returns :not_found for an unknown id" do
      assert {:error, :not_found} = Linear.delete_issue("nope")
    end
  end
end
