defmodule SymphonyElixir.LinearRateLimitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.RateLimit

  setup do
    RateLimit.clear()
    on_exit(fn -> RateLimit.clear() end)
    :ok
  end

  test "allowed? defaults to true and retry_after_ms is nil when no back-off is recorded" do
    assert RateLimit.allowed?()
    assert RateLimit.retry_after_ms() == nil
  end

  test "record_rate_limited extracts duration from the meta.rateLimitResult body" do
    body = %{
      "errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}],
      "meta" => %{"rateLimitResult" => %{"remaining" => 0, "duration" => 3_600_000, "limit" => 2500}}
    }

    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.record_rate_limited(body) == 3_600_000
    end)

    refute RateLimit.allowed?()
    retry_after = RateLimit.retry_after_ms()
    assert is_integer(retry_after) and retry_after > 0 and retry_after <= 3_600_000
  end

  test "record_rate_limited falls back to default throttle when duration is missing" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.record_rate_limited(%{}) == 60_000
    end)

    refute RateLimit.allowed?()
    assert RateLimit.retry_after_ms() > 0
  end

  test "record_rate_limited accepts a raw duration integer" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.record_rate_limited(250) == 250
    end)

    refute RateLimit.allowed?()
  end

  test "clear removes the recorded back-off" do
    ExUnit.CaptureLog.capture_log(fn -> RateLimit.record_rate_limited(5_000) end)
    refute RateLimit.allowed?()

    :ok = RateLimit.clear()
    assert RateLimit.allowed?()
    assert RateLimit.retry_after_ms() == nil
  end

  test "rate_limited_body? detects the RATELIMITED error code among mixed errors" do
    body = %{
      "errors" => [
        %{"message" => "unrelated"},
        %{"extensions" => %{"code" => "RATELIMITED"}}
      ]
    }

    assert RateLimit.rate_limited_body?(body)
  end

  test "rate_limited_body? detects an exhausted remaining budget without an error code" do
    assert RateLimit.rate_limited_body?(%{
             "meta" => %{"rateLimitResult" => %{"remaining" => 0}}
           })
  end

  test "rate_limited_body? returns false for an ordinary response" do
    refute RateLimit.rate_limited_body?(%{"data" => %{"viewer" => %{"id" => "user-1"}}})
  end

  test "maybe_record_response records a back-off only for rate-limited bodies" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.maybe_record_response(%{
               "errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]
             }) == :rate_limited
    end)

    refute RateLimit.allowed?()

    RateLimit.clear()
    assert RateLimit.maybe_record_response(%{"data" => %{"viewer" => %{"id" => "user-1"}}}) == :ok
    assert RateLimit.allowed?()
  end

  test "record_rate_limited falls back to the default throttle for a nil input" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.record_rate_limited(nil) == 60_000
    end)

    refute RateLimit.allowed?()
  end

  test "record_rate_limited reads the duration nested under errors extensions" do
    body = %{
      "errors" => [
        %{"message" => "no extensions"},
        %{"extensions" => %{"rateLimitResult" => %{"duration" => 7_000}}}
      ]
    }

    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.record_rate_limited(body) == 7_000
    end)
  end

  test "start_link/0 resolves to the already-running supervised instance" do
    assert {:error, {:already_started, pid}} = RateLimit.start_link()
    assert is_pid(pid)
  end

  test "queries tolerate a missing ETS table and the supervisor rebuilds it" do
    # Terminating the supervised owner drops its ETS table, so lookups fall back
    # to the no-back-off default until the supervisor restarts the process and
    # `init/1` recreates the table. This test is synchronous, so no other test
    # touches RateLimit while the table is gone.
    on_exit(fn ->
      Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Linear.RateLimit)
    end)

    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Linear.RateLimit)

    assert RateLimit.allowed?()
    assert RateLimit.retry_after_ms() == nil

    {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Linear.RateLimit)

    assert RateLimit.allowed?()
  end
end
