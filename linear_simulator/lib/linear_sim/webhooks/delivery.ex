defmodule LinearSim.Webhooks.Delivery do
  @moduledoc """
  Delivers a Linear-style webhook to a target URL (docs/linear-sim.md §19).

  The payload is encoded to a raw binary exactly once; that same binary is
  signed and sent. Short timeouts and a rescue clause keep failures clean when
  the target app is offline.
  """
  alias LinearSim.Webhooks.Signer

  @doc """
  Encodes `payload_map`, signs it, and POSTs it to `target_url`.

  `req_options` is merged into the `Req.post/2` call — used in tests to route to
  an in-process plug instead of the network.
  """
  @spec deliver(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def deliver(target_url, secret, payload_map, req_options \\ []) do
    raw_body = Jason.encode!(payload_map)
    signature = Signer.sign_body!(raw_body, secret)

    options =
      Keyword.merge(
        [
          url: target_url,
          body: raw_body,
          headers: [
            {"content-type", "application/json"},
            {"linear-signature", signature}
          ],
          receive_timeout: 5_000,
          connect_options: [timeout: 2_000],
          retry: false
        ],
        req_options
      )

    case Req.post(options) do
      {:ok, response} ->
        {:ok,
         %{
           status: :delivered,
           response_status: response.status,
           response_body: response.body,
           signature: signature,
           raw_body: raw_body
         }}

      {:error, reason} ->
        {:error,
         %{status: :failed, reason: inspect(reason), signature: signature, raw_body: raw_body}}
    end
  rescue
    exception ->
      {:error, %{status: :failed, reason: Exception.message(exception)}}
  end
end
