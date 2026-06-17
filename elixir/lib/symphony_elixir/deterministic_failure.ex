defmodule SymphonyElixir.DeterministicFailure do
  @moduledoc """
  Tracks consecutive same-code adapter failures and escalates the issue to
  Linear once configured thresholds are crossed (IDE-73).

  The orchestrator owns the per-issue counter; this module supplies the pure
  decision logic and the side-effecting helpers that post the workpad/blocker
  comment and move the issue state.

  ## Failure taxonomy

  IDE-71 maps every adapter failure to a structured `error_code`. Only the
  *deterministic* subset feeds the counter — codes whose recurrence implies a
  human (or external system) needs to intervene before another retry makes
  sense:

      :quota_exceeded            — billing / credit balance exhausted
      :context_window_exhausted  — prompt won't fit the model
      :invalid_request           — request shape is permanently rejected
      :claude_sidecar_exit       — sidecar binary exited non-cleanly
      :port_exit                 — codex app-server port died
      :max_turns_reached         — IDE-74: agent.max_turns budget exhausted
                                   while the issue was still active (the
                                   model is looping unproductively)

  Transient codes (`:rate_limited`, `:overloaded`, `:turn_timeout`,
  `:response_timeout`, `:unknown`) intentionally reset the counter so a brief
  upstream blip never trips the escalation. `:unknown` is reset rather than
  counted because the agent_runner falls back to it on shapes we couldn't
  classify — counting it would surface noise more often than stuck issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Issue

  @typedoc "Threshold severity emitted to Linear."
  @type severity :: :alert | :escalate

  @workpad_marker "## Symphony Workpad"
  @escalation_section_marker "<!-- symphony:deterministic-failure -->"

  @typedoc """
  Per-issue counter snapshot stored in the orchestrator state.
  """
  @type entry :: %{
          required(:code) => atom(),
          required(:count) => pos_integer(),
          required(:notified_alert?) => boolean(),
          required(:notified_escalation?) => boolean()
        }

  @typedoc """
  Decision returned by `decide/3` for a single failure event.
  """
  @type action ::
          :no_action
          | {:alert, code :: atom(), count :: pos_integer()}
          | {:escalate, code :: atom(), count :: pos_integer()}

  @deterministic_codes ~w(quota_exceeded context_window_exhausted invalid_request claude_sidecar_exit port_exit max_turns_reached budget_exhausted)a

  # Codes that escalate on the *first* occurrence rather than after the
  # configured consecutive-failure threshold. A `max_budget_usd` breach is a
  # hard, operator-visible stop — there is no value in burning N more sessions
  # to "confirm" it, and `:budget_exhausted` is `:no_retry` so it would never
  # accumulate a streak anyway.
  @immediate_escalation_codes ~w(budget_exhausted)a

  @doc """
  Returns the deterministic code set as a list. Exposed for tests/docs.
  """
  @spec deterministic_codes() :: [atom()]
  def deterministic_codes, do: @deterministic_codes

  @doc """
  Decide the next counter state and what (if anything) the orchestrator should
  do given a fresh failure event. Pure.

  Returns `{:drop, :no_action}` when the counter resets (transient or unknown
  code), otherwise `{updated_entry, action}` where `action` reports whether
  the orchestrator should send an alert, escalate the issue, or do nothing.

  The returned entry only carries the incremented count; the
  `:notified_alert?` / `:notified_escalation?` flags are *not* mutated here.
  The orchestrator persists those flags itself, and only after `handle/3`
  reports the corresponding side effect succeeded — that way a failed
  comment-post or state-move stays retryable on the next failure with the
  same code.
  """
  @spec decide(entry() | nil, atom(), Config.Schema.t()) ::
          {:drop, :no_action} | {entry(), action()}
  def decide(prev_entry, code, settings) when is_atom(code) do
    if deterministic?(code) do
      incremented = increment(prev_entry, code)
      classify(incremented, settings)
    else
      {:drop, :no_action}
    end
  end

  @doc """
  Returns `true` if the given code should advance the counter.
  """
  @spec deterministic?(atom()) :: boolean()
  def deterministic?(code), do: code in @deterministic_codes

  @doc """
  Drop the counter entry for an issue. Called when the issue completes
  successfully, moves to a terminal/non-active state, or is otherwise no
  longer being retried.
  """
  @spec reset(map(), String.t()) :: map()
  def reset(deterministic_failures, issue_id) when is_map(deterministic_failures) do
    Map.delete(deterministic_failures, issue_id)
  end

  @doc """
  Side-effecting handler invoked by the orchestrator when `decide/3` returned
  a non-`:no_action` decision.

  * On `:alert` — append the failure summary to the existing `## Symphony
    Workpad` comment if one is present; otherwise create a standalone blocker
    comment.
  * On `:escalate` — emit the same comment (idempotent if the alert path
    already posted it) and then move the issue to the configured escalation
    state via `Tracker.update_issue_state/2`.

  Returns one of:

      :ok                — alert posted, no state move expected
      {:ok, :escalated}  — comment posted AND state move succeeded
      {:error, reason}   — best-effort failure (the orchestrator already
                           updated the counter; the next failure with the
                           same code will retry the comment/move)
  """
  @spec handle(action(), Issue.t() | map(), Config.Schema.t()) ::
          :ok | {:ok, :escalated} | {:error, term()}
  def handle({:alert, code, count}, issue, settings) do
    post_failure_comment(issue, code, count, :alert, settings)
  end

  def handle({:escalate, code, count}, issue, settings) do
    state_name = settings.agent.deterministic_failure_escalation_state

    with :ok <- post_failure_comment(issue, code, count, :escalate, settings),
         :ok <- move_issue(issue, state_name) do
      {:ok, :escalated}
    end
  end

  def handle(:no_action, _issue, _settings), do: :ok

  @doc false
  @spec compose_message(atom(), pos_integer(), severity(), String.t()) :: String.t()
  def compose_message(code, count, severity, escalation_state) do
    header =
      case severity do
        :alert -> "Deterministic-failure alert"
        :escalate -> "Deterministic-failure escalation"
      end

    move_line =
      if severity == :escalate do
        "\n- Action: moving the issue to **#{escalation_state}** so the polling loop stops re-dispatching.\n"
      else
        ""
      end

    """
    #{@escalation_section_marker}

    ### #{header}

    #{summary_line(code, count)}
    #{move_line}
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # The cumulative session cap (P1) is not a "same-code failure" streak — it's a
  # ceiling on total sessions run for one issue — so it gets its own sentence.
  defp summary_line(:max_sessions_per_issue, count) do
    "Symphony ran **#{count}** agent sessions for this issue without it leaving the active set " <>
      "(the `agent.max_sessions_per_issue` cap). See `elixir/docs/token_exhaustion.md`."
  end

  defp summary_line(code, count) do
    "Symphony has seen **#{count}** consecutive failures with the same structured error code (`#{code}`) for this issue. " <>
      "See `elixir/docs/token_exhaustion.md` for the deterministic-failure taxonomy."
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp increment(nil, code), do: fresh_entry(code)
  defp increment(%{code: prev_code}, code) when prev_code != code, do: fresh_entry(code)
  defp increment(%{code: code, count: count} = prev, code), do: %{prev | count: count + 1}

  defp fresh_entry(code) do
    %{code: code, count: 1, notified_alert?: false, notified_escalation?: false}
  end

  defp classify(entry, settings) do
    escalate = settings.agent.deterministic_failure_escalation_threshold
    alert = settings.agent.deterministic_failure_alert_threshold
    count = entry.count

    cond do
      not entry.notified_escalation? and escalate_now?(entry, escalate, count) ->
        {entry, {:escalate, entry.code, count}}

      is_integer(alert) and count >= alert and not entry.notified_alert? ->
        {entry, {:alert, entry.code, count}}

      true ->
        {entry, :no_action}
    end
  end

  # Escalate either when the code is in the immediate-escalation set (first
  # occurrence) or when the consecutive-failure count reaches the configured
  # threshold.
  defp escalate_now?(entry, escalate, count) do
    entry.code in @immediate_escalation_codes or (is_integer(escalate) and count >= escalate)
  end

  defp post_failure_comment(issue, code, count, severity, settings) do
    issue_id = issue_id(issue)
    escalation_state = settings.agent.deterministic_failure_escalation_state
    section = compose_message(code, count, severity, escalation_state)

    case find_workpad_comment(issue_id) do
      {:ok, %{id: comment_id, body: body}} ->
        new_body = append_failure_section(body, section)
        log_comment_intent(issue, code, count, severity, :update)

        case Tracker.update_comment(comment_id, new_body) do
          :ok ->
            :ok

          {:error, reason} = err ->
            Logger.warning("Deterministic-failure workpad update failed for #{issue_context(issue)} code=#{code}: #{inspect(reason)}")

            err
        end

      :not_found ->
        body = blocker_body(code, count, severity, escalation_state, section)
        log_comment_intent(issue, code, count, severity, :create)

        case Tracker.create_comment(issue_id, body) do
          :ok ->
            :ok

          {:error, reason} = err ->
            Logger.warning("Deterministic-failure blocker comment create failed for #{issue_context(issue)} code=#{code}: #{inspect(reason)}")

            err
        end

      {:error, reason} = err ->
        Logger.warning("Deterministic-failure workpad lookup failed for #{issue_context(issue)} code=#{code}: #{inspect(reason)}")

        err
    end
  end

  defp move_issue(issue, state_name) do
    issue_id = issue_id(issue)

    case Tracker.update_issue_state(issue_id, state_name) do
      :ok ->
        Logger.warning("Deterministic-failure escalation moved #{issue_context(issue)} to state=#{state_name}")

        :ok

      {:error, reason} = err ->
        Logger.warning("Deterministic-failure escalation state move failed for #{issue_context(issue)} target=#{state_name}: #{inspect(reason)}")

        err
    end
  end

  defp find_workpad_comment(issue_id) do
    case Tracker.fetch_comments(issue_id) do
      {:ok, comments} ->
        comments
        |> Enum.find(&workpad_candidate?/1)
        |> case do
          nil -> :not_found
          comment -> {:ok, comment}
        end

      {:error, _reason} = err ->
        err
    end
  end

  defp workpad_candidate?(%{body: body} = comment) when is_binary(body) do
    is_nil(Map.get(comment, :resolved_at)) and String.contains?(body, @workpad_marker)
  end

  defp workpad_candidate?(_comment), do: false

  defp append_failure_section(body, section) when is_binary(body) do
    body_without_prior =
      case String.split(body, @escalation_section_marker, parts: 2) do
        [head, _tail] -> String.trim_trailing(head)
        [head] -> String.trim_trailing(head)
      end

    body_without_prior <> "\n\n" <> section
  end

  defp blocker_body(code, count, severity, escalation_state, section) do
    header =
      case severity do
        :alert -> "Symphony Deterministic Failure Alert"
        :escalate -> "Symphony Deterministic Failure Escalation"
      end

    """
    ## #{header}

    No `#{@workpad_marker}` comment was found on this issue, so this standalone
    blocker comment is being posted instead (per the workflow's blocked-access
    escape hatch).

    - Error code: `#{code}`
    - Consecutive failures: **#{count}**
    - Escalation state on threshold breach: `#{escalation_state}`

    #{section}
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp log_comment_intent(issue, code, count, severity, mode) do
    Logger.warning(
      "Deterministic-failure #{severity} #{mode}=workpad_comment " <>
        "#{issue_context(issue)} code=#{code} count=#{count}"
    )
  end

  defp issue_id(%Issue{id: id}) when is_binary(id), do: id
  defp issue_id(%{id: id}) when is_binary(id), do: id

  defp issue_context(%Issue{id: id, identifier: identifier}),
    do: "issue_id=#{id} issue_identifier=#{identifier}"

  defp issue_context(_issue), do: "issue_id=unknown"
end
