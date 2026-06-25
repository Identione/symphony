defmodule SymphonyElixir.GitHost do
  @moduledoc """
  Adapter boundary for git-host (GitHub) read operations backing the
  merge-gate (§8.2). Mirrors `SymphonyElixir.Tracker`: a thin module that
  delegates to a configurable `adapter/0` so tests can inject a deterministic
  in-memory implementation.

  Two operations:

  - `gate_active?/0` — whether the merge-gate should hold dependency-resumed
    issues. Active only when GitHub is configured for this instance (a
    `github.com` `repo.url` remote) and the `gh` CLI is usable. When inactive
    (no repo, non-GitHub remote, or `gh` missing) the orchestrator never holds,
    so non-GitHub and test/sim setups behave exactly as before the gate.
  - `pr_merged?/2` — whether a blocker's PR has landed in the base branch.
  """

  @callback gate_active?() :: boolean()
  @callback pr_merged?(repo :: String.t() | nil, pr_url :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @spec gate_active?() :: boolean()
  def gate_active?, do: adapter().gate_active?()

  @spec pr_merged?(String.t() | nil, String.t()) :: {:ok, boolean()} | {:error, term()}
  def pr_merged?(repo, pr_url), do: adapter().pr_merged?(repo, pr_url)

  @spec adapter() :: module()
  def adapter do
    Application.get_env(:symphony_elixir, :git_host_adapter, SymphonyElixir.GitHost.Gh)
  end
end
