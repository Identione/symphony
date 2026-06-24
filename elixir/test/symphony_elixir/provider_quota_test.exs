defmodule SymphonyElixir.ProviderQuotaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProviderQuota

  test "normalizes Claude OAuth usage buckets" do
    snapshot =
      ProviderQuota.normalize_claude(
        %{
          "five_hour" => %{"utilization" => 72.5, "resets_at" => "2026-06-11T12:00:00Z"},
          "seven_day_opus" => %{"utilization" => 41.0, "resets_at" => "2026-06-12T12:00:00Z"},
          "omelette_promotional" => %{"utilization" => 10.0},
          "extra_usage" => %{"is_enabled" => true, "utilization" => 5.0}
        },
        now_ms: 1_000,
        stale_after_ms: 180_000
      )

    assert snapshot.provider == :claude
    assert snapshot.buckets["five_hour"].used_percent == 72.5
    assert snapshot.buckets["seven_day_opus"].resets_at == "2026-06-12T12:00:00Z"
    assert snapshot.buckets["seven_day_design"].used_percent == 10.0
    assert snapshot.credits == %{"is_enabled" => true, "utilization" => 5.0}
    refute ProviderQuota.active_quota_exhausted?(snapshot, 95, 1_100)
  end

  test "normalizes current Codex app-server multi-limit response" do
    snapshot =
      ProviderQuota.normalize_codex(
        %{
          "rateLimitsByLimitId" => %{
            "codex" => %{
              "primary" => %{"usedPercent" => 96.0, "windowDurationMins" => 300, "resetsAt" => 1_234},
              "secondary" => %{"remaining" => 50, "limit" => 100}
            }
          }
        },
        now_ms: 2_000
      )

    assert snapshot.provider == :codex
    assert snapshot.buckets["codex.primary"].used_percent == 96.0
    assert snapshot.buckets["codex.primary"].window_minutes == 300
    assert snapshot.buckets["codex.secondary"].used_percent == 50.0
    assert ProviderQuota.active_quota_exhausted?(snapshot, 95, 2_100)
  end

  test "stale snapshots do not gate dispatch" do
    snapshot =
      ProviderQuota.normalize_codex(
        %{"limit_id" => "codex", "primary" => %{"usedPercent" => 100.0}},
        now_ms: 1_000,
        stale_after_ms: 100
      )

    refute ProviderQuota.active_quota_exhausted?(snapshot, 95, 1_101)
  end

  describe "error_snapshot/5 preserves the last successful fetch" do
    setup do
      good =
        ProviderQuota.normalize_claude(
          %{"five_hour" => %{"utilization" => 99.0}},
          now_ms: 1_000,
          stale_after_ms: 180_000
        )

      {:ok, good: good}
    end

    test "carries the prior buckets and fetch age, recording the error", %{good: good} do
      err =
        ProviderQuota.error_snapshot(:claude, :rate_limited, %{stale_after_ms: 180_000}, good, now: ~U[2026-06-24 10:00:00Z])

      # Age is tied to the last successful read (1_000), not the failed poll.
      assert err.fetched_at_ms == 1_000
      assert err.buckets == good.buckets
      assert err.error == %{code: "rate_limited"}
      assert err.error_since == "2026-06-24T10:00:00Z"
      assert err.last_attempt_at == "2026-06-24T10:00:00Z"
    end

    test "preserved age lets the snapshot go stale so dispatch stops gating", %{good: good} do
      err = ProviderQuota.error_snapshot(:claude, :rate_limited, %{stale_after_ms: 180_000}, good)

      # While fresh (49s after the last read), the carried 99% bucket still gates.
      refute ProviderQuota.stale?(err, 50_000)
      assert ProviderQuota.active_quota_exhausted?(err, 95, 50_000)

      # Past the window (relative to the original read at 1_000ms), it goes stale
      # and no longer pauses dispatch during the telemetry outage.
      assert ProviderQuota.stale?(err, 1_000 + 180_001)
      refute ProviderQuota.active_quota_exhausted?(err, 95, 1_000 + 180_001)
    end

    test "a failure streak keeps the original fetch age and error_since", %{good: good} do
      err1 =
        ProviderQuota.error_snapshot(:claude, :rate_limited, %{stale_after_ms: 180_000}, good, now: ~U[2026-06-24 10:00:00Z])

      err2 =
        ProviderQuota.error_snapshot(:claude, :rate_limited, %{stale_after_ms: 180_000}, err1, now: ~U[2026-06-24 10:05:00Z])

      assert err2.fetched_at_ms == 1_000
      # The streak's start is preserved even though the latest attempt is later.
      assert err2.error_since == "2026-06-24T10:00:00Z"
      assert err2.last_attempt_at == "2026-06-24T10:05:00Z"
    end

    test "with no prior success the snapshot reads as stale and empty" do
      err = ProviderQuota.error_snapshot(:claude, :timeout, %{}, nil, now: ~U[2026-06-24 10:00:00Z])

      assert err.buckets == %{}
      assert err.error == %{code: "timeout"}
      assert err.error_since == "2026-06-24T10:00:00Z"
      refute Map.has_key?(err, :fetched_at_ms)
      assert ProviderQuota.stale?(err, 999_999)
    end
  end
end
