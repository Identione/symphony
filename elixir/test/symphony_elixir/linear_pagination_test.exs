defmodule SymphonyElixir.LinearPaginationTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Pagination

  defp track_calls(test_pid, ref, page_fn) do
    fn cursor ->
      send(test_pid, {ref, :fetch, cursor})
      page_fn.(cursor)
    end
  end

  test "returns accumulated items in encounter order when pagination terminates" do
    pages = [
      {[1, 2], %{has_next_page: true, end_cursor: "c1"}},
      {[3, 4], %{has_next_page: true, end_cursor: "c2"}},
      {[5], %{has_next_page: false, end_cursor: nil}}
    ]

    {:ok, agent} = Agent.start_link(fn -> pages end)

    fetch = fn _cursor ->
      Agent.get_and_update(agent, fn [{items, info} | rest] -> {{:ok, items, info}, rest} end)
    end

    assert {:ok, [1, 2, 3, 4, 5]} = Pagination.paginate(fetch)
  end

  test "cap exhaustion returns :linear_pagination_exhausted after exactly max_pages calls" do
    ref = make_ref()

    fetch =
      track_calls(self(), ref, fn cursor ->
        {:ok, [cursor || "first"], %{has_next_page: true, end_cursor: "c-#{System.unique_integer([:positive])}"}}
      end)

    assert {:error, :linear_pagination_exhausted} = Pagination.paginate(fetch, max_pages: 3)

    assert_receive {^ref, :fetch, nil}
    assert_receive {^ref, :fetch, "c-" <> _}
    assert_receive {^ref, :fetch, "c-" <> _}
    refute_receive {^ref, :fetch, _}, 50
  end

  test "stuck cursor is reported as :linear_stuck_cursor after two identical end_cursors" do
    ref = make_ref()

    fetch =
      track_calls(self(), ref, fn _cursor ->
        {:ok, [:item], %{has_next_page: true, end_cursor: "STUCK"}}
      end)

    assert {:error, :linear_stuck_cursor} = Pagination.paginate(fetch, max_pages: 50)

    # The stuck-cursor branch must fire before the cap, so we should see only
    # the two calls needed to detect a repeated end_cursor — not a long chain.
    assert_receive {^ref, :fetch, nil}
    assert_receive {^ref, :fetch, "STUCK"}
    refute_receive {^ref, :fetch, _}, 50
  end

  test "missing end_cursor with has_next_page: true is surfaced as :linear_missing_end_cursor" do
    fetch = fn _cursor -> {:ok, [:only], %{has_next_page: true, end_cursor: nil}} end

    assert {:error, :linear_missing_end_cursor} = Pagination.paginate(fetch)
  end

  test "propagates fetch errors verbatim" do
    fetch = fn _cursor -> {:error, :boom} end

    assert {:error, :boom} = Pagination.paginate(fetch)
  end

  test "treats a missing has_next_page field as terminal" do
    fetch = fn _cursor -> {:ok, [:a, :b], %{has_next_page: false, end_cursor: nil}} end

    assert {:ok, [:a, :b]} = Pagination.paginate(fetch)
  end

  test "max_pages/0 exposes the shared cap so call sites can document the budget" do
    assert is_integer(Pagination.max_pages()) and Pagination.max_pages() > 0
  end
end
