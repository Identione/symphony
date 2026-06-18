defmodule Mix.Tasks.LinearSim.CompatibilityReportTest do
  use LinearSim.DataCase, async: false

  alias Mix.Tasks.LinearSim.CompatibilityReport

  test "writes the txt and json artifacts and reports the curated corpus" do
    out_dir = Path.join(System.tmp_dir!(), "compat_report_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(out_dir) end)

    assert {:ok, paths, report} = CompatibilityReport.write(out_dir: out_dir)

    assert File.exists?(paths.txt)
    assert File.exists?(paths.json)

    assert report.curated_count == 12
    assert report.validate_linear == "12/12"
    assert report.validate_sim == "12/12"
    assert report.replay == "12/12"

    decoded = paths.json |> File.read!() |> Jason.decode!()
    assert decoded["curatedCount"] == 12

    assert File.read!(paths.txt) =~ "Linear Simulator Compatibility Report"
  end
end
