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
end
