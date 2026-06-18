defmodule LinearSimWeb.WebhookReplayTest do
  use LinearSimWeb.ConnCase, async: false

  alias LinearSim.Repo
  alias LinearSim.Linear.WebhookDelivery

  test "POST /admin/webhooks/replay records a clean failure for an offline target", %{conn: conn} do
    payload = %{
      "targetUrl" => "http://127.0.0.1:1/linear/webhook",
      "secret" => "test_webhook_secret",
      "event" => %{"type" => "Issue", "action" => "create", "issueId" => "issue_eng_1"}
    }

    conn = post(conn, "/admin/webhooks/replay", payload)
    body = json_response(conn, 502)

    assert body["ok"] == false
    assert body["delivery"]["status"] == "failed"
    # Raw body is not leaked back over the admin API.
    refute Map.has_key?(body["delivery"], "raw_body")

    # The attempt is recorded in the delivery log.
    assert Repo.aggregate(WebhookDelivery, :count) == 1
    delivery = Repo.one(WebhookDelivery)
    assert delivery.event_type == "Issue"
    assert delivery.action == "create"
    assert delivery.status == "failed"
    assert is_binary(delivery.signature)
  end

  test "POST /admin/webhooks/replay 400s without targetUrl/event", %{conn: conn} do
    conn = post(conn, "/admin/webhooks/replay", %{"foo" => "bar"})
    assert json_response(conn, 400)["ok"] == false
  end
end
