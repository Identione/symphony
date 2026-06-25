defmodule SymphonyElixir.Overseer.SidecarClient do
  @moduledoc """
  Engine (b) for the Layer 2 overseer (IDE-230 Path B): a single read-only
  classification run through the Claude Agent SDK sidecar
  (`SymphonyElixir.Claude.AppServer`).

  The whole point of this engine is **credential reuse** — the sidecar
  authenticates with the same Claude *subscription OAuth* the `claude` coding
  adapter uses (via the `claude` CLI credentials / `CLAUDE_CONFIG_DIR`), so an
  operator who already runs the Claude adapter needs no separate
  `ANTHROPIC_API_KEY` for the overseer. Contrast `Overseer.Client`, which makes a
  direct `x-api-key` Messages call.

  Read-only by construction: the session is launched isolated
  (`setting_sources: []`, `allowed_tools: []`) with a single turn, so the model
  cannot read files, run commands, or touch the workspace — it only emits the
  verdict. Unlike the `api` engine there is no forced `tool_choice`, so we ask
  for a bare JSON object (`PromptBuilder` `:json` mode) and parse it back into the
  same string-keyed map `Overseer.parse/1` validates.

  Every failure path returns `{:error, reason}` — the caller (`Overseer.run/3`)
  is fail-open, so a startup/turn/parse error yields no judgement instead of
  raising into the turn loop.
  """

  require Logger

  alias SymphonyElixir.Claude.AppServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig

  # The sidecar session's within-session turn cap. One model response is a single
  # turn; we allow a small margin so a stray (denied) tool attempt under the
  # claude_code preset can still recover into a final answer rather than tripping
  # `error_max_turns`. Tools are disallowed, so the model has nothing to call.
  @sidecar_max_turns 2

  @doc """
  Classify a near-budget run through the Claude sidecar. `messages` is the
  `%{system, user}` bundle from `PromptBuilder.build(evidence, output_mode:
  :json)`. `opts[:cwd]` is the issue workspace the sidecar runs in (required; the
  SDK needs a real directory even though the session is tool-less).

  Returns the raw verdict map (string keys) on success, or `{:error, reason}` on
  any startup / turn / parse failure.
  """
  @spec classify(%{system: String.t(), user: String.t()}, OverseerConfig.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def classify(%{system: system, user: user}, %OverseerConfig{} = config, opts \\ [])
      when is_binary(system) and is_binary(user) do
    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) and cwd != "" ->
        do_classify(system <> "\n\n" <> user, config, cwd)

      _ ->
        {:error, :overseer_sidecar_no_cwd}
    end
  end

  @spec do_classify(String.t(), OverseerConfig.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  defp do_classify(prompt, config, cwd) do
    adapter = adapter()

    case adapter.start_session(cwd, config: sidecar_config(config), worker_host: nil) do
      {:ok, session} ->
        result = run_turn_collect(adapter, session, prompt, config)
        adapter.stop_session(session)

        with {:ok, text} <- result, do: extract_json(text)

      {:error, reason} ->
        {:error, {:overseer_sidecar_start_failed, reason}}
    end
  end

  # Run the single classification turn, accumulating assistant text. Tools are
  # disallowed at the SDK level; the deny executor is defense-in-depth so an
  # unexpected tool round-trip can never reach Linear from the overseer turn.
  @spec run_turn_collect(module(), term(), String.t(), OverseerConfig.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp run_turn_collect(adapter, session, prompt, config) do
    {:ok, acc} = Agent.start_link(fn -> [] end)

    on_message = fn envelope ->
      collect_text(acc, envelope)
      :ok
    end

    result =
      adapter.run_turn(session, prompt, nil,
        on_message: on_message,
        turn_timeout_ms: config.timeout_ms,
        tool_executor: &deny_tool/2
      )

    texts = Agent.get(acc, &Enum.reverse/1)
    Agent.stop(acc)

    case result do
      {:ok, _turn_result} -> {:ok, Enum.join(texts, "\n")}
      {:error, reason} -> {:error, {:overseer_sidecar_turn_failed, reason}}
    end
  end

  @spec collect_text(pid(), map()) :: :ok
  defp collect_text(acc, %{event: :assistant_message, payload: payload}) do
    case payload_text(payload) do
      text when is_binary(text) and text != "" -> Agent.update(acc, &[text | &1])
      _ -> :ok
    end
  end

  defp collect_text(_acc, _envelope), do: :ok

  @spec payload_text(term()) :: String.t() | nil
  defp payload_text(payload) when is_map(payload), do: payload[:text] || payload["text"]
  defp payload_text(_payload), do: nil

  @spec deny_tool(String.t(), map()) :: map()
  defp deny_tool(_name, _input) do
    %{
      "success" => false,
      "output" => "tools are disabled for the overseer classification turn"
    }
  end

  # Build the locked-down AppServer config: reuse the Claude adapter's launch
  # surface (command, config_dir → CLAUDE_CONFIG_DIR/OAuth, extra_env,
  # permission_mode, system_prompt_preset) but force isolation and a single
  # tool-less turn with the overseer's own model/effort/timeout.
  @spec sidecar_config(OverseerConfig.t()) :: map()
  defp sidecar_config(%OverseerConfig{} = ov) do
    claude = Config.settings!().agent.claude

    %{
      AppServer.resolve_config(claude, nil)
      | model: ov.model,
        effort: ov.effort,
        allowed_tools: [],
        setting_sources: [],
        max_turns: @sidecar_max_turns,
        max_budget_usd: nil,
        read_timeout_ms: ov.timeout_ms,
        verbose_logging: false
    }
  end

  # Test seam: swap the sidecar adapter for a stub without spawning the Python
  # sidecar (mirrors `Overseer.Client`'s `:overseer_api_base_url`).
  @spec adapter() :: module()
  defp adapter do
    Application.get_env(:symphony_elixir, :overseer_sidecar_adapter, AppServer)
  end

  # Extract the verdict object from the model's text. Tolerant of stray prose or
  # markdown fences despite the "JSON only" instruction: try a whole-string
  # decode first, then fall back to the first balanced `{...}` object.
  @spec extract_json(String.t()) :: {:ok, map()} | {:error, term()}
  defp extract_json(text) when is_binary(text) do
    stripped = text |> strip_code_fences() |> String.trim()

    case Jason.decode(stripped) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> extract_first_object(stripped)
    end
  end

  @spec strip_code_fences(String.t()) :: String.t()
  defp strip_code_fences(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
  end

  @spec extract_first_object(String.t()) :: {:ok, map()} | {:error, term()}
  defp extract_first_object(text) do
    case scan_object(text) do
      {:ok, candidate} ->
        case Jason.decode(candidate) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, :overseer_sidecar_unparseable_verdict}
        end

      :error ->
        {:error, :overseer_sidecar_unparseable_verdict}
    end
  end

  # Return the substring of the first balanced top-level `{...}` object, honoring
  # double-quoted strings and escapes so a brace inside a string value does not
  # close the object early.
  @spec scan_object(String.t()) :: {:ok, String.t()} | :error
  defp scan_object(text) do
    case :binary.match(text, "{") do
      {start, _} ->
        rest = binary_part(text, start, byte_size(text) - start)
        scan_object(rest, 0, 0, false, false)

      :nomatch ->
        :error
    end
  end

  @spec scan_object(binary(), non_neg_integer(), non_neg_integer(), boolean(), boolean()) ::
          {:ok, String.t()} | :error
  defp scan_object(bin, idx, _depth, _in_string?, _escaped?) when idx >= byte_size(bin), do: :error

  defp scan_object(bin, idx, depth, in_string?, escaped?) do
    case advance(:binary.at(bin, idx), depth, in_string?, escaped?) do
      :close -> {:ok, binary_part(bin, 0, idx + 1)}
      {depth, in_string?, escaped?} -> scan_object(bin, idx + 1, depth, in_string?, escaped?)
    end
  end

  # One step of the brace scanner, expressed as pattern-matched heads on
  # `(char, depth, in_string?, escaped?)`. Returns the next `{depth, in_string?,
  # escaped?}` state, or `:close` when the top-level object's closing brace is
  # reached. Order matters: the escaped-char head must precede the others.
  @spec advance(byte(), non_neg_integer(), boolean(), boolean()) ::
          {non_neg_integer(), boolean(), boolean()} | :close
  defp advance(_char, depth, in_string?, true), do: {depth, in_string?, false}
  defp advance(?\\, depth, true, false), do: {depth, true, true}
  defp advance(?", depth, in_string?, false), do: {depth, not in_string?, false}
  defp advance(_char, depth, true, false), do: {depth, true, false}
  defp advance(?{, depth, false, false), do: {depth + 1, false, false}
  defp advance(?}, 1, false, false), do: :close
  defp advance(?}, depth, false, false), do: {depth - 1, false, false}
  defp advance(_char, depth, false, false), do: {depth, false, false}
end
