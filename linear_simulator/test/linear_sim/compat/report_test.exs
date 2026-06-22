defmodule LinearSim.Compat.ReportTest do
  use ExUnit.Case, async: true

  alias LinearSim.Compat.Report

  defp inputs do
    %{
      curated_count: 12,
      reference: :loaded,
      validate_results: [
        %{name: "a", sim_ok?: true, linear_ok?: true},
        %{name: "b", sim_ok?: true, linear_ok?: true},
        %{name: "c", sim_ok?: false, linear_ok?: true}
      ],
      replay: %{total: 12, ok: 11},
      missing_simulator_fields: ["Issue.branchName used by symphony_linear_poll"],
      unimplemented_reference_fields: ["Comment.url"],
      stale_simulator_fields: ["RootQueryType.apiVersion"],
      observed_unsupported: [~s|Cannot query field "url" on type "Comment".|],
      behavioral_gaps: ["symphony_linear_poll: hasNextPage is computed from scenario data"]
    }
  end

  describe "build/1" do
    test "computes the headline counts" do
      report = Report.build(inputs())

      assert report.curated_count == 12
      assert report.validate_sim == "2/3"
      assert report.validate_linear == "3/3"
      assert report.replay == "11/12"
    end

    test "reports 'skipped' for the Linear column when the reference is absent" do
      report = Report.build(%{inputs() | reference: :skipped})
      assert report.validate_linear == "skipped"
    end
  end

  describe "to_text/1" do
    test "renders the documented section headings and values" do
      text = inputs() |> Report.build() |> Report.to_text()

      assert text =~ "Linear Simulator Compatibility Report"
      assert text =~ "Missing simulator fields:"
      assert text =~ "Issue.branchName used by symphony_linear_poll"
      assert text =~ "Unimplemented reference fields (on implemented types):"
      assert text =~ "Comment.url"
      assert text =~ "Observed unsupported operations:"
      assert text =~ ~s|Cannot query field "url" on type "Comment".|
      assert text =~ "Behavioral gaps:"
      assert text =~ "hasNextPage"
    end
  end

  describe "to_json/1" do
    test "round-trips through Jason" do
      json = inputs() |> Report.build() |> Report.to_json()
      decoded = Jason.decode!(json)

      assert decoded["curatedCount"] == 12
      assert decoded["validateAgainstSimulator"] == "2/3"
      assert decoded["replaySuccessful"] == "11/12"
      assert decoded["unimplementedReferenceFields"] == ["Comment.url"]
      assert decoded["observedUnsupported"] == [~s|Cannot query field "url" on type "Comment".|]
    end
  end
end
