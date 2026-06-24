defmodule SymphonyElixir.Claude.QuotaCollectorTest do
  # async: false — exercises the CLAUDE_CODE_OAUTH_TOKEN env var and the OS clock.
  use ExUnit.Case, async: false

  alias SymphonyElixir.Claude.QuotaCollector
  alias SymphonyElixir.Config.Schema

  # Records that the CLI refresh was spawned (runs in the test process, so
  # `self()` is the test pid) and stands in for System.cmd/3.
  defmodule CmdStub do
    def run(bin, args, opts) do
      send(self(), {:cmd, bin, args, opts})
      {"", 0}
    end
  end

  # Like CmdStub, but also rewrites the credentials file the way a real
  # `claude` refresh would, so we can prove the fresh token is read afterwards.
  defmodule RefreshingCmdStub do
    def run(_bin, _args, opts) do
      dir =
        case List.keyfind(Keyword.get(opts, :env, []), "CLAUDE_CONFIG_DIR", 0) do
          {_, d} -> d
          _ -> nil
        end

      if dir do
        File.write!(
          Path.join(dir, ".credentials.json"),
          Jason.encode!(%{
            "claudeAiOauth" => %{
              "accessToken" => "tok-REFRESHED",
              "expiresAt" => System.os_time(:millisecond) + 28_800_000
            }
          })
        )
      end

      send(self(), {:cmd_refreshed, dir})
      {"", 0}
    end
  end

  defmodule HttpStub do
    def get(_url, opts) do
      send(self(), {:http_auth, List.keyfind(Keyword.get(opts, :headers, []), "authorization", 0)})
      {:ok, %{status: 200, body: %{"five_hour" => %{"utilization" => 10.0}}}}
    end
  end

  defp settings!(config_dir, quota_attrs) do
    {:ok, settings} =
      Schema.parse(%{
        "tracker" => %{"kind" => "memory"},
        "agent" => %{
          "kind" => "claude",
          "claude" => %{"config_dir" => config_dir, "quota" => quota_attrs}
        }
      })

    settings
  end

  defp write_credentials!(config_dir, expires_at_ms) do
    File.write!(
      Path.join(config_dir, ".credentials.json"),
      Jason.encode!(%{
        "claudeAiOauth" => %{"accessToken" => "tok-original", "expiresAt" => expires_at_ms}
      })
    )
  end

  defp tmp_config_dir do
    dir = Path.join(System.tmp_dir!(), "symphony-quota-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  setup do
    prior = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

    on_exit(fn ->
      if prior, do: System.put_env("CLAUDE_CODE_OAUTH_TOKEN", prior), else: System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
    end)

    :ok
  end

  test "claude_cli_refresh runs the CLI hook and reads the refreshed token when near expiry" do
    dir = tmp_config_dir()
    write_credentials!(dir, System.os_time(:millisecond) + 60_000)
    settings = settings!(dir, %{"enabled" => true, "token_source" => "claude_cli_refresh", "cli_refresh_margin_ms" => 300_000})

    assert {:ok, _snapshot} =
             QuotaCollector.fetch_once(settings, http_client: {HttpStub, :get}, cmd_runner: {RefreshingCmdStub, :run})

    assert_received {:cmd_refreshed, ^dir}
    # The usage request used the token the hook wrote, proving refresh-then-read order.
    assert_received {:http_auth, {"authorization", "Bearer tok-REFRESHED"}}
  end

  test "does not run the CLI hook when the cached token is still fresh" do
    dir = tmp_config_dir()
    write_credentials!(dir, System.os_time(:millisecond) + 3_600_000)
    settings = settings!(dir, %{"enabled" => true, "token_source" => "claude_cli_refresh", "cli_refresh_margin_ms" => 300_000})

    assert {:ok, _} = QuotaCollector.fetch_once(settings, http_client: {HttpStub, :get}, cmd_runner: {CmdStub, :run})

    refute_received {:cmd, _, _, _}
    assert_received {:http_auth, {"authorization", "Bearer tok-original"}}
  end

  test "credentials_file token_source never runs the CLI hook even near expiry" do
    dir = tmp_config_dir()
    write_credentials!(dir, System.os_time(:millisecond) + 1_000)
    settings = settings!(dir, %{"enabled" => true, "token_source" => "credentials_file"})

    assert {:ok, _} = QuotaCollector.fetch_once(settings, http_client: {HttpStub, :get}, cmd_runner: {CmdStub, :run})

    refute_received {:cmd, _, _, _}
  end

  test "CLAUDE_CODE_OAUTH_TOKEN wins and skips the CLI hook" do
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "env-token")
    dir = tmp_config_dir()
    write_credentials!(dir, System.os_time(:millisecond) + 1_000)
    settings = settings!(dir, %{"enabled" => true, "token_source" => "claude_cli_refresh", "cli_refresh_margin_ms" => 300_000})

    assert {:ok, _} = QuotaCollector.fetch_once(settings, http_client: {HttpStub, :get}, cmd_runner: {CmdStub, :run})

    refute_received {:cmd, _, _, _}
    assert_received {:http_auth, {"authorization", "Bearer env-token"}}
  end

  describe "next_delay/3 backoff" do
    @quota %{refresh_ms: 60_000, max_backoff_ms: 900_000}

    test "no failures polls at the steady-state interval" do
      assert QuotaCollector.next_delay(@quota, 0, nil) == 60_000
      # A Retry-After on the success path is irrelevant.
      assert QuotaCollector.next_delay(@quota, 0, 300_000) == 60_000
    end

    test "delay grows exponentially per consecutive failure (with <=10% jitter)" do
      assert_within(QuotaCollector.next_delay(@quota, 1, nil), 60_000)
      assert_within(QuotaCollector.next_delay(@quota, 2, nil), 120_000)
      assert_within(QuotaCollector.next_delay(@quota, 3, nil), 240_000)
      assert_within(QuotaCollector.next_delay(@quota, 4, nil), 480_000)
    end

    test "backoff is capped at max_backoff_ms" do
      # 60_000 * 2^4 = 960_000 > 900_000 cap.
      assert_within(QuotaCollector.next_delay(@quota, 5, nil), 900_000)
      # A large failure count never exceeds the cap (exponent is bounded).
      assert_within(QuotaCollector.next_delay(@quota, 1_000, nil), 900_000)
    end

    test "Retry-After acts as a floor over the computed backoff" do
      # First failure backoff is 60_000, but the server asked for 300_000.
      assert_within(QuotaCollector.next_delay(@quota, 1, 300_000), 300_000)
      # When backoff already exceeds Retry-After, backoff wins.
      assert_within(QuotaCollector.next_delay(@quota, 4, 300_000), 480_000)
    end

    test "falls back to defaults when the quota map omits the knobs" do
      assert QuotaCollector.next_delay(%{}, 0, nil) == 60_000
      assert_within(QuotaCollector.next_delay(%{}, 1, nil), 60_000)
      # Default cap is 900_000.
      assert_within(QuotaCollector.next_delay(%{}, 100, nil), 900_000)
    end

    # The delay floors at `expected` and adds at most ~10% upward jitter.
    defp assert_within(actual, expected) do
      assert actual >= expected
      assert actual <= expected + div(expected, 10) + 1
    end
  end
end
