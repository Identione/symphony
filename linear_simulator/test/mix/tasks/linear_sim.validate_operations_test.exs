defmodule Mix.Tasks.LinearSim.ValidateOperationsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.LinearSim.ValidateOperations, as: Validate

  describe "quadrant/2" do
    test "maps the four-quadrant compatibility matrix" do
      assert Validate.quadrant(true, true) == :good
      assert Validate.quadrant(true, false) == :simulator_missing_support
      assert Validate.quadrant(false, true) == :stale_simulator_schema
      assert Validate.quadrant(false, false) == :captured_op_wrong
    end
  end

  describe "classify_all/1 against the committed Linear reference" do
    test "every curated operation is valid against both schemas" do
      result = Validate.classify_all([])

      assert result.reference == :loaded
      assert result.required_failures == []
      assert Enum.all?(result.results, &(&1.quadrant == :good))
      assert length(result.results) == 12
    end
  end

  describe "classify_all/1 when the reference snapshot is absent" do
    test "skips the reference check but still validates against the simulator" do
      result = Validate.classify_all(reference_path: "priv/linear/__missing__.json")

      assert result.reference == :skipped
      assert Enum.all?(result.results, &(&1.linear == :skipped))
      assert result.required_failures == []
    end
  end

  describe "classify_all/1 with a simulator-invalid operation" do
    test "flags it as a required failure" do
      dir = Path.join(System.tmp_dir!(), "validate_bad_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(Path.join(dir, "operation.graphql"), "query { viewer { totallyBogusField } }")
      File.write!(Path.join(dir, "variables.json"), "{}")

      result = Validate.classify_all(dirs: [dir], reference_path: "priv/linear/__missing__.json")

      assert [name] = result.required_failures
      assert name == Path.basename(dir)
      assert [%{sim_ok?: false}] = result.results
    end
  end
end
