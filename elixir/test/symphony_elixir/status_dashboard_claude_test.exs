defmodule SymphonyElixir.StatusDashboardClaudeTest do
  use SymphonyElixir.TestSupport

  @terminal_columns 115

  defp claude_running_entry(overrides) do
    Map.merge(
      %{
        identifier: "MT-700",
        state: "running",
        session_id: "claude-session-abcdef1234567890",
        agent_kind: :claude,
        codex_app_server_pid: nil,
        codex_total_tokens: 0,
        claude_app_server_pid: "9999",
        claude_input_tokens: 4_000,
        claude_output_tokens: 1_500,
        claude_total_tokens: 5_500,
        claude_cache_creation_input_tokens: 800,
        claude_cache_read_input_tokens: 1_200,
        runtime_seconds: 90,
        turn_count: 3,
        last_codex_event: "turn_completed",
        last_codex_message: %{
          event: :turn_completed,
          message: %{"type" => "turn_end", "usage" => %{}}
        }
      },
      overrides
    )
  end

  test "claude running row shows claude_total_tokens in the tokens column" do
    rendered =
      claude_running_entry(%{claude_total_tokens: 14_500})
      |> StatusDashboard.format_running_summary_for_test(@terminal_columns)

    assert rendered =~ "MT-700"
    assert rendered =~ "14,500", "expected claude_total_tokens (14,500) in: #{inspect(rendered)}"

    refute rendered =~ ~r/\b0\b\s+claude-session/,
           "tokens column rendered as 0 even though claude_total_tokens=14,500: #{inspect(rendered)}"
  end

  test "claude running row shows claude_app_server_pid in the pid column" do
    rendered =
      claude_running_entry(%{claude_app_server_pid: "7777", codex_app_server_pid: nil})
      |> StatusDashboard.format_running_summary_for_test(@terminal_columns)

    assert rendered =~ "7777", "expected claude pid (7777) in: #{inspect(rendered)}"
    refute rendered =~ "n/a", "pid column showed n/a despite claude_app_server_pid=7777"
  end

  test "codex running row keeps using codex_total_tokens / codex_app_server_pid" do
    codex_entry = %{
      identifier: "MT-101",
      state: "running",
      session_id: "thread-1234567890",
      agent_kind: :codex,
      codex_app_server_pid: "4242",
      codex_total_tokens: 120_450,
      claude_app_server_pid: nil,
      claude_total_tokens: 0,
      runtime_seconds: 60,
      turn_count: 1,
      last_codex_event: :notification,
      last_codex_message: %{
        event: :notification,
        message: %{"method" => "turn/started", "params" => %{}}
      }
    }

    rendered = StatusDashboard.format_running_summary_for_test(codex_entry, @terminal_columns)

    assert rendered =~ "4242"
    assert rendered =~ "120,450"
  end

  test "snapshot top panel sums codex + claude totals when both are nonzero" do
    snapshot_data =
      {:ok,
       %{
         running: [
           claude_running_entry(%{
             claude_input_tokens: 8_000,
             claude_output_tokens: 2_000,
             claude_total_tokens: 10_000,
             claude_cache_creation_input_tokens: 600,
             claude_cache_read_input_tokens: 400
           })
         ],
         retrying: [],
         codex_totals: %{
           input_tokens: 1_000,
           output_tokens: 200,
           total_tokens: 1_200,
           seconds_running: 30
         },
         claude_totals: %{
           input_tokens: 8_000,
           output_tokens: 2_000,
           total_tokens: 10_000,
           cache_creation_input_tokens: 600,
           cache_read_input_tokens: 400,
           seconds_running: 90
         },
         rate_limits: nil
       }}

    rendered =
      StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0, @terminal_columns)

    assert rendered =~ "in 9,000",
           "expected combined input tokens (codex 1,000 + claude 8,000 = 9,000): #{inspect(rendered)}"

    assert rendered =~ "out 2,200",
           "expected combined output tokens (codex 200 + claude 2,000 = 2,200): #{inspect(rendered)}"

    assert rendered =~ "total 11,200",
           "expected combined total tokens (codex 1,200 + claude 10,000 = 11,200): #{inspect(rendered)}"
  end

  test "snapshot top panel renders claude cache sublabel when cache fields are nonzero" do
    snapshot_data =
      {:ok,
       %{
         running: [claude_running_entry(%{})],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         claude_totals: %{
           input_tokens: 4_000,
           output_tokens: 1_500,
           total_tokens: 5_500,
           cache_creation_input_tokens: 800,
           cache_read_input_tokens: 1_200,
           seconds_running: 90
         },
         rate_limits: nil
       }}

    rendered =
      StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0, @terminal_columns)

    assert rendered =~ "Cache:",
           "expected a 'Cache:' line for claude_totals with nonzero cache fields: #{inspect(rendered)}"

    assert rendered =~ "created 800"
    assert rendered =~ "read 1,200"
  end

  describe "snapshot pipeline (snapshot_with_samples + snapshot_total_tokens)" do
    # Regression for IDE-66 rework: the inner snapshot wrapper used to drop
    # `claude_totals` (and the TPS sampler used to ignore claude tokens), so
    # the CLI header rendered `Tokens: in 0 | out 0 | total 0` even while
    # `state.claude_totals` was non-zero — the rework feedback signal.
    test "forwards claude_totals end-to-end so the header reflects a claude-only run" do
      snapshot_payload_result =
        {:ok,
         %{
           running: [claude_running_entry(%{})],
           retrying: [],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           claude_totals: %{
             input_tokens: 4_000,
             output_tokens: 1_500,
             total_tokens: 5_500,
             cache_creation_input_tokens: 800,
             cache_read_input_tokens: 1_200,
             seconds_running: 90
           },
           rate_limits: nil,
           polling: nil
         }}

      {snapshot_data, _samples} =
        StatusDashboard.snapshot_with_samples_for_test(snapshot_payload_result, [], 1_000)

      rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0, @terminal_columns)

      assert rendered =~ "in 4,000",
             "claude input tokens should reach the header: #{inspect(rendered)}"

      assert rendered =~ "out 1,500"
      assert rendered =~ "total 5,500"
      assert rendered =~ "Cache:"
      assert rendered =~ "created 800"
      assert rendered =~ "read 1,200"
    end

    test "TPS sampler combines codex + claude total tokens" do
      snapshot_payload_result =
        {:ok,
         %{
           running: [],
           retrying: [],
           codex_totals: %{input_tokens: 700, output_tokens: 300, total_tokens: 1_000, seconds_running: 0},
           claude_totals: %{
             input_tokens: 400,
             output_tokens: 100,
             total_tokens: 500,
             cache_creation_input_tokens: 0,
             cache_read_input_tokens: 0,
             seconds_running: 0
           },
           rate_limits: nil,
           polling: nil
         }}

      {_snapshot_data, samples} =
        StatusDashboard.snapshot_with_samples_for_test(snapshot_payload_result, [], 5_000)

      assert {5_000, 1_500} in samples,
             "expected combined codex+claude total_tokens (1,000 + 500) sampled at now_ms: #{inspect(samples)}"
    end

    test "snapshot_total_tokens combines codex + claude totals" do
      snapshot_data =
        {:ok,
         %{
           codex_totals: %{total_tokens: 2_500},
           claude_totals: %{total_tokens: 1_750}
         }}

      assert StatusDashboard.snapshot_total_tokens_for_test(snapshot_data) == 4_250
    end

    test "snapshot_total_tokens treats missing claude_totals as zero (codex-only path)" do
      snapshot_data = {:ok, %{codex_totals: %{total_tokens: 9_000}}}

      assert StatusDashboard.snapshot_total_tokens_for_test(snapshot_data) == 9_000
    end

    test "snapshot pipeline propagates :error without sampling tokens" do
      assert {:error, []} = StatusDashboard.snapshot_with_samples_for_test(:error, [], 100)
    end
  end

  test "snapshot top panel omits cache sublabel when claude cache fields are all zero" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         claude_totals: %{
           input_tokens: 0,
           output_tokens: 0,
           total_tokens: 0,
           cache_creation_input_tokens: 0,
           cache_read_input_tokens: 0,
           seconds_running: 0
         },
         rate_limits: nil
       }}

    rendered =
      StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0, @terminal_columns)

    refute rendered =~ "Cache:",
           "did not expect a 'Cache:' line when all claude cache fields are zero"
  end
end
