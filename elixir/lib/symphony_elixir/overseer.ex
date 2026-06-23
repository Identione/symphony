defmodule SymphonyElixir.Overseer do
  @moduledoc """
  Layer 2 of the IDE-189 agent-run robustness defense (IDE-212, extended by
  IDE-230): a gated AI overseer that semantically classifies an extending run and
  either **approves** continued extension or **gives up** (escalates to human
  review with findings). It makes a single read-only Anthropic call per
  consultation. Every error path is fail-open: a transport/parse/timeout failure
  yields no judgement, and the worker does not auto-extend past the base budget
  without one (see `SymphonyElixir.AgentRunner`).

  Pure decision surface:

    * `triggered?/3` — the IDE-230 trigger: the consecutive deterministic
      fail-streak reached `streak_to_llm`, or the turn is a multiple of
      `mandatory_llm_every` (a periodic semantic review).
    * `should_run?/2` — `triggered?/3` plus the cooldown / per-session cap /
      engine gates. Enable/key gating is the caller's job
      (`Config.overseer_enabled?/0`).
    * `run/3` — assemble evidence → call the engine → parse + validate the
      structured verdict.
    * `decide_action/2` — map a verdict to a concrete action, enforcing the
      confidence floor, the `steering_message`-iff-`nudge` invariant, and the
      `allow_abort` gate. Approve actions keep the run extending; `escalate` /
      `abort` carry the give-up rationale + structured findings.
  """

  require Logger

  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig
  alias SymphonyElixir.Overseer.{Client, PromptBuilder, SidecarClient}

  @engines ~w(api sidecar)

  @verdicts ~w(converging thrashing blocked)
  @actions ~w(continue nudge recommend_extend_budget escalate abort)

  @typedoc "Parsed, validated verdict (atomized enums)."
  @type verdict :: %{
          verdict: atom(),
          confidence: float(),
          recommended_action: atom(),
          steering_message: String.t() | nil,
          findings: map() | nil,
          rationale: String.t()
        }

  @typedoc "Trigger context supplied by the worker at a turn boundary (IDE-230)."
  @type trigger_ctx :: %{
          turn: non_neg_integer(),
          calls: non_neg_integer(),
          last_call_turn: non_neg_integer() | nil,
          fail_streak: non_neg_integer()
        }

  @typedoc "Action the worker applies after a verdict (or a downgrade thereof)."
  @type action ::
          {:continue, atom()}
          | {:nudge, String.t()}
          | {:recommend_extend_budget, String.t()}
          | {:escalate, String.t(), map() | nil}
          | {:abort, String.t(), map() | nil}

  @doc """
  The IDE-230 trigger predicate: `true` when the consecutive deterministic
  fail-streak has reached `streak_to_llm`, or `turn` is a multiple of
  `mandatory_llm_every` (the periodic mandatory review; `0` disables that arm).
  """
  @spec triggered?(non_neg_integer(), non_neg_integer(), OverseerConfig.t()) :: boolean()
  def triggered?(turn, fail_streak, %OverseerConfig{} = config) do
    streak_trigger?(fail_streak, config.streak_to_llm) or
      cadence_trigger?(turn, config.mandatory_llm_every)
  end

  @doc """
  `triggered?/3` gated by the engine (`"api"`), the per-run call cap
  (`max_calls_per_session`), and the cooldown (`min_turns_between`).
  """
  @spec should_run?(trigger_ctx(), OverseerConfig.t()) :: boolean()
  def should_run?(%{turn: turn, calls: calls, last_call_turn: last, fail_streak: streak}, %OverseerConfig{} = config) do
    config.engine in @engines and
      triggered?(turn, streak, config) and
      calls < config.max_calls_per_session and
      cooldown_ok?(turn, last, config.min_turns_between)
  end

  @spec streak_trigger?(non_neg_integer(), non_neg_integer()) :: boolean()
  defp streak_trigger?(streak, threshold) when is_integer(threshold) and threshold > 0,
    do: streak >= threshold

  defp streak_trigger?(_streak, _threshold), do: false

  @spec cadence_trigger?(non_neg_integer(), non_neg_integer()) :: boolean()
  defp cadence_trigger?(turn, every) when is_integer(every) and every > 0, do: rem(turn, every) == 0
  defp cadence_trigger?(_turn, _every), do: false

  @spec cooldown_ok?(non_neg_integer(), non_neg_integer() | nil, non_neg_integer()) :: boolean()
  defp cooldown_ok?(_turn, nil, _min), do: true
  defp cooldown_ok?(turn, last, min), do: turn - last >= min

  @doc """
  Assemble evidence → call the engine → parse + validate. Returns the parsed
  verdict or `{:error, reason}` (fail-open at the call site).

  The engine is selected by `config.engine`: `"api"` (direct `x-api-key` Messages
  call, `Client`) or `"sidecar"` (Claude SDK sidecar reusing subscription OAuth,
  `SidecarClient` — needs `opts[:cwd]`, the issue workspace). `opts[:engine]`
  overrides the engine fun (`(messages, config) -> {:ok, map} | {:error, term}`)
  for tests, bypassing the `config.engine` dispatch.
  """
  @spec run(PromptBuilder.evidence(), OverseerConfig.t(), keyword()) ::
          {:ok, verdict()} | {:error, term()}
  def run(evidence, %OverseerConfig{} = config, opts \\ []) when is_map(evidence) do
    case Keyword.get(opts, :engine) do
      override when is_function(override, 2) ->
        with {:ok, raw} <- override.(PromptBuilder.build(evidence), config), do: parse(raw)

      _ ->
        run_engine(evidence, config, opts)
    end
  end

  @spec run_engine(PromptBuilder.evidence(), OverseerConfig.t(), keyword()) ::
          {:ok, verdict()} | {:error, term()}
  defp run_engine(evidence, %OverseerConfig{engine: "api"} = config, _opts) do
    with {:ok, raw} <- Client.classify(PromptBuilder.build(evidence), config), do: parse(raw)
  end

  defp run_engine(evidence, %OverseerConfig{engine: "sidecar"} = config, opts) do
    messages = PromptBuilder.build(evidence, output_mode: :json)

    with {:ok, raw} <- SidecarClient.classify(messages, config, cwd: Keyword.get(opts, :cwd)) do
      parse(raw)
    end
  end

  defp run_engine(_evidence, %OverseerConfig{engine: other}, _opts) do
    {:error, {:engine_unsupported, other}}
  end

  @doc """
  Validate and atomize a raw verdict map (string keys) from the engine. Rejects
  unknown enum values, missing required fields, and the wrong steering shape.
  """
  @spec parse(map()) :: {:ok, verdict()} | {:error, term()}
  def parse(raw) when is_map(raw) do
    with {:ok, verdict} <- enum(raw, "verdict", @verdicts),
         {:ok, action} <- enum(raw, "recommended_action", @actions),
         {:ok, confidence} <- number(raw, "confidence"),
         {:ok, steering} <- steering(raw),
         {:ok, findings} <- findings(raw),
         {:ok, rationale} <- string(raw, "rationale") do
      {:ok,
       %{
         verdict: verdict_atom(verdict),
         confidence: confidence,
         recommended_action: action_atom(action),
         steering_message: steering,
         findings: findings,
         rationale: rationale
       }}
    end
  end

  def parse(_other), do: {:error, :overseer_verdict_not_a_map}

  # Explicit string→atom maps (never `String.to_atom/1` on model output). The
  # input strings are already whitelisted by `enum/3`, so these are total.
  @spec verdict_atom(String.t()) :: atom()
  defp verdict_atom("converging"), do: :converging
  defp verdict_atom("thrashing"), do: :thrashing
  defp verdict_atom("blocked"), do: :blocked

  @spec action_atom(String.t()) :: atom()
  defp action_atom("continue"), do: :continue
  defp action_atom("nudge"), do: :nudge
  defp action_atom("recommend_extend_budget"), do: :recommend_extend_budget
  defp action_atom("escalate"), do: :escalate
  defp action_atom("abort"), do: :abort

  @doc """
  Map a verdict to a concrete action. Enforces:

    * confidence below `confidence_floor` ⇒ downgrade to `{:continue, :low_confidence}`;
    * `nudge` requires a non-empty `steering_message`, else downgrade to continue;
    * `abort` is treated as `escalate` unless `allow_abort` is true.

  Approve actions (`continue` / `nudge` / `recommend_extend_budget`, and any
  confidence-floor downgrade) keep the run extending; `escalate` / `abort` carry
  the give-up `rationale` and the structured `findings` for the human hand-off.
  """
  @spec decide_action(verdict(), OverseerConfig.t()) :: action()
  def decide_action(%{confidence: confidence}, %OverseerConfig{confidence_floor: floor})
      when is_number(confidence) and confidence < floor do
    {:continue, :low_confidence}
  end

  def decide_action(%{recommended_action: :continue}, _config), do: {:continue, :ok}

  def decide_action(%{recommended_action: :nudge, steering_message: msg}, _config)
      when is_binary(msg) and msg != "" do
    {:nudge, msg}
  end

  def decide_action(%{recommended_action: :nudge}, _config), do: {:continue, :missing_steering}

  def decide_action(%{recommended_action: :recommend_extend_budget, rationale: r}, _config) do
    {:recommend_extend_budget, r}
  end

  def decide_action(%{recommended_action: :escalate, rationale: r, findings: f}, _config),
    do: {:escalate, r, f}

  def decide_action(%{recommended_action: :abort, rationale: r, findings: f}, %OverseerConfig{allow_abort: true}) do
    {:abort, r, f}
  end

  def decide_action(%{recommended_action: :abort, rationale: r, findings: f}, _config),
    do: {:escalate, r, f}

  # ── parse helpers ───────────────────────────────────────────────────────────

  @spec enum(map(), String.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  defp enum(raw, key, allowed) do
    case Map.get(raw, key) do
      value when is_binary(value) ->
        if value in allowed, do: {:ok, value}, else: {:error, {:overseer_bad_enum, key, value}}

      _ ->
        {:error, {:overseer_missing_field, key}}
    end
  end

  @spec number(map(), String.t()) :: {:ok, float()} | {:error, term()}
  defp number(raw, key) do
    case Map.get(raw, key) do
      value when is_number(value) -> {:ok, value / 1}
      _ -> {:error, {:overseer_missing_field, key}}
    end
  end

  @spec string(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp string(raw, key) do
    case Map.get(raw, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:overseer_missing_field, key}}
    end
  end

  # steering_message is the one nullable field: a string or JSON null (absent).
  @spec steering(map()) :: {:ok, String.t() | nil} | {:error, term()}
  defp steering(raw) do
    case Map.get(raw, "steering_message", :__absent__) do
      :__absent__ -> {:error, {:overseer_missing_field, "steering_message"}}
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:overseer_bad_field, "steering_message"}}
    end
  end

  # findings (IDE-230) is an optional structured object: a map (background
  # evidence on give-up) or JSON null / absent (approve path). A non-map,
  # non-null value is rejected.
  @spec findings(map()) :: {:ok, map() | nil} | {:error, term()}
  defp findings(raw) do
    case Map.get(raw, "findings", :__absent__) do
      :__absent__ -> {:ok, nil}
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:overseer_bad_field, "findings"}}
    end
  end
end
