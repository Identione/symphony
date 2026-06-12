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

  test "record_rate_limited never shortens an already-longer back-off" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.record_rate_limited(3_600_000) == 3_600_000
      # A subsequent shorter arm (e.g. a bare 429 with no body duration) must
      # not stomp the longer active window down to 60s.
      assert RateLimit.record_rate_limited(60_000) == 3_600_000
    end)

    retry_after = RateLimit.retry_after_ms()
    assert is_integer(retry_after) and retry_after > 1_000_000 and retry_after <= 3_600_000
  end

  test "maybe_record_response/2 on a bare 429 does not shorten an existing longer window" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.record_rate_limited(3_600_000) == 3_600_000
      assert RateLimit.maybe_record_response(429, "Too Many Requests") == :rate_limited
    end)

    retry_after = RateLimit.retry_after_ms()
    assert is_integer(retry_after) and retry_after > 1_000_000 and retry_after <= 3_600_000
  end

  test "record_rate_limited still extends the window when the new back-off is longer" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.record_rate_limited(1_000) == 1_000
      assert RateLimit.record_rate_limited(3_600_000) == 3_600_000
    end)

    assert RateLimit.retry_after_ms() > 1_000_000
  end

  test "rate_limited_body? does not flag an unrelated body mentioning 'rate limit'" do
    refute RateLimit.rate_limited_body?("GraphQL validation failed: rate limit must be an integer")
    refute RateLimit.rate_limited_body?(%{"errors" => [%{"message" => "rate limit must be an integer"}]})
  end

  test "rate_limited_status? is true only for 429" do
    assert RateLimit.rate_limited_status?(429)
    refute RateLimit.rate_limited_status?(400)
    refute RateLimit.rate_limited_status?(200)
  end

  test "maybe_record_response/2 arms the breaker on a 429 regardless of body shape" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.maybe_record_response(429, %{"unexpected" => "shape"}) == :rate_limited
    end)

    refute RateLimit.allowed?()
  end

  test "maybe_record_response/2 leaves the breaker closed for a 400 with an ordinary body" do
    assert RateLimit.maybe_record_response(400, %{
             "errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"}}]
           }) == :ok

    assert RateLimit.allowed?()
  end

  test "maybe_record_response/2 mines the body duration even when armed by status" do
    body = %{
      "errors" => [
        %{"extensions" => %{"code" => "RATELIMITED", "meta" => %{"rateLimitResult" => %{"duration" => 3_600_000}}}}
      ]
    }

    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.maybe_record_response(429, body) == :rate_limited
    end)

    retry_after = RateLimit.retry_after_ms()
    assert is_integer(retry_after) and retry_after > 1_000_000 and retry_after <= 3_600_000
  end

  test "rate_limited_body? detects RATELIMITED in an undecoded string body" do
    assert RateLimit.rate_limited_body?(~s({"errors":[{"extensions":{"code":"RATELIMITED"}}]}))
  end

  test "rate_limited_body? detects a plain-text rate limit page" do
    assert RateLimit.rate_limited_body?("429 Too Many Requests - rate limit exceeded")
  end

  test "rate_limited_body? returns false for an unrelated string body" do
    refute RateLimit.rate_limited_body?("Internal Server Error")
  end

  test "maybe_record_response on a string RATELIMITED body falls back to the default throttle" do
    ExUnit.CaptureLog.capture_log(fn ->
      assert RateLimit.maybe_record_response(~s({"errors":[{"extensions":{"code":"RATELIMITED"}}]})) ==
               :rate_limited
    end)

    refute RateLimit.allowed?()
    retry_after = RateLimit.retry_after_ms()
    assert is_integer(retry_after) and retry_after > 0 and retry_after <= 60_000
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
