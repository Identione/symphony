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
end
