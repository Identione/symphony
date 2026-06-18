defmodule LinearSimWeb.GraphQLBehaviorTest do
  @moduledoc """
  Behavioural assertions beyond schema validity: blocker extraction via
  inverseRelations, connection pagination, state transitions, and structured
  validation errors.
  """
  use LinearSimWeb.ConnCase, async: false

  alias LinearSim.Repo
  alias LinearSim.Linear.{Issue, IssueRelation}
  alias LinearSim.Scenarios.Common

  @poll File.read!(
          Path.join([
            File.cwd!(),
            "priv/linear/operations/curated/symphony_linear_poll/operation.graphql"
          ])
        )

  defp gql(conn, query, variables) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer user_hakan")
    |> post("/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  describe "inverseRelations blocker extraction" do
    test "exposes a blocking issue as inverseRelations.node.issue with type blocks", %{conn: conn} do
      # Seed a blocker: ENG-2 blocks ENG-1.
      Repo.insert!(%Issue{
        id: "issue_eng_2",
        organization_id: "org_default",
        team_id: "team_eng",
        state_id: "state_todo",
        project_id: "project_roadmap",
        identifier: "ENG-2",
        number: 2,
        title: "Blocker",
        branch_name: Common.branch_name("ENG-2"),
        url: Common.issue_url("ENG-2")
      })

      Repo.insert!(%IssueRelation{
        id: "rel_1",
        issue_id: "issue_eng_2",
        related_issue_id: "issue_eng_1",
        type: "blocks"
      })

      vars = %{
        "projectSlug" => "roadmap",
        "stateNames" => ["Todo"],
        "first" => 50,
        "relationFirst" => 10,
        "after" => nil
      }

      body = gql(conn, @poll, vars)
      nodes = get_in(body, ["data", "issues", "nodes"])
      eng1 = Enum.find(nodes, &(&1["identifier"] == "ENG-1"))

      assert [%{"type" => "blocks", "issue" => %{"identifier" => "ENG-2"}}] =
               get_in(eng1, ["inverseRelations", "nodes"])
    end
  end

  describe "pagination" do
    @tag scenario: :many_issues
    test "many_issues returns one page and reports hasNextPage", %{conn: conn} do
      vars = %{
        "projectSlug" => "roadmap",
        "stateNames" => ["Todo"],
        "first" => 50,
        "relationFirst" => 10,
        "after" => nil
      }

      body = gql(conn, @poll, vars)
      page = get_in(body, ["data", "issues", "nodes"])
      assert length(page) == 50
      assert get_in(body, ["data", "issues", "pageInfo", "hasNextPage"]) == true
      assert is_binary(get_in(body, ["data", "issues", "pageInfo", "endCursor"]))
    end
  end

  describe "parent extraction" do
    test "exposes an issue's parent (with state and sibling children) on the poll query", %{
      conn: conn
    } do
      # Seed a parent ENG-100 and make ENG-1 its child.
      Repo.insert!(%Issue{
        id: "issue_eng_100",
        organization_id: "org_default",
        team_id: "team_eng",
        state_id: "state_todo",
        project_id: "project_roadmap",
        identifier: "ENG-100",
        number: 100,
        title: "Parent epic",
        branch_name: Common.branch_name("ENG-100"),
        url: Common.issue_url("ENG-100")
      })

      Repo.get(Issue, "issue_eng_1")
      |> Ecto.Changeset.change(parent_id: "issue_eng_100")
      |> Repo.update!()

      vars = %{
        "projectSlug" => "roadmap",
        "stateNames" => ["Todo"],
        "first" => 50,
        "relationFirst" => 10,
        "after" => nil
      }

      body = gql(conn, @poll, vars)

      assert body["errors"] in [nil, []],
             "poll returned errors: #{inspect(body["errors"])}"

      nodes = get_in(body, ["data", "issues", "nodes"])
      eng1 = Enum.find(nodes, &(&1["identifier"] == "ENG-1"))

      assert get_in(eng1, ["parent", "identifier"]) == "ENG-100"
      assert get_in(eng1, ["parent", "state", "name"]) == "Todo"

      sibling_ids =
        eng1 |> get_in(["parent", "children", "nodes"]) |> Enum.map(& &1["identifier"])

      assert "ENG-1" in sibling_ids
    end

    test "resolves parent as null for a top-level issue", %{conn: conn} do
      vars = %{
        "projectSlug" => "roadmap",
        "stateNames" => ["Todo"],
        "first" => 50,
        "relationFirst" => 10,
        "after" => nil
      }

      body = gql(conn, @poll, vars)
      nodes = get_in(body, ["data", "issues", "nodes"])
      eng1 = Enum.find(nodes, &(&1["identifier"] == "ENG-1"))

      assert body["errors"] in [nil, []]
      assert eng1["parent"] == nil
    end
  end

  describe "issueUpdate" do
    test "transitions the issue's workflow state", %{conn: conn} do
      mutation = """
      mutation($id: String!, $stateId: String!) {
        issueUpdate(id: $id, input: {stateId: $stateId}) { success }
      }
      """

      body = gql(conn, mutation, %{"id" => "issue_eng_1", "stateId" => "state_in_progress"})
      assert get_in(body, ["data", "issueUpdate", "success"]) == true
      assert Repo.get(Issue, "issue_eng_1").state_id == "state_in_progress"
    end
  end

  describe "validation errors" do
    test "commentCreate against a missing issue returns a structured error", %{conn: conn} do
      mutation = """
      mutation($issueId: String!, $body: String!) {
        commentCreate(input: {issueId: $issueId, body: $body}) { success }
      }
      """

      body = gql(conn, mutation, %{"issueId" => "issue_missing", "body" => "x"})
      assert [error | _] = body["errors"]
      assert get_in(error, ["extensions", "code"]) == "VALIDATION_ERROR"
    end
  end
end
