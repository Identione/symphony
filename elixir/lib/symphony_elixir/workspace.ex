defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, Git, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host),
           :ok <- maybe_copy_skills(workspace, issue_context, worker_host, created?) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, empty_workspace_needs_bootstrap?(workspace)}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp empty_workspace_needs_bootstrap?(workspace) do
    case Config.settings!().hooks.after_create do
      nil ->
        false

      _command ->
        case File.ls(workspace) do
          {:ok, []} -> true
          _ -> false
        end
    end
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    if dot_only_identifier?(safe_id) do
      {:error, {:unsafe_workspace_identifier, safe_id}}
    else
      root = Config.settings!().workspace.root
      joined = Path.join(root, safe_id)

      # `safe_id` can't contain "/" (see `safe_identifier/1`), so the only way
      # `joined` escapes `root` is via a dot-only segment — already rejected
      # above. This lexical check is defense-in-depth against future changes
      # to `safe_identifier/1`/`safe_id` construction; unlike the local branch,
      # remote paths can't be canonicalized to catch symlink escapes, so this
      # has to stay a string check.
      if String.length(joined) > String.length(root) and String.starts_with?(joined, root <> "/") do
        {:ok, joined}
      else
        {:error, {:unsafe_workspace_identifier, safe_id}}
      end
    end
  end

  defp dot_only_identifier?(safe_id) when is_binary(safe_id) do
    safe_id == "" or String.match?(safe_id, ~r/^\.+$/)
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true -> run_after_create_hook(hooks.after_create, workspace, issue_context, worker_host)
      false -> :ok
    end
  end

  defp run_after_create_hook(nil, _workspace, _issue_context, _worker_host), do: :ok

  defp run_after_create_hook(command, workspace, issue_context, worker_host) do
    case run_hook(command, workspace, issue_context, "after_create", worker_host) do
      :ok ->
        :ok

      {:error, reason} = error ->
        remove_created_workspace_after_failure(workspace, issue_context, worker_host, "after_create hook", reason)
        error
    end
  end

  defp remove_created_workspace_after_failure(workspace, issue_context, nil, stage, reason) do
    Logger.warning("Removing workspace after #{stage} failure #{issue_log_context(issue_context)} workspace=#{workspace} reason=#{inspect(reason)} worker_host=local")
    File.rm_rf(workspace)
    :ok
  end

  defp remove_created_workspace_after_failure(workspace, issue_context, worker_host, stage, reason)
       when is_binary(worker_host) do
    Logger.warning("Removing workspace after #{stage} failure #{issue_log_context(issue_context)} workspace=#{workspace} reason=#{inspect(reason)} worker_host=#{worker_host}")

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning(
          "Failed to remove workspace after #{stage} failure #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host} status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}"
        )

      {:error, cleanup_reason} ->
        Logger.warning("Failed to remove workspace after #{stage} failure #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host} reason=#{inspect(cleanup_reason)}")
    end

    :ok
  end

  # Auto-provisions `workspace.skills_source` (SPEC.md §9.3) into
  # `workspace.skills_targets` on every `create_for_issue/2` call — both fresh
  # creates and reuses, so a reused workspace's skills stay fresh. No-op when
  # `skills_source` is unset. Local-only: a remote `worker_host` is rejected
  # here as defense-in-depth (the config layer already refuses
  # `workspace.skills_source` + non-empty `worker.ssh_hosts` at parse time).
  # Repo-wins: the copy is additive per top-level entry — anything the target
  # repo already tracks at a given target (a whole target path tracked as a
  # blob/symlink, or a top-level entry name under it) is left alone rather
  # than overwritten.
  defp maybe_copy_skills(workspace, issue_context, worker_host, created?) do
    workspace_settings = Config.settings!().workspace

    case workspace_settings.skills_source do
      empty when empty in [nil, ""] ->
        :ok

      _skills_source when is_binary(worker_host) ->
        {:error, {:workspace_skills_remote_unsupported, worker_host}}

      skills_source ->
        copy_skills(workspace, issue_context, created?, skills_source, workspace_settings.skills_targets)
    end
  end

  defp copy_skills(workspace, issue_context, created?, skills_source, targets) do
    expanded_source = Path.expand(skills_source)

    if File.dir?(expanded_source) do
      copy_skill_targets(workspace, issue_context, created?, expanded_source, targets)
    else
      fail_skills_copy(
        workspace,
        issue_context,
        created?,
        {:error, {:workspace_skills_source_missing, expanded_source}}
      )
    end
  end

  # One `Git.tracked_paths/3` probe per copy operation (not per target).
  # `:not_a_git_repo` preserves the pre-repo-wins blind-copy behavior (empty
  # tracked set, exclude file skipped entirely); a probe failure aborts the
  # copy rather than risking a blind clobber over a repo git couldn't read.
  defp copy_skill_targets(workspace, issue_context, created?, expanded_source, targets) do
    case Git.tracked_paths(workspace, targets) do
      :not_a_git_repo ->
        apply_skill_targets(workspace, issue_context, created?, expanded_source, targets, [], nil)

      {:ok, %{paths: tracked_paths, exclude_file: exclude_file}} ->
        apply_skill_targets(workspace, issue_context, created?, expanded_source, targets, tracked_paths, exclude_file)

      {:error, reason} ->
        fail_skills_copy(
          workspace,
          issue_context,
          created?,
          {:error, {:workspace_skills_git_probe_failed, reason}}
        )
    end
  end

  defp apply_skill_targets(workspace, issue_context, created?, expanded_source, targets, tracked_paths, exclude_file) do
    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         ctx = %{
           canonical_workspace: canonical_workspace,
           workspace: workspace,
           expanded_source: expanded_source,
           entries: File.ls!(expanded_source)
         },
         {:ok, exclude_targets, skipped} <- reduce_skill_targets(ctx, targets, tracked_paths) do
      if exclude_file, do: ensure_skills_git_exclude(exclude_file, exclude_targets)
      log_skills_copy(issue_context, expanded_source, targets, skipped)
      :ok
    else
      {:error, reason} -> fail_skills_copy(workspace, issue_context, created?, {:error, reason})
    end
  end

  # Repo-wins, additive copy per target: a target the repo tracks as a blob
  # or symlink (e.g. a committed `.claude/skills` symlink) is skipped
  # entirely — nothing is created or written through it. Otherwise, each
  # top-level entry of `expanded_source` is copied in unless the repo
  # already tracks something at that name under `target`, in which case the
  # repo's version wins and the entry is left untouched. Accumulates the
  # exclude-worthy (normalized) targets and skip labels directly, in one pass.
  defp reduce_skill_targets(ctx, targets, tracked_paths) do
    targets
    |> Enum.reduce_while({:ok, [], []}, fn target, {:ok, exclude_targets, skipped} ->
      normalized = String.trim_trailing(target, "/")

      case copy_skill_target(ctx, target, normalized, tracked_paths) do
        {:ok, :skipped_target} ->
          {:cont, {:ok, exclude_targets, [normalized | skipped]}}

        {:ok, {:copied, skipped_entries}} ->
          {:cont, {:ok, [normalized | exclude_targets], skipped_entries ++ skipped}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, exclude_targets, skipped} -> {:ok, Enum.reverse(exclude_targets), Enum.reverse(skipped)}
      error -> error
    end
  end

  defp copy_skill_target(ctx, target, normalized, tracked_paths) do
    target_dir = Path.join(ctx.workspace, target)

    with :ok <- validate_skills_target_path(ctx.canonical_workspace, target_dir) do
      if target_tracked_as_blob?(tracked_paths, normalized) do
        {:ok, :skipped_target}
      else
        File.mkdir_p!(target_dir)
        tracked_top_level = tracked_top_level_entries(tracked_paths, normalized)

        skipped_entries =
          copy_skill_entries(ctx.entries, ctx.expanded_source, target_dir, normalized, tracked_top_level)

        {:ok, {:copied, skipped_entries}}
      end
    end
  end

  defp target_tracked_as_blob?(tracked_paths, normalized_target) do
    normalized_target in tracked_paths
  end

  defp tracked_top_level_entries(tracked_paths, normalized_target) do
    prefix = normalized_target <> "/"

    tracked_paths
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn path ->
      path |> String.replace_prefix(prefix, "") |> String.split("/", parts: 2) |> List.first()
    end)
    |> Enum.uniq()
    |> MapSet.new()
  end

  defp copy_skill_entries(entries, expanded_source, target_dir, normalized_target, tracked_top_level) do
    entries
    |> Enum.reduce([], fn name, skipped ->
      if MapSet.member?(tracked_top_level, name) do
        [Path.join(normalized_target, name) | skipped]
      else
        File.cp_r!(Path.join(expanded_source, name), Path.join(target_dir, name))
        skipped
      end
    end)
    |> Enum.reverse()
  end

  # Mirrors `validate_workspace_path/2`'s canonicalize-and-prefix-check style:
  # the schema already rejects absolute/`..`/`~` target entries, so this is
  # defense-in-depth against a symlinked workspace/target escaping the root.
  # `canonical_workspace` is resolved once per operation by the caller.
  defp validate_skills_target_path(canonical_workspace, target_dir) do
    case PathSafety.canonicalize(target_dir) do
      {:ok, canonical_target} ->
        workspace_prefix = canonical_workspace <> "/"

        if String.starts_with?(canonical_target <> "/", workspace_prefix) do
          :ok
        else
          {:error, {:workspace_skills_target_escape, canonical_target, canonical_workspace}}
        end

      {:error, reason} ->
        {:error, {:workspace_skills_target_unreadable, target_dir, reason}}
    end
  end

  defp log_skills_copy(issue_context, expanded_source, targets, skipped) do
    suffix = if skipped == [], do: "", else: " skipped=#{Enum.join(skipped, ",")}"

    Logger.info(
      "Workspace skills copied #{issue_log_context(issue_context)} skills_source=#{expanded_source} targets=#{Enum.join(targets, ",")}" <>
        suffix
    )
  end

  defp fail_skills_copy(_workspace, _issue_context, false, error), do: error

  defp fail_skills_copy(workspace, issue_context, true, {:error, reason} = error) do
    remove_created_workspace_after_failure(workspace, issue_context, nil, "skills copy", reason)
    error
  end

  # Keeps the copied skill files out of `git status`/`git add -A`/Symphony's
  # WIP-preservation commits without touching files the cloned repo tracks
  # under the same directories. Idempotent: appends each `/<target>/` line at
  # most once. `exclude_file` is the git-resolved `info/exclude` path from
  # `Git.tracked_paths/3` — correct for worktree/`--separate-git-dir` layouts
  # where `.git` is a file, unlike a hand-built `<workspace>/.git/info/exclude`.
  defp ensure_skills_git_exclude(exclude_file, targets) do
    File.mkdir_p!(Path.dirname(exclude_file))

    existing =
      case File.read(exclude_file) do
        {:ok, content} -> content
        {:error, _reason} -> ""
      end

    existing_lines = String.split(existing, "\n")

    missing_lines =
      targets
      |> Enum.map(&("/" <> &1 <> "/"))
      |> Enum.uniq()
      |> Enum.reject(&(&1 in existing_lines))

    case missing_lines do
      [] ->
        :ok

      _ ->
        separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
        File.write!(exclude_file, existing <> separator <> Enum.join(missing_lines, "\n") <> "\n")
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        # Non-login shell on purpose: the daemon is launched via `mise exec`, so its
        # inherited PATH already carries the activated toolchain (codex/uv/gh). A login
        # shell (`-lc`) sources /etc/profile, which on Debian *assigns* PATH (not
        # appends), clobbering the mise dirs and leaving the bare system default — which
        # breaks hooks that shell out to those tools (e.g. a clone whose git credential
        # helper is `gh auth git-credential`). The general rule: a login shell is only
        # safe at the bottom of a process tree; spawning one here — nested under the env
        # mise already built — is the anti-pattern. Don't reintroduce `-l`.
        System.cmd("sh", ["-c", command], cd: workspace, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
