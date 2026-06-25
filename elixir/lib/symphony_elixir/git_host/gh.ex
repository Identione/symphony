defmodule SymphonyElixir.GitHost.Gh do
  @moduledoc """
  Real `SymphonyElixir.GitHost` adapter. Shells `gh` to read a PR's merge
  state, with a bounded timeout (mirrors the `Git.with_timeout/2` pattern) so a
  hung `gh` process can never wedge the orchestrator's poll loop.
  """

  @behaviour SymphonyElixir.GitHost

  alias SymphonyElixir.Config

  @pr_view_timeout_ms 15_000

  @spec gate_active?() :: boolean()
  def gate_active? do
    case repo_url() do
      url when is_binary(url) -> github_url?(url) and gh_available?()
      _ -> false
    end
  end

  @spec pr_merged?(String.t() | nil, String.t()) :: {:ok, boolean()} | {:error, term()}
  def pr_merged?(_repo, pr_url) when is_binary(pr_url) and pr_url != "" do
    case run_gh(["pr", "view", pr_url, "--json", "state"]) do
      {:ok, {output, 0}} -> parse_state(output)
      {:ok, {output, status}} -> {:error, {:gh_exit, status, output |> to_string() |> String.trim()}}
      {:error, reason} -> {:error, reason}
    end
  end

  def pr_merged?(_repo, _pr_url), do: {:error, :missing_pr_url}

  # `gh pr view --json state` reports the PR's GitHub state; "MERGED" is the
  # only positively-landed value (OPEN/CLOSED both mean "not merged").
  @spec parse_state(String.t()) :: {:ok, boolean()} | {:error, term()}
  defp parse_state(output) do
    case Jason.decode(output) do
      {:ok, %{"state" => state}} when is_binary(state) ->
        {:ok, String.upcase(state) == "MERGED"}

      {:ok, _other} ->
        {:error, :gh_unexpected_output}

      {:error, reason} ->
        {:error, {:gh_decode_error, reason}}
    end
  end

  @spec run_gh([String.t()]) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  defp run_gh(args) do
    task = Task.async(fn -> {:ok, System.cmd("gh", args, stderr_to_stdout: true)} end)

    case Task.yield(task, @pr_view_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:gh_task_exit, reason}}
    end
  end

  @spec repo_url() :: String.t() | nil
  defp repo_url, do: Config.settings!().repo.url

  @spec github_url?(String.t()) :: boolean()
  defp github_url?(url) when is_binary(url), do: String.contains?(url, "github.com")

  @spec gh_available?() :: boolean()
  defp gh_available?, do: not is_nil(System.find_executable("gh"))
end
