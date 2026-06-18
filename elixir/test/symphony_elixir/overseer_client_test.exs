defmodule SymphonyElixir.Overseer.ClientTest do
  @moduledoc """
  HTTP-path coverage for the Layer 2 overseer engine (IDE-212). A tiny local
  Plug router (served by Bandit on an OS-assigned port) stands in for the
  Anthropic Messages API via the `:overseer_api_base_url` test seam, so the
  forced-tool request shape and every fail-open error path are exercised without
  a live endpoint.
  """
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig
  alias SymphonyElixir.Overseer.Client

  defmodule StubRouter do
    use Plug.Router

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    post "/v1/messages" do
      {test_pid, mode} = Application.get_env(:symphony_elixir, :overseer_test_stub)
      send(test_pid, {:overseer_request, conn.body_params})
      respond(conn, mode)
    end

    defp respond(conn, :ok) do
      body = %{
        "content" => [
          %{
            "type" => "tool_use",
            "name" => "emit_verdict",
            "input" => %{
              "verdict" => "converging",
              "confidence" => 0.9,
              "recommended_action" => "continue",
              "steering_message" => nil,
              "rationale" => "ok"
            }
          }
        ]
      }

      json(conn, 200, body)
    end

    defp respond(conn, :no_tool) do
      json(conn, 200, %{"content" => [%{"type" => "text", "text" => "hi"}]})
    end

    defp respond(conn, :http_error) do
      json(conn, 429, %{"error" => "rate_limited"})
    end

    defp json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  setup context do
    mode = Map.get(context, :mode, :ok)
    Application.put_env(:symphony_elixir, :overseer_test_stub, {self(), mode})

    {:ok, server} = start_supervised({Bandit, plug: StubRouter, port: 0})
    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:symphony_elixir, :overseer_api_base_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :overseer_api_base_url)
      Application.delete_env(:symphony_elixir, :overseer_test_stub)
    end)

    :ok
  end

  defp config do
    %OverseerConfig{model: "claude-sonnet-4-6", api_key: "test-key", timeout_ms: 5_000}
  end

  defp messages, do: %{system: "sys", user: "usr"}

  test "classify/2 returns the raw verdict input on a 200 tool_use response" do
    assert {:ok, input} = Client.classify(messages(), config())
    assert input["verdict"] == "converging"
    assert input["recommended_action"] == "continue"
  end

  test "forces the emit_verdict tool and sends the system+user content" do
    Client.classify(messages(), config())
    assert_receive {:overseer_request, body}
    assert body["system"] == "sys"
    assert [%{"role" => "user", "content" => "usr"}] = body["messages"]
    assert body["tool_choice"]["name"] == "emit_verdict"
    assert [%{"name" => "emit_verdict"}] = body["tools"]
  end

  @tag mode: :no_tool
  test "fails open when the response carries no tool_use block" do
    assert {:error, :overseer_no_tool_use} = Client.classify(messages(), config())
  end

  @tag mode: :http_error
  test "fails open on a non-200 status" do
    assert {:error, {:overseer_http_error, 429, _}} = Client.classify(messages(), config())
  end

  test "fails open on a transport error (unroutable base url)" do
    Application.put_env(:symphony_elixir, :overseer_api_base_url, "http://127.0.0.1:1")
    assert {:error, {:overseer_transport_error, _}} = Client.classify(messages(), config())
  end

  test "the schema is read-only (only emit_verdict, required verdict fields)" do
    schema = Client.verdict_tool_schema()
    assert schema["additionalProperties"] == false

    assert Enum.sort(schema["required"]) ==
             Enum.sort(["verdict", "confidence", "recommended_action", "steering_message", "rationale"])
  end

  test "exposes an optional findings object (IDE-230) that is not required" do
    schema = Client.verdict_tool_schema()
    findings = schema["properties"]["findings"]

    assert findings["type"] == ["object", "null"]
    assert Map.has_key?(findings["properties"], "summary")
    assert Map.has_key?(findings["properties"], "blockers")
    assert Map.has_key?(findings["properties"], "next_steps_for_human")
    # findings stays optional — the give-up triage brief is best-effort.
    refute "findings" in schema["required"]
  end
end
