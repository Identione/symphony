defmodule SymphonyElixir.Overseer.PromptBuilder do
  @moduledoc """
  Renders the Layer 2 overseer prompt (IDE-212): a fixed system prompt plus a
  user message assembled from read-only evidence (issue, signals, git diff,
  build/test log tails, recent transcript window).

  The transcript renderer (`render_transcript/1`) consumes the *normalized*
  envelope shape both adapters emit (`%{event: ..., payload: ...}`), so identical
  envelopes render identically regardless of which adapter produced them — the
  adapter-agnostic consumption point the parity contract relies on.
  """

  @system_prompt """
  You are a turn-budget overseer for an autonomous coding agent. The agent works
  a single ticket in its own workspace over a bounded number of turns. You are
  invoked once, late in the budget, with read-only evidence about the run. Your
  job is to classify the run and recommend a single action. You cannot run tools,
  read files, or change anything — you only emit one structured verdict.

  Classify the run as one of:
    - "converging": acceptance criteria look met or nearly met; remaining gaps are
      finalization (e.g. uncommitted-but-finished work). The right move is usually
      a precise nudge (commit/push) or, if more turns are genuinely needed, a
      budget-extension recommendation.
    - "thrashing": repeated identical errors or oscillating diffs with no
      diagnostic progress. A nudge will not help; escalate for human triage.
    - "blocked": progress is stalled on an external dependency the agent cannot
      resolve itself (missing secret, upstream outage, unmet cross-issue blocker).

  Choose recommended_action from:
    - "continue": healthy; let the run proceed untouched.
    - "nudge": one concrete, actionable instruction will finalize the work. Put it
      in steering_message. Use this ONLY when a single nudge plausibly resolves the
      gap within the remaining turns.
    - "recommend_extend_budget": converging but needs more turns than remain. This
      only surfaces a recommendation to a human — it does NOT change the budget.
    - "escalate": route to a human; no automated nudge resolves this.
    - "abort": high-confidence wasted spend; stop now. Reserve for clear thrashing.

  You are judging this run against the issue's plan and acceptance criteria (the
  "## Symphony Workpad" section, when present) plus the deterministic Layer-1
  progress assessment. Decide whether more progress is genuinely expected.

  Hard rules:
    - steering_message MUST be non-null if and only if recommended_action is
      "nudge"; otherwise it MUST be null.
    - Be conservative: prefer "continue" or "nudge" over "escalate"/"abort" unless
      the evidence clearly shows wasted effort.
    - confidence is your calibrated probability (0..1) that the verdict is correct.
    - rationale is one short paragraph citing the concrete evidence.
    - When recommended_action is "escalate" or "abort", populate the optional
      "findings" object so a human can triage quickly: a one-line "summary", the
      concrete "blockers" you observed, and "next_steps_for_human". For
      continue/nudge/recommend_extend_budget, leave "findings" null.
  """

  @typedoc """
  Read-only evidence bundle assembled by `SymphonyElixir.Overseer`. All fields
  are optional; missing sections are simply omitted from the rendered message.
  """
  @type evidence :: %{
          optional(:issue_title) => String.t() | nil,
          optional(:issue_description) => String.t() | nil,
          optional(:workpad) => String.t() | nil,
          optional(:turn) => non_neg_integer(),
          optional(:max_turns) => non_neg_integer(),
          optional(:signals) => map() | nil,
          optional(:git_diff) => String.t() | nil,
          optional(:logs) => [{String.t(), String.t()}],
          optional(:transcript) => [map()]
        }

  @doc "The fixed system prompt. Exposed for tests/docs."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @system_prompt

  @doc "Render `%{system: ..., user: ...}` from the evidence bundle."
  @spec build(evidence()) :: %{system: String.t(), user: String.t()}
  def build(evidence) when is_map(evidence) do
    %{system: @system_prompt, user: render_user(evidence)}
  end

  @spec render_user(evidence()) :: String.t()
  defp render_user(evidence) do
    [
      section("ISSUE", render_issue(evidence)),
      section("PLAN / WORKPAD", present(evidence[:workpad])),
      section("BUDGET / SIGNALS", render_signals(evidence)),
      section("GIT DIFF (HEAD)", present(evidence[:git_diff])),
      section("BUILD / TEST LOGS", render_logs(evidence[:logs])),
      section("RECENT TRANSCRIPT", render_transcript(evidence[:transcript] || [])),
      "Emit your verdict by calling the emit_verdict tool exactly once."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @spec section(String.t(), String.t() | nil) :: String.t() | nil
  defp section(_label, nil), do: nil
  defp section(_label, ""), do: nil
  defp section(label, body), do: "## #{label}\n\n#{body}"

  @spec render_issue(evidence()) :: String.t() | nil
  defp render_issue(evidence) do
    title = present(evidence[:issue_title])
    desc = present(evidence[:issue_description])

    cond do
      title && desc -> "Title: #{title}\n\n#{desc}"
      title -> "Title: #{title}"
      desc -> desc
      true -> nil
    end
  end

  @spec render_signals(evidence()) :: String.t() | nil
  defp render_signals(evidence) do
    turn_line =
      case {evidence[:turn], evidence[:max_turns]} do
        {turn, max} when is_integer(turn) and is_integer(max) -> "Turn: #{turn}/#{max}"
        _ -> nil
      end

    signal_lines =
      case evidence[:signals] do
        signals when is_map(signals) and map_size(signals) > 0 ->
          signals
          |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
          |> Enum.sort()

        _ ->
          []
      end

    case Enum.reject([turn_line | signal_lines], &is_nil/1) do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  @spec render_logs([{String.t(), String.t()}] | nil) :: String.t() | nil
  defp render_logs(logs) when is_list(logs) and logs != [] do
    Enum.map_join(logs, "\n\n", fn {name, tail} -> "### #{name}\n```\n#{String.trim(tail)}\n```" end)
  end

  defp render_logs(_logs), do: nil

  @doc """
  Render a normalized transcript envelope window into a compact, deterministic
  string. Public so the parity test can assert adapter-agnostic rendering.
  """
  @spec render_transcript([map()]) :: String.t() | nil
  def render_transcript([]), do: nil

  def render_transcript(envelopes) when is_list(envelopes) do
    envelopes
    |> Enum.map(&render_envelope/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  @spec render_envelope(map()) :: String.t() | nil
  defp render_envelope(%{event: :assistant_message, payload: payload}) do
    "assistant: #{truncate(text_of(payload), 400)}"
  end

  defp render_envelope(%{event: :tool_call, payload: payload}) when is_map(payload) do
    name = payload[:name] || payload["name"] || "?"
    "tool_call: #{name} #{truncate(args_of(payload), 200)}" |> String.trim_trailing()
  end

  defp render_envelope(%{event: :turn_completed}), do: "— turn boundary —"
  defp render_envelope(%{event: event}) when is_atom(event), do: "event: #{event}"
  defp render_envelope(_other), do: nil

  @spec text_of(term()) :: String.t()
  defp text_of(payload) when is_map(payload), do: to_string(payload[:text] || payload["text"] || "")
  defp text_of(payload) when is_binary(payload), do: payload
  defp text_of(_payload), do: ""

  @spec args_of(map()) :: String.t()
  defp args_of(payload) do
    case payload[:input] || payload["input"] do
      nil -> ""
      input -> input |> inspect(limit: 8, printable_limit: 200) |> String.replace("\n", " ")
    end
  end

  @spec truncate(String.t(), pos_integer()) :: String.t()
  defp truncate(value, limit) when is_binary(value) do
    if String.length(value) > limit, do: String.slice(value, 0, limit) <> "…", else: value
  end

  @spec present(term()) :: String.t() | nil
  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_value), do: nil
end
