defmodule SymphonyElixir.LinearSubissuesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.{Client, Issue}

  # A child node carrying the `@issue_child_fields` selection set, used both as a
  # top-level poll result and as a sibling under `parent.children`.
  defp child_node(id, identifier, state_name, state_type, labels, assignee_id) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => "Title #{identifier}",
      "priority" => 2,
      "state" => %{"name" => state_name, "type" => state_type},
      "url" => "https://linear.app/example/#{identifier}",
      "assignee" => if(assignee_id, do: %{"id" => assignee_id}, else: nil),
      "labels" => %{"nodes" => Enum.map(labels, &%{"name" => &1})}
    }
  end

  defp single_page(nodes) do
    fn _query, _variables ->
      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => nodes,
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
           }
         }
       }}
    end
  end

  test "normalizes a child issue's parent and the parent's sibling children" do
    parent_children = [
      child_node("child-1", "MT-2", "Todo", "unstarted", ["agent"], "u1"),
      child_node("child-2", "MT-3", "Backlog", "backlog", [], nil)
    ]

    child =
      child_node("child-1", "MT-2", "Todo", "unstarted", ["agent"], "u1")
      |> Map.put("children", %{"nodes" => []})
      |> Map.put("parent", %{
        "id" => "parent-1",
        "identifier" => "MT-1",
        "title" => "Umbrella",
        "url" => "https://linear.app/example/MT-1",
        "state" => %{"name" => "In Progress", "type" => "started"},
        "children" => %{"nodes" => parent_children}
      })
      |> Map.put("inverseRelations", %{"nodes" => []})

    assert {:ok, [%Issue{} = issue]} =
             Client.do_fetch_by_states_for_test("proj", ["Todo"], nil, single_page([child]))

    assert issue.id == "child-1"
    assert issue.parent_id == "parent-1"
    assert issue.children == []

    assert %Issue{id: "parent-1", identifier: "MT-1", has_children: true} = issue.parent

    # The parent carries the full sibling list, each backfilled with parent_id,
    # so a container can be built from any one managed child without re-fetching.
    sibling_ids = issue.parent.children |> Enum.map(& &1.id) |> Enum.sort()
    assert sibling_ids == ["child-1", "child-2"]
    assert Enum.all?(issue.parent.children, &(&1.parent_id == "parent-1"))
  end

  test "normalizes a parent issue's own children and flags has_children" do
    parent =
      %{
        "id" => "parent-1",
        "identifier" => "MT-1",
        "title" => "Umbrella",
        "priority" => 1,
        "state" => %{"name" => "In Progress", "type" => "started"},
        "url" => "https://linear.app/example/MT-1",
        "assignee" => nil,
        "labels" => %{"nodes" => []},
        "children" => %{
          "nodes" => [child_node("child-1", "MT-2", "Todo", "unstarted", ["agent"], "u1")]
        },
        "inverseRelations" => %{"nodes" => []}
      }

    assert {:ok, [%Issue{} = issue]} =
             Client.do_fetch_by_states_for_test("proj", ["In Progress"], nil, single_page([parent]))

    assert issue.id == "parent-1"
    assert issue.has_children == true
    assert issue.parent_id == nil
    assert [%Issue{id: "child-1", parent_id: "parent-1"}] = issue.children
  end

  test "captures a blocker's GitHub PR URL from its attachments onto the blocker ref" do
    issue =
      child_node("iss-1", "MT-10", "Todo", "unstarted", [], nil)
      |> Map.put("children", %{"nodes" => []})
      |> Map.put("inverseRelations", %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "iss-blk",
              "identifier" => "MT-9",
              "state" => %{"name" => "In Progress"},
              "attachments" => %{
                "nodes" => [
                  %{"url" => "https://example.com/not-a-pr"},
                  %{"url" => "https://github.com/acme/repo/pull/9"}
                ]
              }
            }
          }
        ]
      })

    normalized = Client.normalize_issue_for_test(issue)

    assert [%{identifier: "MT-9", pr_url: "https://github.com/acme/repo/pull/9"}] =
             normalized.blocked_by
  end

  test "captures the issue's own GitHub PR URL from its top-level attachments" do
    # Feeds the orchestrator's continuation context on re-runs
    # (docs/investigations/claude-session-token-optimization.md, finding 5).
    issue =
      child_node("iss-pr", "MT-12", "In Progress", "started", [], nil)
      |> Map.put("children", %{"nodes" => []})
      |> Map.put("attachments", %{
        "nodes" => [
          %{"url" => "https://example.com/design-doc"},
          %{"url" => "https://github.com/acme/repo/pull/12"}
        ]
      })

    assert Client.normalize_issue_for_test(issue).pr_url ==
             "https://github.com/acme/repo/pull/12"
  end

  test "leaves the issue's own pr_url nil without a GitHub PR attachment" do
    issue =
      child_node("iss-nopr", "MT-13", "In Progress", "started", [], nil)
      |> Map.put("children", %{"nodes" => []})
      |> Map.put("attachments", %{"nodes" => [%{"url" => "https://example.com/doc"}]})

    assert Client.normalize_issue_for_test(issue).pr_url == nil
  end

  test "leaves a blocker's pr_url nil when no GitHub PR attachment is present" do
    issue =
      child_node("iss-2", "MT-11", "Todo", "unstarted", [], nil)
      |> Map.put("children", %{"nodes" => []})
      |> Map.put("inverseRelations", %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "iss-blk2",
              "identifier" => "MT-8",
              "state" => %{"name" => "In Progress"},
              "attachments" => %{"nodes" => []}
            }
          }
        ]
      })

    normalized = Client.normalize_issue_for_test(issue)

    assert [%{identifier: "MT-8", pr_url: nil}] = normalized.blocked_by
  end
end
