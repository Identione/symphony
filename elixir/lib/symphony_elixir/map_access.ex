defmodule SymphonyElixir.MapAccess do
  @moduledoc """
  First-match key lookup and path traversal over maps whose keys may be either
  atoms or strings — the recurring shape when reading provider payloads that mix
  JSON (string keys) and internally-built (atom keys) maps.
  """

  @doc """
  Returns the first non-nil value found by trying each key in order, or `nil`.
  """
  @spec value(map() | term(), [term()]) :: term()
  def value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  def value(_map, _keys), do: nil

  @doc """
  Walks `path` through nested maps, accepting an atom step that resolves to a
  string key. Returns `nil` as soon as a step is missing.
  """
  @spec at_path(map() | term(), [term()]) :: term()
  def at_path(map, path) when is_map(map) and is_list(path) do
    Enum.reduce_while(path, map, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) ->
          {:cont, Map.get(acc, key)}

        is_atom(key) and is_map(acc) and Map.has_key?(acc, Atom.to_string(key)) ->
          {:cont, Map.get(acc, Atom.to_string(key))}

        true ->
          {:halt, nil}
      end
    end)
  end

  def at_path(_map, _path), do: nil
end
