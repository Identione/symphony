defmodule SymphonyElixirWeb.PresenterProviderQuotaTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProviderQuota
  alias SymphonyElixirWeb.Presenter

  defp future_iso(seconds) do
    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp codex_snapshot(opts) do
    ProviderQuota.normalize_codex(
      %{
        "rateLimitsByLimitId" => %{
          "codex" => %{
            "primary" => %{"usedPercent" => 72.53, "resetsAt" => future_iso(3_600)},
            "secondary" => %{"usedPercent" => 96.0, "resetsAt" => future_iso(90_000)}
          }
        }
      },
      opts
    )
  end

  defp claude_snapshot(opts) do
    ProviderQuota.normalize_claude(
      %{
        "five_hour" => %{"utilization" => 30.0, "resets_at" => future_iso(600)},
        "seven_day_opus" => %{"utilization" => 88.0}
      },
      opts
    )
  end

  test "projects each provider snapshot into a render-ready card" do
    quotas = %{codex: codex_snapshot([]), claude: claude_snapshot([])}

    [codex_card, claude_card] = Presenter.provider_quota_cards(quotas)

    assert codex_card.provider == :codex
    assert claude_card.provider == :claude
    assert codex_card.source == "codex_app_server"
    refute codex_card.stale
    assert is_number(codex_card.threshold)
  end

  test "buckets carry rounded percent, labels, banding, and relative resets" do
    quotas = %{codex: codex_snapshot([])}
    [card] = Presenter.provider_quota_cards(quotas)

    # sorted by name => codex.primary then codex.secondary
    [primary, secondary] = card.buckets

    assert primary.label == "Primary"
    assert secondary.label == "Secondary"
    assert primary.used_percent == 72.5
    assert secondary.used_percent == 96.0

    # default threshold is 95.0 => primary ok, secondary danger
    assert primary.level == :ok
    refute primary.over_threshold
    assert secondary.level == :danger
    assert secondary.over_threshold

    assert String.starts_with?(primary.resets_in, "in ")
  end

  test "claude bucket keys are humanized" do
    quotas = %{claude: claude_snapshot([])}
    [card] = Presenter.provider_quota_cards(quotas)

    labels = Enum.map(card.buckets, & &1.label)
    assert "5h" in labels
    assert "Weekly · Opus" in labels
  end

  test "stale snapshots are flagged" do
    # fetched far in the (monotonic) past => stale relative to the configured window
    stale =
      codex_snapshot([])
      |> Map.put(:fetched_at_ms, System.monotonic_time(:millisecond) - 10_000_000)
      |> Map.put(:stale_after_ms, 1_000)

    [card] = Presenter.provider_quota_cards(%{codex: stale})

    assert card.stale
  end

  test "error snapshots surface the error and report no buckets" do
    snapshot = ProviderQuota.error_snapshot(:claude, :timeout, %{})
    [card] = Presenter.provider_quota_cards(%{claude: snapshot})

    assert card.error == %{code: "timeout"}
    assert card.buckets == []
  end

  test "missing or empty provider_quotas yields no cards" do
    assert Presenter.provider_quota_cards(%{}) == []
    assert Presenter.provider_quota_cards(%{codex: nil, claude: nil}) == []
    assert Presenter.provider_quota_cards(nil) == []
  end
end
