defmodule LinearSimWeb.GraphQLRootQueriesTest do
  @moduledoc """
  Covers the root-level discovery queries Linear clients expect but the
  operation-driven simulator was missing (see priv/linear/operations/unsupported.jsonl,
  "Bucket A"): `teams`, `users`, `team(id:)`, `workflowStates`, plus `User.displayName`
  and `Comment.user`.
  """
  use LinearSimWeb.ConnCase, async: false

  alias LinearSim.Repo
  alias LinearSim.Linear.Comment

  describe "teams root query" do
    test "lists the organization's teams", %{conn: conn} do
      body = gql(conn, "{ teams { nodes { id key name } } }")
      nodes = get_in(body, ["data", "teams", "nodes"])

      assert %{"id" => "team_eng", "key" => "ENG", "name" => "Engineering"} in nodes
    end
  end

  describe "team(id:) root query" do
    test "fetches a team by internal id, with its states", %{conn: conn} do
      query = ~s|{ team(id: "team_eng") { id key name states { nodes { name } } } }|
      body = gql(conn, query)
      team = get_in(body, ["data", "team"])

      assert team["key"] == "ENG"
      state_names = Enum.map(team["states"]["nodes"], & &1["name"])
      assert "In Progress" in state_names
    end

    test "fetches a team by key", %{conn: conn} do
      body = gql(conn, ~s|{ team(id: "ENG") { id key } }|)
      assert get_in(body, ["data", "team", "id"]) == "team_eng"
    end
  end

  describe "users root query and displayName" do
    test "lists users with displayName resolved from name", %{conn: conn} do
      body = gql(conn, "{ users { nodes { id name email displayName } } }")
      nodes = get_in(body, ["data", "users", "nodes"])
      hakan = Enum.find(nodes, &(&1["id"] == "user_hakan"))

      assert hakan["name"] == "Håkan Niska"
      assert hakan["displayName"] == "Håkan Niska"
    end

    test "viewer exposes displayName", %{conn: conn} do
      body = gql(conn, "{ viewer { id displayName } }")
      assert get_in(body, ["data", "viewer", "displayName"]) == "Håkan Niska"
    end
  end

  describe "workflowStates root query" do
    test "lists every workflow state across the org", %{conn: conn} do
      body = gql(conn, "{ workflowStates { nodes { id name type } } }")
      names = body |> get_in(["data", "workflowStates", "nodes"]) |> Enum.map(& &1["name"])

      assert "Todo" in names
      assert "Done" in names
      assert length(names) == 10
    end

    test "filters by team key", %{conn: conn} do
      query =
        ~s|{ workflowStates(filter: { team: { key: { eq: "ENG" } } }) { nodes { name team { key } } } }|

      body = gql(conn, query)
      nodes = get_in(body, ["data", "workflowStates", "nodes"])

      assert length(nodes) == 10
      assert Enum.all?(nodes, &(get_in(&1, ["team", "key"]) == "ENG"))
    end

    test "filters by name", %{conn: conn} do
      query = ~s|{ workflowStates(filter: { name: { eq: "In Progress" } }) { nodes { name } } }|
      body = gql(conn, query)
      nodes = get_in(body, ["data", "workflowStates", "nodes"])

      assert nodes == [%{"name" => "In Progress"}]
    end

    test "exposes each state's position (real Linear WorkflowState.position)", %{conn: conn} do
      query = ~s|{ workflowStates(filter: { name: { eq: "Todo" } }) { nodes { name position } } }|
      body = gql(conn, query)

      assert get_in(body, ["data", "workflowStates", "nodes"]) ==
               [%{"name" => "Todo", "position" => 2.0}]
    end
  end

  describe "issues filter by number" do
    test "filters issues by number.eq (real Linear IssueFilter.number)", %{conn: conn} do
      body = gql(conn, ~s|{ issues(filter: { number: { eq: 1 } }) { nodes { identifier } } }|)

      assert get_in(body, ["data", "issues", "nodes"]) == [%{"identifier" => "ENG-1"}]
    end
  end

  describe "viewer assignedIssues" do
    test "lists the viewer's assigned issues (real Linear User.assignedIssues)", %{conn: conn} do
      body = gql(conn, ~s|{ viewer { assignedIssues(first: 10) { nodes { identifier } } } }|)
      nodes = get_in(body, ["data", "viewer", "assignedIssues", "nodes"])

      assert %{"identifier" => "ENG-1"} in nodes
    end
  end

  describe "Comment.user" do
    test "resolves a comment's author", %{conn: conn} do
      Repo.insert!(%Comment{
        id: "comment_1",
        issue_id: "issue_eng_1",
        user_id: "user_hakan",
        body: "Looks good"
      })

      query = ~s|{ issue(id: "ENG-1") { comments { nodes { body user { id name } } } } }|
      body = gql(conn, query)
      nodes = get_in(body, ["data", "issue", "comments", "nodes"])
      comment = Enum.find(nodes, &(&1["body"] == "Looks good"))

      assert comment["user"] == %{"id" => "user_hakan", "name" => "Håkan Niska"}
    end
  end

  describe "Comment.url" do
    # Regression for the ENG-10 fidelity gap: `Comment.url` is a real Linear field
    # (schema_reference.graphql), so an agent querying it is correct — the simulator
    # just hadn't implemented it. The permalink mirrors the parent issue's url.
    test "resolves to the issue permalink with a comment fragment", %{conn: conn} do
      Repo.insert!(%Comment{
        id: "comment_url_1",
        issue_id: "issue_eng_1",
        user_id: "user_hakan",
        body: "With a url"
      })

      query = ~s|{ issue(id: "ENG-1") { comments { nodes { id body url } } } }|
      body = gql(conn, query)
      nodes = get_in(body, ["data", "issue", "comments", "nodes"])
      comment = Enum.find(nodes, &(&1["id"] == "comment_url_1"))

      assert comment["url"] == "https://linear.app/acme/issue/ENG-1#comment-comment_url_1"
    end

    test "commentCreate returns the new comment's url", %{conn: conn} do
      mutation = """
      mutation($issueId: String!, $body: String!) {
        commentCreate(input: { issueId: $issueId, body: $body }) {
          success
          comment { id url }
        }
      }
      """

      body = gql(conn, mutation, %{"issueId" => "issue_eng_1", "body" => "hello"})
      comment = get_in(body, ["data", "commentCreate", "comment"])

      assert comment["url"] == "https://linear.app/acme/issue/ENG-1#comment-#{comment["id"]}"
    end
  end
end
