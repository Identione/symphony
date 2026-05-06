defmodule SymphonyElixir.Claude.Wire do
  @moduledoc """
  Line-delimited JSON wire protocol shared between Symphony and the Claude
  Agent SDK sidecar (SPEC.md §10.8).

  Pure encoding/decoding helpers — no IO, no process state.
  """

  @type symphony_to_sidecar ::
          %{required(:type) => binary(), optional(any()) => any()}

  @type sidecar_to_symphony :: %{required(:type) => atom(), optional(any()) => any()}

  @sidecar_envelope_types ~w(
    ready
    system_init
    assistant_message
    assistant_delta
    tool_call
    permission_request
    token_usage
    turn_end
    error
    log
  )

  @doc """
  Encode a Symphony→sidecar envelope as a single newline-terminated JSON line.
  """
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(%{type: type} = envelope) when is_binary(type) or is_atom(type) do
    payload = envelope |> Map.put(:type, to_string(type)) |> stringify_keys()

    case Jason.encode(payload) do
      {:ok, json} -> {:ok, json <> "\n"}
      {:error, reason} -> {:error, {:json_encode_error, reason}}
    end
  end

  def encode(_other), do: {:error, :missing_type_field}

  @doc """
  Decode a single sidecar→Symphony JSON line into a typed envelope map. The
  returned map's `:type` key is an atom drawn from the documented vocabulary;
  unknown types are rejected so callers do not silently mishandle them.
  """
  @spec decode(binary()) :: {:ok, sidecar_to_symphony()} | {:error, term()}
  def decode(line) when is_binary(line) do
    trimmed = String.trim(line)

    case Jason.decode(trimmed) do
      {:ok, %{"type" => type} = decoded} when type in @sidecar_envelope_types ->
        {:ok, atomize_envelope(decoded)}

      {:ok, %{"type" => type}} ->
        {:error, {:unknown_envelope, type}}

      {:ok, _other} ->
        {:error, :missing_type_field}

      {:error, reason} ->
        {:error, {:malformed_json, reason}}
    end
  end

  @doc """
  Split an accumulated stdio buffer into complete `\n`-terminated lines plus a
  trailing remainder that has not yet seen its newline.
  """
  @spec split_lines(binary()) :: {[binary()], binary()}
  def split_lines(buffer) when is_binary(buffer) do
    case String.split(buffer, "\n") do
      [single] -> {[], single}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp atomize_envelope(%{"type" => type} = decoded) do
    # `decode/1` already gated on `@sidecar_envelope_types` (whitelist), so the
    # input string is one of a fixed, vetted set — safe to convert to an atom.
    decoded
    |> Map.delete("type")
    |> Enum.reduce(%{type: envelope_type_atom(type)}, fn {key, value}, acc ->
      Map.put(acc, atomize_known_key(key), atomize_known_value(key, value))
    end)
  end

  defp envelope_type_atom("ready"), do: :ready
  defp envelope_type_atom("system_init"), do: :system_init
  defp envelope_type_atom("assistant_message"), do: :assistant_message
  defp envelope_type_atom("assistant_delta"), do: :assistant_delta
  defp envelope_type_atom("tool_call"), do: :tool_call
  defp envelope_type_atom("permission_request"), do: :permission_request
  defp envelope_type_atom("token_usage"), do: :token_usage
  defp envelope_type_atom("turn_end"), do: :turn_end
  defp envelope_type_atom("error"), do: :error
  defp envelope_type_atom("log"), do: :log

  @known_keys ~w(
    session_id
    text
    tool_use_id
    name
    input
    stop_reason
    num_turns
    usage
    error
    category
    permission_request_id
    request
    payload
    level
    message
    source
  )

  defp atomize_known_key(key) when is_binary(key) do
    if key in @known_keys, do: String.to_atom(key), else: key
  end

  @usage_keys ~w(input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens)

  defp atomize_known_value("usage", %{} = usage) do
    Enum.reduce(usage, %{}, fn {k, v}, acc ->
      key = if k in @usage_keys, do: String.to_atom(k), else: k
      Map.put(acc, key, v)
    end)
  end

  defp atomize_known_value(_key, value), do: value

  defp stringify_keys(value) when is_map(value) do
    for {k, v} <- value, into: %{} do
      {key_to_string(k), stringify_keys(v)}
    end
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)
end
