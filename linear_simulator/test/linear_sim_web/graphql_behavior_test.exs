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

    test "updates title, description and priority (widened input)", %{conn: conn} do
      mutation = """
      mutation($id: String!) {
        issueUpdate(id: $id, input: {title: "Renamed via API", description: "New body", priority: 1}) {
          success
          issue { identifier title description priority }
        }
      }
      """

      body = gql(conn, mutation, %{"id" => "issue_eng_1"})
      issue = get_in(body, ["data", "issueUpdate", "issue"])
      assert issue["title"] == "Renamed via API"
      assert issue["description"] == "New body"
      assert issue["priority"] == 1

      reloaded = Repo.get(Issue, "issue_eng_1")
      assert reloaded.title == "Renamed via API"
      assert reloaded.priority == 1
    end
  end

  describe "issueCreate" do
    test "creates an issue and returns it queryable", %{conn: conn} do
      mutation = """
      mutation($input: IssueCreateInput!) {
        issueCreate(input: $input) {
          success
          issue { identifier title priority state { name } assignee { name } }
        }
      }
      """

      input = %{
        "teamId" => "team_eng",
        "title" => "Created via API",
        "stateId" => "state_in_progress",
        "assigneeId" => "user_hakan",
        "priority" => 2
      }

      body = gql(conn, mutation, %{"input" => input})
      issue = get_in(body, ["data", "issueCreate", "issue"])

      assert get_in(body, ["data", "issueCreate", "success"]) == true
      # basic_workspace seeds ENG-1, so the API-created issue is ENG-2.
      assert issue["identifier"] == "ENG-2"
      assert issue["title"] == "Created via API"
      assert issue["priority"] == 2
      assert issue["state"]["name"] == "In Progress"
      assert issue["assignee"]["name"] == "Håkan Niska"

      # And it is visible to a follow-up issues query.
      list = """
      query { issues { nodes { identifier } } }
      """

      identifiers =
        gql(conn, list, %{})
        |> get_in(["data", "issues", "nodes"])
        |> Enum.map(& &1["identifier"])

      assert "ENG-2" in identifiers
    end

    test "missing title returns a structured validation error", %{conn: conn} do
      mutation = """
      mutation {
        issueCreate(input: {teamId: "team_eng", title: ""}) { success }
      }
      """

      body = gql(conn, mutation, %{})
      assert [error | _] = body["errors"]
      assert get_in(error, ["extensions", "code"]) == "VALIDATION_ERROR"
    end

    test "a non-existent FK reference returns a structured error, not a 500", %{conn: conn} do
      mutation = """
      mutation {
        issueCreate(input: {teamId: "team_eng", title: "Bad parent", parentId: "issue_ghost"}) {
          success
        }
      }
      """

      body = gql(conn, mutation, %{})
      assert [error | _] = body["errors"]
      assert get_in(error, ["extensions", "code"]) == "VALIDATION_ERROR"
    end
  end

  describe "issueArchive" do
    test "soft-archives so the issue drops out of the issues query", %{conn: conn} do
      mutation = """
      mutation($id: String!) {
        issueArchive(id: $id) { success entity { identifier } }
      }
      """

      body = gql(conn, mutation, %{"id" => "issue_eng_1"})
      assert get_in(body, ["data", "issueArchive", "success"]) == true
      assert get_in(body, ["data", "issueArchive", "entity", "identifier"]) == "ENG-1"

      list = "query { issues { nodes { identifier } } }"
      assert gql(conn, list, %{}) |> get_in(["data", "issues", "nodes"]) == []

      # Soft archive: the row still exists with archivedAt stamped.
      assert Repo.get(Issue, "issue_eng_1").archived_at != nil
    end
  end

  describe "issueDelete" do
    test "hard-deletes the issue", %{conn: conn} do
      mutation = """
      mutation($id: String!) {
        issueDelete(id: $id) { success }
      }
      """

      body = gql(conn, mutation, %{"id" => "issue_eng_1"})
      assert get_in(body, ["data", "issueDelete", "success"]) == true
      assert Repo.get(Issue, "issue_eng_1") == nil
    end
  end

  describe "relations and sub-issues" do
    setup %{conn: conn} do
      # Seed a second issue (ENG-2) to relate to / parent under.
      create = """
      mutation { issueCreate(input: {teamId: "team_eng", title: "Second"}) { issue { identifier } } }
      """

      gql(conn, create, %{})
      :ok
    end

    test "issueRelationCreate links two issues and surfaces inverseRelations", %{conn: conn} do
      mutation = """
      mutation($input: IssueRelationCreateInput!) {
        issueRelationCreate(input: $input) {
          success
          issueRelation { id type issue { identifier } relatedIssue { identifier } }
        }
      }
      """

      input = %{"type" => "blocks", "issueId" => "ENG-2", "relatedIssueId" => "ENG-1"}
      body = gql(conn, mutation, %{"input" => input})
      rel = get_in(body, ["data", "issueRelationCreate", "issueRelation"])

      assert get_in(body, ["data", "issueRelationCreate", "success"]) == true
      assert rel["type"] == "blocks"
      assert rel["issue"]["identifier"] == "ENG-2"
      assert rel["relatedIssue"]["identifier"] == "ENG-1"

      # ENG-1 now reports ENG-2 as a blocker via inverseRelations.
      query = """
      query { issue(id: "ENG-1") { inverseRelations { nodes { type issue { identifier } } } } }
      """

      nodes = gql(conn, query, %{}) |> get_in(["data", "issue", "inverseRelations", "nodes"])
      assert [%{"type" => "blocks", "issue" => %{"identifier" => "ENG-2"}}] = nodes
    end

    test "issueRelationDelete removes the relation", %{conn: conn} do
      create = """
      mutation {
        issueRelationCreate(input: {type: related, issueId: "ENG-2", relatedIssueId: "ENG-1"}) {
          issueRelation { id }
        }
      }
      """

      id =
        gql(conn, create, %{}) |> get_in(["data", "issueRelationCreate", "issueRelation", "id"])

      del = "mutation($id: String!) { issueRelationDelete(id: $id) { success } }"

      assert get_in(gql(conn, del, %{"id" => id}), ["data", "issueRelationDelete", "success"]) ==
               true
    end

    test "an unknown related issue returns a structured error", %{conn: conn} do
      mutation = """
      mutation {
        issueRelationCreate(input: {type: blocks, issueId: "ENG-2", relatedIssueId: "ENG-404"}) {
          success
        }
      }
      """

      assert [_ | _] = gql(conn, mutation, %{})["errors"]
    end

    test "sub-issues: parentId sets parent and exposes children", %{conn: conn} do
      set_parent = """
      mutation { issueUpdate(id: "ENG-2", input: {parentId: "issue_eng_1"}) {
        issue { parent { identifier } }
      } }
      """

      body = gql(conn, set_parent, %{})
      assert get_in(body, ["data", "issueUpdate", "issue", "parent", "identifier"]) == "ENG-1"

      children = """
      query { issue(id: "ENG-1") { children { nodes { identifier } } } }
      """

      ids =
        gql(conn, children, %{})
        |> get_in(["data", "issue", "children", "nodes"])
        |> Enum.map(& &1["identifier"])

      assert "ENG-2" in ids
    end
  end

  describe "labels" do
    defp label_names(issue), do: issue["labels"]["nodes"] |> Enum.map(& &1["name"]) |> Enum.sort()

    test "issueLabels query lists seeded workspace labels", %{conn: conn} do
      body = gql(conn, "query { issueLabels { nodes { name } } }", %{})

      names =
        get_in(body, ["data", "issueLabels", "nodes"]) |> Enum.map(& &1["name"]) |> Enum.sort()

      assert names == ["Bug", "Feature", "Improvement"]
    end

    test "issueLabelCreate adds a label", %{conn: conn} do
      mutation = """
      mutation { issueLabelCreate(input: {name: "Spike", color: "#000000"}) {
        success issueLabel { id name color }
      } }
      """

      body = gql(conn, mutation, %{})
      assert get_in(body, ["data", "issueLabelCreate", "success"]) == true
      assert get_in(body, ["data", "issueLabelCreate", "issueLabel", "name"]) == "Spike"
    end

    test "issueAddLabel and issueRemoveLabel attach/detach by identifier", %{conn: conn} do
      add = """
      mutation($id: String!, $labelId: String!) {
        issueAddLabel(id: $id, labelId: $labelId) { success issue { labels { nodes { name } } } }
      }
      """

      body = gql(conn, add, %{"id" => "ENG-1", "labelId" => "label_bug"})
      assert get_in(body, ["data", "issueAddLabel", "success"]) == true
      assert label_names(get_in(body, ["data", "issueAddLabel", "issue"])) == ["Bug"]

      remove = """
      mutation($id: String!, $labelId: String!) {
        issueRemoveLabel(id: $id, labelId: $labelId) { success issue { labels { nodes { name } } } }
      }
      """

      body = gql(conn, remove, %{"id" => "ENG-1", "labelId" => "label_bug"})
      assert label_names(get_in(body, ["data", "issueRemoveLabel", "issue"])) == []
    end

    test "issueUpdate labelIds replaces the set; addedLabelIds/removedLabelIds patch it", %{
      conn: conn
    } do
      replace = """
      mutation($id: String!, $ids: [String!]) {
        issueUpdate(id: $id, input: {labelIds: $ids}) { success issue { labels { nodes { name } } } }
      }
      """

      body = gql(conn, replace, %{"id" => "ENG-1", "ids" => ["label_bug", "label_feature"]})
      assert label_names(get_in(body, ["data", "issueUpdate", "issue"])) == ["Bug", "Feature"]

      patch = """
      mutation($id: String!) {
        issueUpdate(id: $id, input: {addedLabelIds: ["label_improvement"], removedLabelIds: ["label_bug"]}) {
          issue { labels { nodes { name } } }
        }
      }
      """

      body = gql(conn, patch, %{"id" => "ENG-1"})

      assert label_names(get_in(body, ["data", "issueUpdate", "issue"])) == [
               "Feature",
               "Improvement"
             ]
    end

    test "issueCreate accepts labelIds", %{conn: conn} do
      mutation = """
      mutation {
        issueCreate(input: {teamId: "team_eng", title: "Tagged", labelIds: ["label_bug"]}) {
          issue { identifier labels { nodes { name } } }
        }
      }
      """

      body = gql(conn, mutation, %{})
      issue = get_in(body, ["data", "issueCreate", "issue"])
      assert issue["identifier"] == "ENG-2"
      assert label_names(issue) == ["Bug"]
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
