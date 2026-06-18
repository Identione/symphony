defmodule SymphonyElixir.Overseer.PromptBuilderTest do
  @moduledoc """
  Rendering coverage for the Layer 2 overseer prompt (IDE-212): section omission,
  the build/test-log fencing, and the adapter-parity contract — identical
  normalized envelopes render identically regardless of which adapter produced
  them.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.Overseer.PromptBuilder

  test "build/1 carries the fixed system prompt and a user message" do
    %{system: system, user: user} = PromptBuilder.build(%{issue_title: "Ship it"})
    assert system == PromptBuilder.system_prompt()
    assert user =~ "## ISSUE"
    assert user =~ "Ship it"
    assert user =~ "emit_verdict"
  end

  test "omits sections whose evidence is absent or blank" do
    %{user: user} = PromptBuilder.build(%{git_diff: "   ", logs: [], transcript: []})
    refute user =~ "## GIT DIFF"
    refute user =~ "## BUILD / TEST LOGS"
    refute user =~ "## RECENT TRANSCRIPT"
  end

  test "renders the budget/turn line and sorted signals" do
    %{user: user} =
      PromptBuilder.build(%{turn: 18, max_turns: 20, signals: %{commits: 0, dirty: true}})

    assert user =~ "Turn: 18/20"
    assert user =~ "commits: 0"
    assert user =~ "dirty: true"
  end

  test "fences build/test log tails under their names" do
    %{user: user} = PromptBuilder.build(%{logs: [{"tmp/build.log", "  error: boom  "}]})
    assert user =~ "### tmp/build.log"
    assert user =~ "```\nerror: boom\n```"
  end

  describe "render_transcript/1 (adapter parity)" do
    test "identical normalized envelopes render identically" do
      envelopes = [
        %{event: :assistant_message, payload: %{text: "working on it"}},
        %{event: :tool_call, payload: %{name: "shell", input: %{cmd: "ls"}}},
        %{event: :turn_completed, payload: %{}}
      ]

      # Both adapters emit the same `%{event:, payload:}` shape, so the consumer
      # is adapter-agnostic by construction: the two lists are byte-identical.
      codex_render = PromptBuilder.render_transcript(envelopes)
      claude_render = PromptBuilder.render_transcript(envelopes)

      assert codex_render == claude_render
      assert codex_render =~ "assistant: working on it"
      assert codex_render =~ "tool_call: shell"
      assert codex_render =~ "— turn boundary —"
    end

    test "accepts string-keyed payloads (claude shape) the same as atom-keyed (codex shape)" do
      atom_keyed = [%{event: :tool_call, payload: %{name: "shell", input: %{cmd: "ls"}}}]
      string_keyed = [%{event: :tool_call, payload: %{"name" => "shell", "input" => %{"cmd" => "ls"}}}]

      assert PromptBuilder.render_transcript(atom_keyed) =~ "tool_call: shell"
      assert PromptBuilder.render_transcript(string_keyed) =~ "tool_call: shell"
    end

    test "empty window renders nil" do
      assert PromptBuilder.render_transcript([]) == nil
    end

    test "truncates very long assistant text" do
      long = String.duplicate("x", 1000)
      rendered = PromptBuilder.render_transcript([%{event: :assistant_message, payload: %{text: long}}])
      assert String.contains?(rendered, "…")
    end
  end
end
