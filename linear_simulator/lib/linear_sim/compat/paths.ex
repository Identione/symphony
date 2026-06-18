defmodule LinearSim.Compat.Paths do
  @moduledoc """
  Shared response-path walking for operation replay (docs/linear-sim.md §7).

  Both `test/linear_sim_web/operation_replay_test.exs` (the HTTP/plug path) and
  `mix linear_sim.replay_operations` (the `Absinthe.run/3` path) assert against
  `expected.paths` from an operation's `metadata.json`. This is the single
  implementation both call so the two replay surfaces cannot drift.
  """

  @typedoc "A single failed expectation: the dotted path, the expected value, the actual value."
  @type mismatch :: {path :: String.t(), expected :: term(), actual :: term()}

  @doc "Resolves a dotted path string (e.g. `\"data.issues.nodes.0.id\"`) against a decoded response."
  @spec get(term(), String.t()) :: term()
  def get(value, path) when is_binary(path), do: get_path(value, String.split(path, "."))

  @doc """
  Resolves a path expressed as a list of segments. Numeric segments index into
  lists; everything else is a map key. A miss (wrong key, out-of-range index, or
  a scalar where a container was expected) resolves to `nil`.
  """
  @spec get_path(term(), [String.t()]) :: term()
  def get_path(value, []), do: value

  def get_path(value, [segment | rest]) do
    next =
      case Integer.parse(segment) do
        {index, ""} when is_list(value) -> Enum.at(value, index)
        _ when is_map(value) -> Map.get(value, segment)
        _ -> nil
      end

    get_path(next, rest)
  end

  @doc """
  Compares a decoded response against a map of `dotted_path => expected_value`.
  Returns `:ok` when every path matches, otherwise `{:error, mismatches}`.
  """
  @spec compare(term(), %{optional(String.t()) => term()}) :: :ok | {:error, [mismatch()]}
  def compare(response, expected_paths) when is_map(expected_paths) do
    mismatches =
      Enum.flat_map(expected_paths, fn {path, expected} ->
        actual = get(response, path)

        if actual == expected, do: [], else: [{path, expected, actual}]
      end)

    if mismatches == [], do: :ok, else: {:error, mismatches}
  end
end
