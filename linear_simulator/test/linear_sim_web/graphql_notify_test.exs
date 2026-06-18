defmodule LinearSimWeb.GraphQLNotifyTest do
  @moduledoc """
  GraphQL mutations must broadcast `:sim_changed` so open dashboard LiveViews
  refresh without a manual browser reload. Queries must not broadcast.
  """
  use LinearSimWeb.ConnCase, async: false

  alias Phoenix.PubSub

  @topic "sim:state"

  @create """
  mutation Create($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue { identifier title }
    }
  }
  """

  @list """
  query {
    issues { nodes { identifier } }
  }
  """

  test "issueCreate mutation broadcasts :sim_changed to subscribers", %{conn: conn} do
    :ok = PubSub.subscribe(LinearSim.PubSub, @topic)

    body =
      gql(conn, @create, %{
        "input" => %{"teamId" => "team_eng", "title" => "Auto refresh me"}
      })

    assert get_in(body, ["data", "issueCreate", "success"]) == true
    assert_receive :sim_changed, 1_000
  end

  test "queries do not broadcast :sim_changed", %{conn: conn} do
    :ok = PubSub.subscribe(LinearSim.PubSub, @topic)

    gql(conn, @list, %{})

    refute_receive :sim_changed, 200
  end
end
