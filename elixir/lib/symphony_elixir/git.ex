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

  @default_timeout_ms 60_000

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

  @typedoc "Per-turn working-tree probe result (IDE-211 Layer 1 progress signals)."
  @type tree_signals :: %{
          hash: String.t(),
          empty: boolean(),
          head: String.t() | nil,
          commits_since: non_neg_integer()
        }

  @doc """
  Read the cheap per-turn progress signals off a workspace in a single
  non-mutating `sh` invocation (IDE-211 Layer 1).

  Returns:

    * `hash` — a content hash of the full working tree (tracked **and**
      untracked), computed via `git write-tree` against a throwaway index so the
      real index/HEAD/working tree are never touched. Identical across turns ⇔
      the agent changed nothing.
    * `empty` — `true` when `git status --porcelain` is empty (clean tree). This
      is the empty-tree guard `:stuck_state` depends on.
    * `head` — the current `HEAD` sha (or `nil` on an unborn branch).
    * `commits_since` — `git rev-list --count <marker>..HEAD` when `marker` is a
      non-empty sha reachable from HEAD; `0` when `marker` is `nil` (first probe,
      before a dispatch marker is captured) or the range can't be computed.

  Best-effort and side-effect-free: like `preserve_uncommitted_work/4` it runs
  under a `Task` timeout so a slow/locked repo degrades to `{:error, _}` (the
  caller leaves the prior assessment unchanged) rather than wedging the loop.
  """
  @spec working_tree_signals(Path.t(), String.t() | nil, worker_host(), pos_integer()) ::
          {:ok, tree_signals()} | {:error, term()}
  def working_tree_signals(workspace, marker, worker_host \\ nil, timeout_ms \\ @default_timeout_ms)
      when is_binary(workspace) do
    script = build_signals_script(marker)

    case run_script(workspace, script, worker_host, timeout_ms) do
      {:ok, {output, 0}} -> parse_signals(output)
      {:ok, {output, status}} -> {:error, {:git_failed, status, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # One `sh` script: capture porcelain (empty bit), snapshot the tree to a sha
  # via the throwaway-index `write-tree` primitive (captures untracked files,
  # mutates nothing), read HEAD, and — only when a marker was supplied — count
  # commits since dispatch. Machine-readable markers keep the Elixir side off
  # git's human output.
  @spec build_signals_script(String.t() | nil) :: String.t()
  defp build_signals_script(marker) do
    marker_literal = esc(marker || "")

    """
    if [ ! -d .git ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo __SYMPHONY_NOT_GIT__
      exit 0
    fi
    PORC=$(git status --porcelain)
    TMPIDX="$(mktemp)"
    trap 'rm -f "$TMPIDX"' EXIT
    rm -f "$TMPIDX"
    cp "$(git rev-parse --git-dir)/index" "$TMPIDX" 2>/dev/null || true
    export GIT_INDEX_FILE="$TMPIDX"
    git add -A >/dev/null 2>&1 || true
    TREE=$(git write-tree)
    HEAD=$(git rev-parse --verify -q HEAD 2>/dev/null || true)
    MARKER=#{marker_literal}
    COUNT=0
    if [ -n "$HEAD" ] && [ -n "$MARKER" ]; then
      COUNT=$(git rev-list --count "$MARKER"..HEAD 2>/dev/null || echo 0)
    fi
    printf '__SYMPHONY_TREE__ %s\\n' "$TREE"
    if [ -z "$PORC" ]; then printf '__SYMPHONY_EMPTY__ 1\\n'; else printf '__SYMPHONY_EMPTY__ 0\\n'; fi
    printf '__SYMPHONY_HEAD__ %s\\n' "$HEAD"
    printf '__SYMPHONY_COUNT__ %s\\n' "$COUNT"
    """
  end

  @spec parse_signals(String.t()) :: {:ok, tree_signals()} | {:error, term()}
  defp parse_signals(output) do
    if String.contains?(output, "__SYMPHONY_NOT_GIT__") do
      {:error, :not_a_git_repo}
    else
      parse_signal_fields(output)
    end
  end

  @spec parse_signal_fields(String.t()) :: {:ok, tree_signals()} | {:error, term()}
  defp parse_signal_fields(output) do
    with [_, tree] <- Regex.run(~r/__SYMPHONY_TREE__\s+([0-9a-f]{7,64})/, output),
         [_, empty] <- Regex.run(~r/__SYMPHONY_EMPTY__\s+([01])/, output) do
      {:ok,
       %{
         hash: tree,
         empty: empty == "1",
         head: parse_head(output),
         commits_since: parse_count(output)
       }}
    else
      _ -> {:error, {:git_unexpected_output, String.trim(output)}}
    end
  end

  @spec parse_head(String.t()) :: String.t() | nil
  defp parse_head(output) do
    case Regex.run(~r/__SYMPHONY_HEAD__\s+([0-9a-f]{7,64})/, output) do
      [_, sha] -> sha
      _ -> nil
    end
  end

  @spec parse_count(String.t()) :: non_neg_integer()
  defp parse_count(output) do
    case Regex.run(~r/__SYMPHONY_COUNT__\s+(\d+)/, output) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  @doc """
  Read-only diff evidence for the Layer 2 overseer (IDE-212): `git diff HEAD
  --stat` followed by the full `git diff HEAD` patch, both captured in one
  non-mutating `sh` invocation. The combined output is truncated to
  `byte_limit` bytes (head-biased — the `--stat` summary plus the start of the
  patch survive). Returns `{:ok, ""}` on a clean tree.

  Touches nothing: no index copy, no `add`, no HEAD/branch/working-tree changes.
  Best-effort and timeout-bounded like the sibling probes, so a slow/locked repo
  degrades to `{:error, _}` rather than wedging the caller.
  """
  @spec diff_summary(Path.t(), worker_host(), non_neg_integer(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def diff_summary(workspace, worker_host \\ nil, byte_limit \\ 16_384, timeout_ms \\ @default_timeout_ms)
      when is_binary(workspace) and is_integer(byte_limit) and byte_limit >= 0 do
    script = build_diff_script()

    case run_script(workspace, script, worker_host, timeout_ms) do
      {:ok, {output, 0}} -> {:ok, truncate_head(output, byte_limit)}
      {:ok, {output, status}} -> {:error, {:git_failed, status, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `git diff HEAD` covers tracked edits (staged + unstaged) against the last
  # commit. Untracked files are not in the diff, but the porcelain/`--stat`
  # surface and the overseer's other evidence (logs, transcript) cover the new
  # work; keeping this to a single read-only `diff` keeps the probe trivially safe.
  @spec build_diff_script() :: String.t()
  defp build_diff_script do
    """
    if [ ! -d .git ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo __SYMPHONY_NOT_GIT__
      exit 0
    fi
    if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
      git diff --stat 2>/dev/null || true
      git diff 2>/dev/null || true
      exit 0
    fi
    git diff HEAD --stat
    git diff HEAD
    """
  end

  @spec truncate_head(String.t(), non_neg_integer()) :: String.t()
  defp truncate_head(output, byte_limit) do
    trimmed = String.trim(output)

    cond do
      String.contains?(trimmed, "__SYMPHONY_NOT_GIT__") -> ""
      byte_size(trimmed) <= byte_limit -> trimmed
      true -> trim_invalid_tail(binary_part(trimmed, 0, byte_limit)) <> "\n…[truncated]"
    end
  end

  # `binary_part/3` can split a multibyte UTF-8 codepoint; drop the dangling
  # bytes so the result is always a valid string.
  @spec trim_invalid_tail(binary()) :: String.t()
  defp trim_invalid_tail(bin) do
    cond do
      String.valid?(bin) -> bin
      byte_size(bin) == 0 -> ""
      true -> trim_invalid_tail(binary_part(bin, 0, byte_size(bin) - 1))
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
    if [ ! -d .git ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
      echo __SYMPHONY_NOT_GIT__
      exit 0
    fi
    if [ -z "$(git status --porcelain)" ]; then
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
