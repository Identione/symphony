defmodule SymphonyElixir.Agent.Adapter do
  @moduledoc """
  Behaviour for coding-agent adapter implementations.

  See SPEC.md §10 for the contract. Conforming implementations:

    * `SymphonyElixir.Codex.AppServer` (Codex App-Server, §10.7)
    * `SymphonyElixir.Claude.AppServer` (Claude Agent SDK sidecar, §10.8)
  """

  @typedoc "Opaque adapter session handle returned from `start_session/2`."
  @type session :: map()

  @typedoc "Per-turn options forwarded to the adapter."
  @type turn_opts :: keyword()

  @doc """
  Start a long-lived adapter session in the per-issue workspace.

  `opts` MAY include `:worker_host` (binary | nil) when running over SSH.
  """
  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @doc """
  Run one turn against an existing adapter session, streaming events back via
  the `:on_message` option callback when supplied.
  """
  @callback run_turn(session :: session(), prompt :: String.t(), issue :: term(), opts :: turn_opts()) ::
              {:ok, map()} | {:error, term()}

  @doc "Stop the adapter session and release any subprocess resources."
  @callback stop_session(session :: session()) :: :ok
end
