defmodule SymphonyElixir.GitHost.Memory do
  @moduledoc """
  In-memory `SymphonyElixir.GitHost` adapter for tests. Reads canned responses
  from the application environment so a test can drive the merge-gate without a
  real `gh`/GitHub:

  - `:memory_git_host_gate_active` — boolean (default `true`).
  - `:memory_git_host_pr_merged` — `%{pr_url => {:ok, boolean} | {:error, term} | boolean}`.
  - `:memory_git_host_default` — fallback for PR URLs absent from the map
    (default `{:ok, false}`).
  """

  @behaviour SymphonyElixir.GitHost

  @spec gate_active?() :: boolean()
  def gate_active? do
    Application.get_env(:symphony_elixir, :memory_git_host_gate_active, true) == true
  end

  @spec pr_merged?(String.t() | nil, String.t()) :: {:ok, boolean()} | {:error, term()}
  def pr_merged?(_repo, pr_url) do
    responses = Application.get_env(:symphony_elixir, :memory_git_host_pr_merged, %{})
    default = Application.get_env(:symphony_elixir, :memory_git_host_default, {:ok, false})

    case Map.get(responses, pr_url, default) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
      bool when is_boolean(bool) -> {:ok, bool}
      _other -> {:error, :memory_git_host_bad_response}
    end
  end
end
