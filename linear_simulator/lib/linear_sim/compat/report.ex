defmodule LinearSim.Compat.Report do
  @moduledoc """
  Aggregates compatibility signals into the report described in
  docs/linear-sim.md §8: how many curated operations validate against each schema,
  how many replay, and which fields/behaviours are missing, stale, or
  intentionally different.

  `build/1` is pure — it takes already-gathered inputs (so it is unit-testable
  without the app) and `mix linear_sim.compatibility_report` does the gathering.
  """

  @enforce_keys [:curated_count, :validate_linear, :validate_sim, :replay]
  defstruct curated_count: 0,
            validate_linear: "0/0",
            validate_sim: "0/0",
            replay: "0/0",
            missing_simulator_fields: [],
            stale_simulator_fields: [],
            behavioral_gaps: []

  @type t :: %__MODULE__{
          curated_count: non_neg_integer(),
          validate_linear: String.t(),
          validate_sim: String.t(),
          replay: String.t(),
          missing_simulator_fields: [String.t()],
          stale_simulator_fields: [String.t()],
          behavioral_gaps: [String.t()]
        }

  @type inputs :: %{
          required(:curated_count) => non_neg_integer(),
          required(:reference) => :loaded | :skipped,
          required(:validate_results) => [%{sim_ok?: boolean(), linear_ok?: boolean()}],
          required(:replay) => %{total: non_neg_integer(), ok: non_neg_integer()},
          optional(:missing_simulator_fields) => [String.t()],
          optional(:stale_simulator_fields) => [String.t()],
          optional(:behavioral_gaps) => [String.t()]
        }

  @doc "Builds a report struct from gathered inputs."
  @spec build(inputs()) :: t()
  def build(inputs) do
    total = length(inputs.validate_results)
    sim_ok = Enum.count(inputs.validate_results, & &1.sim_ok?)
    linear_ok = Enum.count(inputs.validate_results, & &1.linear_ok?)

    %__MODULE__{
      curated_count: inputs.curated_count,
      validate_sim: "#{sim_ok}/#{total}",
      validate_linear:
        if(inputs.reference == :skipped, do: "skipped", else: "#{linear_ok}/#{total}"),
      replay: "#{inputs.replay.ok}/#{inputs.replay.total}",
      missing_simulator_fields: Map.get(inputs, :missing_simulator_fields, []),
      stale_simulator_fields: Map.get(inputs, :stale_simulator_fields, []),
      behavioral_gaps: Map.get(inputs, :behavioral_gaps, [])
    }
  end

  @doc "Renders the report as the docs §8 plain-text format."
  @spec to_text(t()) :: String.t()
  def to_text(%__MODULE__{} = r) do
    """
    Linear Simulator Compatibility Report

    Schemas:
    - Linear reference: priv/linear/schema_reference.graphql
    - Simulator: priv/linear_sim/schema.graphql

    Operations:
    - Curated operations: #{r.curated_count}
    - Validate against Linear: #{r.validate_linear}
    - Validate against simulator: #{r.validate_sim}
    - Replay successfully: #{r.replay}

    #{section("Missing simulator fields:", r.missing_simulator_fields)}
    #{section("Stale simulator fields:", r.stale_simulator_fields)}
    #{section("Behavioral gaps:", r.behavioral_gaps)}
    """
  end

  @doc "Renders the report as JSON for CI artifacts."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = r) do
    Jason.encode!(
      %{
        "curatedCount" => r.curated_count,
        "validateAgainstLinear" => r.validate_linear,
        "validateAgainstSimulator" => r.validate_sim,
        "replaySuccessful" => r.replay,
        "missingSimulatorFields" => r.missing_simulator_fields,
        "staleSimulatorFields" => r.stale_simulator_fields,
        "behavioralGaps" => r.behavioral_gaps
      },
      pretty: true
    )
  end

  defp section(heading, []), do: heading <> "\n- (none)"

  defp section(heading, items) do
    heading <> "\n" <> Enum.map_join(items, "\n", &"- #{&1}")
  end
end
