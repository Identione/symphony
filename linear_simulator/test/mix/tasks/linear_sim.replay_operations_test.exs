defmodule Mix.Tasks.LinearSim.ReplayOperationsTest do
  use LinearSim.DataCase, async: false

  alias Mix.Tasks.LinearSim.ReplayOperations

  test "replays the whole curated corpus successfully" do
    summary = ReplayOperations.replay_all([])

    assert summary.total == 12
    assert summary.ok == 12
    assert summary.failures == []
  end

  test "records a failure when an expected path does not match" do
    dir = Path.join(System.tmp_dir!(), "replay_bad_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    File.write!(Path.join(dir, "operation.graphql"), "query Bad { viewer { id } }")
    File.write!(Path.join(dir, "variables.json"), "{}")

    File.write!(
      Path.join(dir, "metadata.json"),
      Jason.encode!(%{
        "name" => "bad_expectation",
        "scenario" => "basic_workspace",
        "operationName" => "Bad",
        "auth" => "Bearer user_hakan",
        "expected" => %{"allowErrors" => false, "paths" => %{"data.viewer.id" => "WRONG"}}
      })
    )

    summary = ReplayOperations.replay_all(dirs: [dir])

    assert summary.total == 1
    assert summary.ok == 0
    assert [%{reason: reason}] = summary.failures
    assert reason =~ "data.viewer.id"
  end
end
