defmodule SymphonyElixir.WorkflowTemplateDelegationModeTest do
  # `repo.delegation_mode: workflow` bakes a "Workflow mode" rule into the
  # Claude Delegation section of the prompt body. It must render only when the
  # knob is set, and at prompt time it must step aside for an issue labelled
  # `no-workflow` (a Liquid check on the live issue labels).
  use ExUnit.Case, async: true

  @template Path.expand("../../priv/templates/workflow.md.eex", __DIR__)
  @marker "You are working on a Linear ticket"
  @render_opts [strict_variables: true, strict_filters: true]

  defp body(delegation_mode) do
    [_, rest] = String.split(File.read!(@template), @marker, parts: 2)

    EEx.eval_string(@marker <> rest,
      assigns: [base_branch: nil, gate_command: nil, worker_notes: nil, delegation_mode: delegation_mode]
    )
  end

  defp prompt(body, labels, kind \\ "claude") do
    body
    |> Solid.parse!()
    |> Solid.render!(
      %{
        "agent" => %{"kind" => kind},
        "attempt" => nil,
        "issue" => %{
          "identifier" => "IDE-1",
          "title" => "t",
          "state" => "Todo",
          "labels" => labels,
          "url" => "u",
          "description" => "d"
        }
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  test "without the knob the body has no Workflow mode rule" do
    refute body(nil) =~ "Workflow mode"
    refute prompt(body(nil), ["symphony"]) =~ "Workflow mode"
  end

  test "delegation_mode workflow makes Workflow the default implementation path for claude" do
    rendered = prompt(body("workflow"), ["symphony"])

    assert rendered =~ "Workflow mode"
    assert rendered =~ "workflow-authoring"
    assert rendered =~ "never poll it"
    assert rendered =~ "Workflow: done"
    # The verify agent's proof rule (the IDE-602 gap).
    assert rendered =~ "only if its environment enforces that behavior"
    # The harness-reminder line names Workflow as allowed.
    assert rendered =~ "the `Agent` and `Workflow` tools are allowed and expected"
  end

  test "the no-workflow label opts a single issue out at prompt time" do
    rendered = prompt(body("workflow"), ["symphony", "no-workflow"])

    refute rendered =~ "Workflow mode"
    assert rendered =~ "the `Agent` tool is allowed and expected"
  end

  test "codex sessions never see the Workflow rule" do
    refute prompt(body("workflow"), ["symphony"], "codex") =~ "Workflow mode"
  end
end
