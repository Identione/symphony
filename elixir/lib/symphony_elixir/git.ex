defmodule SymphonyElixir.Git do
  @moduledoc """
  Non-destructive git helpers for preserving a coding agent's uncommitted work
  before a session is stopped (budget-pressure cutoff, Backlog/non-active stop,
  `agent.max_turns` cap).

  The single public entry point, `preserve_uncommitted_work/4`, snapshots a dirty
  working tree to a real commit reachable from `refs/symphony/wip/<id>` **without
  touching HEAD, the current branch, or the working tree**. It uses the temp-index
  `commit-tree` primitive (copy `.git/index` to a throwaway `GIT_INDEX_FILE`,
  `git add -A`, `git write-tree`, `git commit-tree`) so that *untracked* files are
  captured too — a plain `git stash create` would silently drop them.

  Operators recover preserved work with `git log refs/symphony/wip/<ID>` (or, when
  `preserve_uncommitted_work_branch` is enabled, `git branch --list 'symphony/wip/*'`).
  """

  alias SymphonyElixir.SSH

  require Logger

  @type worker_host :: String.t() | nil
  @type preserve_result ::
          {:ok, :clean | {:preserved, commit_sha :: String.t(), ref :: String.t()}}
          | {:error, term()}

  @typedoc """
  Read-only working-tree probe used by the per-turn progress signals (Layer 1,
  IDE-189). `:hash` is `sha256(git status --porcelain ++ git diff)` — a stable
  fingerprint of the dirty working tree; `:empty` is `true` when the tree has no
  pending changes; `:head` is the current HEAD sha (or `nil` on an unborn
  branch); `:commits_since` counts commits on `marker..HEAD` (`0` when no marker
  was supplied or HEAD is unborn).
  """
  @type tree_probe :: %{
          hash: String.t(),
          empty: boolean(),
          head: String.t() | nil,
          commits_since: non_neg_integer()
        }

  @default_timeout_ms 60_000
  @default_probe_timeout_ms 2_000

  @not_a_git_repo_guard """
  if [ ! -d .git ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo __SYMPHONY_NOT_GIT__
    exit 0
  fi
  """

  @doc """
  Non-destructively snapshot a dirty working tree to a WIP commit + ref.

  Returns `{:ok, :clean}` on an unchanged tree (no ref is created and no empty
  commit is written), `{:ok, {:preserved, sha, ref}}` once the snapshot exists,
  or `{:error, reason}` on any failure. Preservation is best-effort: callers
  should log and swallow errors rather than letting them block a stop or retry.

  Options:

    * `:branch` — also create a visible `symphony/wip/<id>` branch (the ref is
      always created regardless).
    * `:reason` — short tag included in the commit message (e.g. `:max_turns`).
    * `:timeout_ms` — git-shell timeout; defaults to #{@default_timeout_ms}.
  """
  @spec preserve_uncommitted_work(Path.t(), String.t(), worker_host(), keyword()) ::
          preserve_result()
  def preserve_uncommitted_work(workspace, issue_identifier, worker_host \\ nil, opts \\ [])
      when is_binary(workspace) and is_binary(issue_identifier) do
    safe_id = safe_ref_component(issue_identifier)
    ref = "refs/symphony/wip/#{safe_id}"
    branch = "symphony/wip/#{safe_id}"
    message = commit_message(issue_identifier, Keyword.get(opts, :reason, :stop))
    script = build_script(message, ref, branch, Keyword.get(opts, :branch, false))
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case run_script(workspace, script, worker_host, timeout_ms) do
      {:ok, {output, 0}} -> parse_output(output, ref)
      {:ok, {output, status}} -> {:error, {:git_failed, status, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read-only working-tree probe for the per-turn progress signals (Layer 1,
  IDE-189). Computes — in a single `sh` invocation, off the agent's critical
  path — the dirty-tree fingerprint, the empty-tree bit, the current HEAD, and
  the commit count on `marker..HEAD`.

  Unlike `preserve_uncommitted_work/4` this **never writes** to the repo (no
  index, ref, or object mutation). On a slow or locked repo the timeout fires
  and the caller gets `{:error, :timeout}`, leaving the prior assessment
  unchanged rather than stalling the orchestrator loop.

  `marker` is the dispatch-time HEAD captured once per session; pass `nil` to
  skip the commit count (first probe, before a marker exists).
  """
  @spec working_tree_probe(Path.t(), String.t() | nil, worker_host(), pos_integer()) ::
          {:ok, tree_probe()} | {:error, term()}
  def working_tree_probe(workspace, marker \\ nil, worker_host \\ nil, timeout_ms \\ @default_probe_timeout_ms)
      when is_binary(workspace) do
    script = build_probe_script(marker)

    case run_script(workspace, script, worker_host, timeout_ms) do
      {:ok, {output, 0}} -> parse_probe_output(output)
      {:ok, {output, status}} -> {:error, {:git_failed, status, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Emits one machine-readable marker line so the Elixir side never parses git's
  # human-facing output. `git diff` (tracked unstaged changes) is concatenated
  # with `git status --porcelain` (which also names untracked files) before
  # hashing, so any per-turn edit — tracked or untracked — moves the hash.
  @spec build_probe_script(String.t() | nil) :: String.t()
  defp build_probe_script(marker) do
    commits_clause =
      if is_binary(marker) and marker != "" do
        """
        if [ -n "$HEAD" ]; then
          COMMITS=$(git rev-list --count #{esc(marker)}..HEAD 2>/dev/null || echo 0)
        fi
        """
      else
        ""
      end

    """
    #{@not_a_git_repo_guard}PORCELAIN="$(git status --porcelain)"
    if [ -z "$PORCELAIN" ]; then EMPTY=1; else EMPTY=0; fi
    HASH="$( { git status --porcelain; git diff; } | sha256sum | cut -d' ' -f1 )"
    HEAD="$(git rev-parse --verify -q HEAD 2>/dev/null || echo)"
    COMMITS=0
    #{commits_clause}echo "__SYMPHONY_PROBE__ empty=$EMPTY hash=$HASH head=$HEAD commits=$COMMITS"
    """
  end

  @spec parse_probe_output(String.t()) :: {:ok, tree_probe()} | {:error, term()}
  defp parse_probe_output(output) do
    if String.contains?(output, "__SYMPHONY_NOT_GIT__") do
      {:error, :not_a_git_repo}
    else
      case Regex.run(
             ~r/__SYMPHONY_PROBE__ empty=([01]) hash=([0-9a-f]+) head=(\S*) commits=(\d+)/,
             output
           ) do
        [_, empty, hash, head, commits] ->
          {:ok,
           %{
             hash: hash,
             empty: empty == "1",
             head: if(head == "", do: nil, else: head),
             commits_since: String.to_integer(commits)
           }}

        _ ->
          {:error, {:git_unexpected_output, String.trim(output)}}
      end
    end
  end

  # Distinct from `Workspace.safe_identifier/1` (which preserves case and forbids
  # `/`): a ref path component is lowercased and keeps `/` as a path separator.
  @spec safe_ref_component(String.t()) :: String.t()
  defp safe_ref_component(identifier) do
    identifier
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._\/-]/, "_")
  end

  @spec commit_message(String.t(), atom() | String.t()) :: String.t()
  defp commit_message(identifier, reason) do
    "symphony: WIP snapshot for #{identifier} (#{reason}) #{DateTime.utc_now() |> DateTime.to_iso8601()}"
  end

  # One `sh` script run locally (cwd = workspace) or remotely (wrapped with `cd`).
  # Emits machine-readable markers so the Elixir side can classify the outcome
  # without parsing git's human-facing output.
  @spec build_script(String.t(), String.t(), String.t(), boolean()) :: String.t()
  defp build_script(message, ref, branch, create_branch?) do
    branch_line =
      if create_branch?, do: "git branch -f #{esc(branch)} \"$WIP\"\n", else: ""

    """
    set -e
    export GIT_AUTHOR_NAME=symphony
    export GIT_AUTHOR_EMAIL=symphony@localhost
    export GIT_COMMITTER_NAME=symphony
    export GIT_COMMITTER_EMAIL=symphony@localhost
    #{@not_a_git_repo_guard}if [ -z "$(git status --porcelain)" ]; then
      echo __SYMPHONY_CLEAN__
      exit 0
    fi
    TMPIDX="$(mktemp)"
    # Clean up the throwaway index on any exit, so a failing git step under
    # `set -e` cannot leak it into $TMPDIR.
    trap 'rm -f "$TMPIDX"' EXIT
    rm -f "$TMPIDX"
    cp "$(git rev-parse --git-dir)/index" "$TMPIDX" 2>/dev/null || true
    export GIT_INDEX_FILE="$TMPIDX"
    git add -A
    TREE=$(git write-tree)
    if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
      WIP=$(git commit-tree "$TREE" -p HEAD -m #{esc(message)})
    else
      WIP=$(git commit-tree "$TREE" -m #{esc(message)})
    fi
    git update-ref #{esc(ref)} "$WIP"
    #{branch_line}echo "__SYMPHONY_WIP__ $WIP"
    """
  end

  @spec parse_output(String.t(), String.t()) :: preserve_result()
  defp parse_output(output, ref) do
    cond do
      String.contains?(output, "__SYMPHONY_NOT_GIT__") ->
        {:error, :not_a_git_repo}

      String.contains?(output, "__SYMPHONY_CLEAN__") ->
        {:ok, :clean}

      true ->
        case Regex.run(~r/__SYMPHONY_WIP__\s+([0-9a-f]{7,40})/, output) do
          [_, sha] -> {:ok, {:preserved, sha, ref}}
          _ -> {:error, {:git_unexpected_output, String.trim(output)}}
        end
    end
  end

  # Local: `sh -c` with cwd = workspace. Remote: SSH session that `cd`s first.
  # Both are wrapped in a Task so the cutoff timeout is enforced and a hung git
  # process can never wedge the orchestrator.
  @spec run_script(Path.t(), String.t(), worker_host(), pos_integer()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  defp run_script(workspace, script, nil, timeout_ms) do
    with_timeout(timeout_ms, fn ->
      {:ok, System.cmd("sh", ["-c", script], cd: workspace, stderr_to_stdout: true)}
    end)
  end

  defp run_script(workspace, script, worker_host, timeout_ms) when is_binary(worker_host) do
    command = "cd #{esc(workspace)} && #{script}"
    with_timeout(timeout_ms, fn -> SSH.run(worker_host, command, stderr_to_stdout: true) end)
  end

  @spec with_timeout(pos_integer(), (-> term())) :: term()
  defp with_timeout(timeout_ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:git_task_exit, reason}}
    end
  end

  @spec esc(String.t()) :: String.t()
  defp esc(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
