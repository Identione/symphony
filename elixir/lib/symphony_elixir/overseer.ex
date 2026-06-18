defmodule SymphonyElixir.Overseer do
  @moduledoc """
  Layer 2 of the IDE-189 agent-run robustness defense (IDE-212): a gated,
  read-only AI overseer that semantically classifies a near-budget run and
  recommends an action. It is invoked at most a couple of times per run (never
  per turn), makes a single read-only Anthropic call, and **never** changes the
  turn budget. Every error path is fail-open: a transport/parse/timeout failure
  leaves the run untouched.

  Pure decision surface:

    * `should_run?/2` — the budget-threshold trigger plus cooldown / per-session
      cap (the Layer-1 `ProgressSignal.trigger?/2` signal arm is a planned second
      trigger; it needs an orchestrator→worker signal channel that does not exist
      yet, so only the budget-threshold arm is wired today).
    * `run/3` — assemble evidence → call the engine → parse + validate the
      structured verdict.
    * `decide_action/2` — map a verdict to a concrete action, enforcing the
      confidence floor, the `steering_message`-iff-`nudge` invariant, and the
      `allow_abort` gate.
  """

  require Logger

  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig
  alias SymphonyElixir.Overseer.{Client, PromptBuilder}

  @verdicts ~w(converging thrashing blocked)
  @actions ~w(continue nudge recommend_extend_budget escalate abort)

  @typedoc """
  Optional structured supporting findings (IDE-230) carried on a hard give-up so
  the escalation comment can present a human-triage brief.
  """
  @type findings :: %{
          summary: String.t() | nil,
          blockers: [String.t()],
          next_steps_for_human: [String.t()]
        }

  @typedoc "Parsed, validated verdict (atomized enums)."
  @type verdict :: %{
          verdict: atom(),
          confidence: float(),
          recommended_action: atom(),
          steering_message: String.t() | nil,
          rationale: String.t(),
          findings: findings() | nil
        }

  @typedoc "Trigger context supplied by the worker at a turn boundary."
  @type trigger_ctx :: %{
          turn: non_neg_integer(),
          max_turns: non_neg_integer(),
          calls: non_neg_integer(),
          last_call_turn: non_neg_integer() | nil
        }

  @typedoc "Action the worker applies after a verdict (or a downgrade thereof)."
  @type action ::
          {:continue, atom()}
          | {:nudge, String.t()}
          | {:recommend_extend_budget, String.t()}
          | {:escalate, String.t()}
          | {:abort, String.t()}

  @doc """
  The budget-threshold trigger, gated by the cooldown (`min_turns_between`) and
  the per-run cap (`max_calls_per_session`). Returns `false` when the engine is
  not the implemented `"api"` path. Enable/key gating is the caller's job
  (`Config.overseer_enabled?/0`).
  """
  @spec should_run?(trigger_ctx(), OverseerConfig.t()) :: boolean()
  def should_run?(%{turn: turn, max_turns: max, calls: calls, last_call_turn: last}, %OverseerConfig{} = config) do
    config.engine == "api" and
      budget_threshold_met?(turn, max, config.budget_threshold_k) and
      calls < config.max_calls_per_session and
      cooldown_ok?(turn, last, config.min_turns_between)
  end

  @spec budget_threshold_met?(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp budget_threshold_met?(turn, max, k), do: turn >= max - k

  @spec cooldown_ok?(non_neg_integer(), non_neg_integer() | nil, non_neg_integer()) :: boolean()
  defp cooldown_ok?(_turn, nil, _min), do: true
  defp cooldown_ok?(turn, last, min), do: turn - last >= min

  @doc """
  Assemble evidence → call the engine → parse + validate. Returns the parsed
  verdict or `{:error, reason}` (fail-open at the call site).

  `opts[:engine]` overrides the engine fun (`(messages, config -> {:ok, map} |
  {:error, term})`) for tests; it defaults to `Client.classify/2`.
  """
  @spec run(PromptBuilder.evidence(), OverseerConfig.t(), keyword()) ::
          {:ok, verdict()} | {:error, term()}
  def run(evidence, %OverseerConfig{} = config, opts \\ []) when is_map(evidence) do
    engine = Keyword.get(opts, :engine, &Client.classify/2)

    if config.engine == "api" do
      messages = PromptBuilder.build(evidence)

      with {:ok, raw} <- engine.(messages, config) do
        parse(raw)
      end
    else
      {:error, {:engine_unsupported, config.engine}}
    end
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
         {:ok, rationale} <- string(raw, "rationale") do
      {:ok,
       %{
         verdict: verdict_atom(verdict),
         confidence: confidence,
         recommended_action: action_atom(action),
         steering_message: steering,
         rationale: rationale,
         findings: findings(raw)
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

  def decide_action(%{recommended_action: :escalate, rationale: r}, _config), do: {:escalate, r}

  def decide_action(%{recommended_action: :abort, rationale: r}, %OverseerConfig{allow_abort: true}) do
    {:abort, r}
  end

  def decide_action(%{recommended_action: :abort, rationale: r}, _config), do: {:escalate, r}

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

  # `findings` is optional and best-effort: a well-formed object is normalized to
  # the atom-keyed `t:findings/0` shape; absent / null / a non-object / a
  # malformed object all collapse to `nil` rather than failing the parse (the
  # findings are advisory triage content, not a hard contract). String-typed
  # subfields survive; anything else in a subfield is dropped.
  @spec findings(map()) :: findings() | nil
  defp findings(raw) do
    case Map.get(raw, "findings") do
      obj when is_map(obj) ->
        %{
          summary: optional_string(obj, "summary"),
          blockers: string_list(obj, "blockers"),
          next_steps_for_human: string_list(obj, "next_steps_for_human")
        }

      _ ->
        nil
    end
  end

  @spec optional_string(map(), String.t()) :: String.t() | nil
  defp optional_string(obj, key) do
    case Map.get(obj, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  @spec string_list(map(), String.t()) :: [String.t()]
  defp string_list(obj, key) do
    case Map.get(obj, key) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end
end
