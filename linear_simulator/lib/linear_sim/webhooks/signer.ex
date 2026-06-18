defmodule LinearSim.Webhooks.Signer do
  @moduledoc """
  Signs the exact raw webhook body with HMAC-SHA256, matching Linear's
  `Linear-Signature` header (docs/linear-sim.md §19). The body must be signed
  and sent as the same binary — never re-encoded.
  """

  @doc "Returns the lowercase hex HMAC-SHA256 of `raw_body` under `secret`."
  @spec sign_body!(binary(), binary()) :: String.t()
  def sign_body!(raw_body, secret) when is_binary(raw_body) and is_binary(secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, raw_body)
    |> Base.encode16(case: :lower)
  end
end
