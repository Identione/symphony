defmodule LinearSim.GraphQL.Connection do
  @moduledoc """
  Builds Linear-like Relay connection payloads from an ordered list of nodes
  (docs/linear-sim.md §13).

  Unlike the doc's initial stub, this applies `first`/`after` and returns an
  accurate `has_next_page` so the `many_issues` scenario exercises symphony's
  pagination loop. `last`/`before` are accepted but not yet implemented.
  """

  @type node_t :: %{:id => String.t(), optional(atom()) => any()}

  @doc "Wraps an ordered node list into a connection, applying `first`/`after`."
  @spec from_nodes([node_t()], map()) :: map()
  def from_nodes(nodes, args \\ %{}) do
    {page, has_next} =
      nodes
      |> drop_until_after(Map.get(args, :after))
      |> take_first(Map.get(args, :first))

    edges = Enum.map(page, fn node -> %{cursor: cursor_for(node), node: node} end)

    %{
      nodes: page,
      edges: edges,
      page_info: %{
        start_cursor: edges |> List.first() |> edge_cursor(),
        end_cursor: edges |> List.last() |> edge_cursor(),
        has_previous_page: false,
        has_next_page: has_next
      }
    }
  end

  @doc "Encodes a stable opaque cursor for a node."
  @spec cursor_for(node_t()) :: String.t()
  def cursor_for(%{id: id}), do: Base.encode64("cursor:#{id}")

  defp drop_until_after(nodes, nil), do: nodes
  defp drop_until_after(nodes, ""), do: nodes

  defp drop_until_after(nodes, cursor) do
    case decode_cursor(cursor) do
      nil ->
        nodes

      id ->
        case Enum.split_while(nodes, fn node -> node.id != id end) do
          {_before, [_match | rest]} -> rest
          {_all, []} -> []
        end
    end
  end

  defp take_first(nodes, nil), do: {nodes, false}

  defp take_first(nodes, first) when is_integer(first) and first >= 0 do
    {Enum.take(nodes, first), length(nodes) > first}
  end

  defp take_first(nodes, _), do: {nodes, false}

  defp decode_cursor(cursor) do
    case Base.decode64(cursor) do
      {:ok, "cursor:" <> id} -> id
      _ -> nil
    end
  end

  defp edge_cursor(nil), do: nil
  defp edge_cursor(%{cursor: cursor}), do: cursor
end
