defmodule LinearSim.WebhooksTest do
  use LinearSim.DataCase, async: false

  alias LinearSim.Webhooks.{Delivery, Signer}

  describe "Signer.sign_body!/2" do
    test "is a stable lowercase hex HMAC-SHA256 of the exact body" do
      sig = Signer.sign_body!(~s({"a":1}), "secret")
      assert sig == String.downcase(sig)
      assert String.match?(sig, ~r/\A[0-9a-f]{64}\z/)
      # Deterministic for the same body+secret.
      assert sig == Signer.sign_body!(~s({"a":1}), "secret")
      # Sensitive to body changes.
      refute sig == Signer.sign_body!(~s({"a":2}), "secret")
    end
  end

  describe "Delivery.deliver/4" do
    test "signs the exact body that the target receives" do
      test_pid = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        sig = Plug.Conn.get_req_header(conn, "linear-signature") |> List.first()
        send(test_pid, {:received, body, sig})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"ok":true}))
      end

      payload = %{"type" => "Issue", "action" => "create", "issueId" => "issue_eng_1"}

      assert {:ok, delivery} =
               Delivery.deliver("http://target.test/webhook", "shh", payload, plug: plug)

      assert delivery.status == :delivered
      assert delivery.response_status == 200

      assert_received {:received, received_body, received_sig}
      # The exact signed binary is what the target got, and the signature matches it.
      assert received_body == delivery.raw_body
      assert received_sig == Signer.sign_body!(received_body, "shh")
    end

    test "returns a clean failure when the target is unreachable" do
      # Port 1 on loopback refuses immediately — exercises the failure path
      # without a real remote target.
      assert {:error, delivery} =
               Delivery.deliver("http://127.0.0.1:1/webhook", "shh", %{"a" => 1})

      assert delivery.status == :failed
      assert is_binary(delivery.reason)
    end
  end
end
