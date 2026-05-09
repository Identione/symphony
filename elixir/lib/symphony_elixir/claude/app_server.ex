defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Claude Agent SDK adapter (SPEC.md §10.8).

  Implements the `SymphonyElixir.Agent.Adapter` behaviour by spawning a
  long-lived sidecar subprocess (`agent.claude.command`, default
  `uv run --project priv/claude_agent python -m symphony_claude_agent`) and
  exchanging line-delimited JSON envelopes over stdio per `Wire`.
  """

  @behaviour SymphonyElixir.Agent.Adapter

  require Logger
  alias SymphonyElixir.{Claude.Wire, Codex.DynamicTool, Config, Linear.Issue, PathSafety}

  @port_line_bytes 1_048_576
  @default_read_timeout_ms 30_000

  @type session :: %{
          port: port(),
          workspace: Path.t(),
          session_id: String.t() | nil,
          claude_app_server_pid: String.t() | nil,
          read_timeout_ms: pos_integer(),
          buffer: binary()
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &resolve_config/0)
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- check_local_only(worker_host),
         {:ok, expanded_workspace} <- canonical_workspace(workspace),
         {:ok, port} <- open_port(expanded_workspace, config),
         :ok <- write_init(port, expanded_workspace, config),
         {:ok, leftover} <-
           await_ready(port, "", config_read_timeout(config)) do
      {:ok,
       %{
         port: port,
         workspace: expanded_workspace,
         # The Claude SDK only delivers `system_init` (carrying the
         # session_id) once the first turn starts and `client.receive_response`
         # yields its first message. We therefore start with `session_id: nil`
         # and capture it lazily inside `do_collect`/`handle_envelope`.
         session_id: nil,
         claude_app_server_pid: port_os_pid(port),
         read_timeout_ms: config_read_timeout(config),
         buffer: leftover
       }}
    else
      {:error, reason} ->
        # Best-effort cleanup if the port was opened.
        case Process.get(:claude_temp_port) do
          port when is_port(port) ->
            Process.delete(:claude_temp_port)
            close_port(port)

          _ ->
            :ok
        end

        # No issue context here — start_session is called before the
        # AgentRunner has bound a turn to an issue. Mirrors the spirit of
        # Codex's "Codex session failed for ..." but at the sidecar
        # bring-up boundary.
        Logger.error("Claude session failed (startup): #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, 3_600_000)

    tool_executor =
      Keyword.get(opts, :tool_executor, fn name, input ->
        DynamicTool.execute(name, input)
      end)

    permission_handler =
      Keyword.get(opts, :permission_handler, fn _request ->
        # Default policy: deny. Symphony's `dontAsk` posture means tools that
        # were not pre-approved must not be invoked, so denying any
        # permission_request that does manage to reach Symphony is the safe
        # default. Operators that need a different policy supply their own.
        %{decision: "deny", reason: "Symphony permission_handler not configured"}
      end)

    issue_log = issue_context(issue)

    turn_payload =
      %{type: "turn", prompt: prompt}
      |> maybe_put_session_id(session.session_id)

    with {:ok, line} <- Wire.encode(turn_payload),
         :ok <- port_command(session.port, line) do
      Logger.info("Claude session started for #{issue_log}#{session_log_suffix(session.session_id)}")

      session
      |> collect_until_terminal(on_message, turn_timeout_ms, issue_log, tool_executor, permission_handler)
      |> log_run_turn_outcome(issue_log)
    else
      {:error, reason} ->
        Logger.error("Claude session failed for #{issue_log}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp log_run_turn_outcome({:ok, %{session_id: sid}} = result, issue_log) do
    Logger.info("Claude session completed for #{issue_log}#{session_log_suffix(sid)}")
    result
  end

  defp log_run_turn_outcome({:error, reason} = result, issue_log) do
    Logger.warning("Claude session ended with error for #{issue_log}: #{inspect(reason)}")
    result
  end

  defp session_log_suffix(sid) when is_binary(sid), do: " session_id=#{sid}"
  defp session_log_suffix(_), do: ""

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    case Wire.encode(%{type: "shutdown"}) do
      {:ok, line} -> port_command(port, line)
      _ -> :ok
    end

    close_port(port)
  end

  def stop_session(_), do: :ok

  # --- internals ---

  # The Claude sidecar command is an absolute path on the orchestrator host,
  # so a remote worker_host would mismatch workspace paths. Reject until
  # remote support lands. Config.validate! refuses claude+ssh_hosts at boot,
  # so this is a defense-in-depth check.
  defp check_local_only(nil), do: :ok

  defp check_local_only(worker_host) when is_binary(worker_host) do
    {:error, {:claude_remote_worker_unsupported, worker_host}}
  end

  defp resolve_config do
    settings = Config.settings!()
    claude = settings.agent.claude

    %{
      command: claude.command,
      model: claude.model,
      permission_mode: claude.permission_mode,
      allowed_tools: claude.allowed_tools,
      disallowed_tools: claude.disallowed_tools,
      system_prompt_preset: claude.system_prompt_preset,
      setting_sources: claude.setting_sources,
      max_turns: claude.max_turns,
      max_budget_usd: claude.max_budget_usd,
      extra_env: claude.extra_env,
      config_dir: claude.config_dir,
      read_timeout_ms: claude.read_timeout_ms,
      verbose: claude.verbose
    }
  end

  defp canonical_workspace(workspace) when is_binary(workspace) do
    expanded = Path.expand(workspace)

    case PathSafety.canonicalize(expanded) do
      {:ok, path} -> {:ok, path}
      _ -> {:ok, expanded}
    end
  end

  defp open_port(workspace, %{command: command} = config) when is_binary(command) and command != "" do
    env_charlists =
      config
      |> sidecar_env_overrides()
      |> Enum.map(fn {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))} end)

    port_opts = [
      :binary,
      :exit_status,
      :hide,
      :use_stdio,
      {:line, @port_line_bytes},
      {:cd, workspace},
      {:args, ["-lc", command]},
      {:env, env_charlists}
    ]

    try do
      port = Port.open({:spawn_executable, System.find_executable("bash")}, port_opts)
      Process.put(:claude_temp_port, port)
      {:ok, port}
    rescue
      e -> {:error, {:claude_sidecar_not_found, Exception.message(e)}}
    end
  end

  defp open_port(_workspace, _config), do: {:error, {:claude_sidecar_not_found, :missing_command}}

  # The sidecar Port spawns with `cd: workspace` (the per-issue workspace), so
  # any relative path in `agent.claude.command` resolves *there*, not in the
  # repo. Inject SYMPHONY_CLAUDE_PRIV_DIR pointing at this app's
  # `priv/claude_agent` so commands like `uv run --project
  # $SYMPHONY_CLAUDE_PRIV_DIR …` find the sidecar regardless of workspace.
  #
  # When `agent.claude.config_dir` is set, also force CLAUDE_CONFIG_DIR in the
  # sidecar env so the SDK's underlying `claude` CLI scopes its OAuth lookup
  # to that subscription's credentials directory. `extra_env` still wins if it
  # explicitly sets either variable.
  defp sidecar_env_overrides(config) do
    extra_env = Map.get(config, :extra_env, %{}) || %{}

    base =
      extra_env
      |> stringify_env_keys()
      |> Map.put_new("SYMPHONY_CLAUDE_PRIV_DIR", claude_priv_dir())

    case Map.get(config, :config_dir) do
      dir when is_binary(dir) and dir != "" ->
        Map.put_new(base, "CLAUDE_CONFIG_DIR", Path.expand(dir))

      _ ->
        base
    end
  end

  # Resolves to the `priv/claude_agent` directory for the running app. Under
  # `mix run`, `:code.priv_dir/1` returns `_build/<env>/lib/symphony_elixir/priv`
  # and the joined path is a real directory. Under the escript launcher, the
  # call returns a non-error charlist pointing *inside* the zip archive
  # (e.g. `bin/symphony/symphony_elixir/priv`) — the path string is well-formed
  # but does not exist on disk, so we must `File.dir?/1`-validate it and fall
  # back to a cwd-anchored path. The launcher always starts from `elixir/`,
  # where `priv/claude_agent` lives in the source tree.
  defp claude_priv_dir do
    fallback = Path.expand("priv/claude_agent")

    case :code.priv_dir(:symphony_elixir) do
      priv_dir when is_list(priv_dir) ->
        candidate = Path.join(to_string(priv_dir), "claude_agent")
        if File.dir?(candidate), do: candidate, else: fallback

      _ ->
        fallback
    end
  end

  defp stringify_env_keys(env) when is_map(env) do
    Enum.into(env, %{}, fn {k, v} -> {to_string(k), v} end)
  end

  defp write_init(port, workspace, config) do
    payload =
      %{
        type: "init",
        cwd: workspace,
        model: Map.get(config, :model),
        permission_mode: Map.get(config, :permission_mode),
        allowed_tools: Map.get(config, :allowed_tools, []),
        disallowed_tools: Map.get(config, :disallowed_tools, []),
        system_prompt_preset: Map.get(config, :system_prompt_preset, "claude_code"),
        setting_sources: Map.get(config, :setting_sources, []),
        max_turns: Map.get(config, :max_turns),
        max_budget_usd: Map.get(config, :max_budget_usd),
        verbose: Map.get(config, :verbose, false),
        # Push the canonical Codex `linear_graphql` schema (and any future
        # client-side tools) into the sidecar so it can register MCP tools
        # without maintaining its own copy of the JSON Schema. See SPEC §10.4.
        tool_specs: DynamicTool.tool_specs()
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Wire.encode(payload) do
      {:ok, line} -> port_command(port, line)
      {:error, reason} -> {:error, {:claude_sdk_error, reason}}
    end
  end

  defp config_read_timeout(config) do
    case Map.get(config, :read_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_read_timeout_ms
    end
  end

  # Wait for the sidecar's `ready` envelope (sent right after the SDK client's
  # `__aenter__` completes). `system_init` is *not* required here because the
  # Claude Agent SDK only emits it once the first turn's `receive_response`
  # yields its initial `SystemMessage(subtype="init")`; we capture it lazily
  # inside `do_collect`. Returns `{:ok, leftover_buffer}` or `{:error, reason}`.
  defp await_ready(port, buffer, timeout_ms) do
    case receive_one_envelope(port, buffer, timeout_ms) do
      {:ok, %{type: :ready}, leftover} ->
        Process.delete(:claude_temp_port)
        {:ok, leftover}

      {:ok, %{type: :error, error: msg}, _leftover} ->
        {:error, {:claude_sdk_error, msg}}

      {:ok, %{type: :log}, leftover} ->
        await_ready(port, leftover, timeout_ms)

      {:ok, _other, leftover} ->
        await_ready(port, leftover, timeout_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Single-envelope receive with read timeout. `buffer` carries leftover bytes
  # from a previous read.
  defp receive_one_envelope(port, buffer, timeout_ms) do
    case extract_one_line(buffer) do
      {:line, line, leftover} ->
        case Wire.decode(line) do
          {:ok, decoded} -> {:ok, decoded, leftover}
          {:error, reason} -> {:error, {:malformed_envelope, reason}}
        end

      :need_more ->
        receive do
          {^port, {:data, {:eol, chunk}}} ->
            line = buffer <> chunk

            case Wire.decode(line) do
              {:ok, decoded} -> {:ok, decoded, ""}
              {:error, reason} -> {:error, {:malformed_envelope, reason}}
            end

          {^port, {:data, {:noeol, chunk}}} ->
            receive_one_envelope(port, buffer <> chunk, timeout_ms)

          {^port, {:exit_status, status}} ->
            {:error, {:claude_sidecar_exit, status}}
        after
          timeout_ms -> {:error, :response_timeout}
        end
    end
  end

  defp extract_one_line(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [_only] -> :need_more
      [line, rest] -> {:line, line, rest}
    end
  end

  defp collect_until_terminal(session, on_message, turn_timeout_ms, issue_log, tool_executor, permission_handler) do
    deadline = monotonic_ms() + turn_timeout_ms

    context = %{
      on_message: on_message,
      deadline: deadline,
      issue_log: issue_log,
      tool_executor: tool_executor,
      permission_handler: permission_handler
    }

    do_collect(session, context, session.buffer)
  end

  defp do_collect(session, context, buffer) do
    remaining = max(context.deadline - monotonic_ms(), 0)
    read_timeout_ms = min(session.read_timeout_ms, remaining)

    if remaining == 0 do
      {:error, :turn_timeout}
    else
      session.port
      |> receive_one_envelope(buffer, read_timeout_ms)
      |> handle_envelope(session, context, buffer)
    end
  end

  defp handle_envelope({:ok, %{type: :turn_end} = env, _leftover}, session, context, _buffer) do
    emit_event(context.on_message, :turn_completed, env, session)
    {:ok, build_turn_result(session, env)}
  end

  defp handle_envelope({:ok, %{type: :error, error: msg}, _leftover}, _session, _context, _buffer) do
    {:error, {:claude_sdk_error, msg}}
  end

  defp handle_envelope({:ok, %{type: :tool_call} = env, leftover}, session, context, _buffer) do
    case dispatch_tool_call(session, env, context.tool_executor) do
      :ok ->
        emit_event(context.on_message, :tool_call, env, session)
        do_collect(session, context, leftover)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_envelope({:ok, %{type: :permission_request} = env, leftover}, session, context, _buffer) do
    case dispatch_permission_request(session, env, context.permission_handler) do
      :ok ->
        emit_event(context.on_message, :permission_request, env, session)
        do_collect(session, context, leftover)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `system_init` carries the SDK's session_id; capture it on the session so
  # subsequent envelopes (and turn_end) carry the right session_id.
  defp handle_envelope(
         {:ok, %{type: :system_init, session_id: session_id} = env, leftover},
         session,
         context,
         _buffer
       )
       when is_binary(session_id) do
    updated = %{session | session_id: session_id}
    emit_event(context.on_message, :system_init, env, updated)
    do_collect(updated, context, leftover)
  end

  defp handle_envelope({:ok, %{type: type} = env, leftover}, session, context, _buffer) do
    emit_event(context.on_message, type, env, session)
    do_collect(session, context, leftover)
  end

  defp handle_envelope({:error, :response_timeout}, session, context, buffer) do
    do_collect(session, context, buffer)
  end

  defp handle_envelope({:error, reason}, _session, _context, _buffer) do
    {:error, reason}
  end

  defp dispatch_tool_call(session, env, tool_executor) do
    name = Map.get(env, :name)
    tool_use_id = Map.get(env, :tool_use_id)
    input = Map.get(env, :input, %{})

    result = tool_executor.(name, input)

    payload = %{
      type: "tool_result",
      tool_use_id: tool_use_id,
      result: result
    }

    case Wire.encode(payload) do
      {:ok, line} -> port_command(session.port, line)
      {:error, reason} -> {:error, {:claude_sdk_error, reason}}
    end
  end

  defp dispatch_permission_request(session, env, permission_handler) do
    request_id = Map.get(env, :permission_request_id)
    response = permission_handler.(env)

    payload = %{
      type: "permission_response",
      permission_request_id: request_id,
      response: response
    }

    case Wire.encode(payload) do
      {:ok, line} -> port_command(session.port, line)
      {:error, reason} -> {:error, {:claude_sdk_error, reason}}
    end
  end

  defp emit_event(on_message, type, payload, session) when is_function(on_message, 1) do
    on_message.(%{
      event: type,
      session_id: session.session_id,
      agent_kind: :claude,
      claude_app_server_pid: Map.get(session, :claude_app_server_pid),
      payload: payload,
      timestamp: DateTime.utc_now()
    })

    :ok
  end

  # Mirrors Codex.AppServer.port_metadata/2's pid extraction. The pid is the
  # `bash -lc` wrapper's pid, not the python sidecar's — same caveat as the
  # codex case, where it's the spawned shell's pid rather than the codex CLI's.
  defp port_os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> to_string(os_pid)
      _ -> nil
    end
  end

  defp build_turn_result(session, env) do
    %{
      session_id: session.session_id,
      stop_reason: Map.get(env, :stop_reason),
      num_turns: Map.get(env, :num_turns, 1),
      usage: Map.get(env, :usage, %{}),
      result: env
    }
  end

  defp port_command(port, iodata) when is_port(port) do
    Port.command(port, iodata)
    :ok
  rescue
    ArgumentError -> {:error, :port_closed}
  catch
    :error, :badarg -> {:error, :port_closed}
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp maybe_put_session_id(map, nil), do: map
  defp maybe_put_session_id(map, session_id), do: Map.put(map, :session_id, session_id)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_), do: "issue_id=unknown"
end
