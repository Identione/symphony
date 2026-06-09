defmodule SymphonyElixir.Linear.Pagination do
  @moduledoc false
  # Walks Linear's `pageInfo { hasNextPage endCursor }` cursor pagination with
  # two guards that callers should not have to re-implement:
  #
  #   * a hard `@max_pages` cap so a buggy/malicious server advertising
  #     `hasNextPage: true` forever cannot drive `Linear.Adapter` /
  #     `Linear.Client` into unbounded recursion (each iteration costs an HTTP
  #     round-trip and a rate-limit hit), and
  #   * detection of a stuck `endCursor` (cursor identical to the cursor we
  #     just used to fetch the current page), surfaced as the more diagnostic
  #     `:linear_stuck_cursor` so the failure mode is distinguishable from a
  #     simple cap exhaustion (IDE-104).
  #
  # At `@comments_page_size`/`@issue_page_size` of 50, a cap of 20 pages allows
  # up to ~1000 items per resource before signalling exhaustion, which is well
  # above any expected real-world Linear page count for the resources we walk.

  @max_pages 20

  @type page_info :: %{
          required(:has_next_page) => boolean(),
          required(:end_cursor) => String.t() | nil
        }

  @type fetch_fun ::
          (String.t() | nil ->
             {:ok, list(), page_info()} | {:error, term()})

  @spec max_pages() :: pos_integer()
  def max_pages, do: @max_pages

  @spec paginate(fetch_fun(), keyword()) :: {:ok, list()} | {:error, term()}
  def paginate(fetch_page, opts \\ []) when is_function(fetch_page, 1) and is_list(opts) do
    max_pages = Keyword.get(opts, :max_pages, @max_pages)
    walk(fetch_page, nil, [], 1, max_pages, nil)
  end

  defp walk(_fetch_page, _cursor, _acc, page_num, max_pages, _prev_end_cursor)
       when page_num > max_pages do
    {:error, :linear_pagination_exhausted}
  end

  defp walk(fetch_page, cursor, acc, page_num, max_pages, prev_end_cursor) do
    case fetch_page.(cursor) do
      {:ok, items, page_info} when is_list(items) and is_map(page_info) ->
        acc = Enum.reverse(items, acc)

        case next_cursor(page_info, prev_end_cursor) do
          :done -> {:ok, Enum.reverse(acc)}
          {:ok, next} -> walk(fetch_page, next, acc, page_num + 1, max_pages, next)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_cursor(%{has_next_page: true, end_cursor: end_cursor}, end_cursor)
       when is_binary(end_cursor) and byte_size(end_cursor) > 0,
       do: {:error, :linear_stuck_cursor}

  defp next_cursor(%{has_next_page: true, end_cursor: end_cursor}, _prev_end_cursor)
       when is_binary(end_cursor) and byte_size(end_cursor) > 0,
       do: {:ok, end_cursor}

  defp next_cursor(%{has_next_page: true}, _prev_end_cursor),
    do: {:error, :linear_missing_end_cursor}

  defp next_cursor(_page_info, _prev_end_cursor), do: :done
end
