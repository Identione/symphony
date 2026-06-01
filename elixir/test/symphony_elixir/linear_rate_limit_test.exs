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
end
