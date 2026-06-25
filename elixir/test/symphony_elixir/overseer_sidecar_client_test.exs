defmodule SymphonyElixir.Overseer.SidecarClientTest do
  @moduledoc """
  Coverage for engine (b) of the Layer 2 overseer (IDE-230 Path B): the
  Claude-sidecar classification path. A stub adapter (injected via the
  `:overseer_sidecar_adapter` seam) stands in for `Claude.AppServer`, so the
  locked-down session config, the assistant-text → JSON extraction, and every
  fail-open error path are exercised without spawning the Python sidecar.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig
  alias SymphonyElixir.Overseer
  alias SymphonyElixir.Overseer.SidecarClient

  # Stub `Claude.AppServer`. Reads its scripted behavior from the
  # `:sidecar_stub` app env and echoes the cwd + resolved session config back to
  # the test process so the locked-down shape can be asserted.
  defmodule StubAdapter do
    def start_session(cwd, opts) do
      stub = Application.get_env(:symphony_elixir, :sidecar_stub, %{})
      send(self(), {:sidecar_start, cwd, Keyword.get(opts, :config)})

      case Map.get(stub, :mode) do
        :start_error -> {:error, :boom}
        _ -> {:ok, %{stub: true}}
      end
    end

    def run_turn(_session, prompt, _issue, opts) do
      stub = Application.get_env(:symphony_elixir, :sidecar_stub, %{})
      send(self(), {:sidecar_prompt, prompt})

      case Map.get(stub, :mode) do
        :turn_error ->
          {:error, {:claude_sdk_error, :invalid_request, "401"}}

        _ ->
          on_message = Keyword.fetch!(opts, :on_message)
          emit_chunks(on_message, Map.get(stub, :text, ""))
          {:ok, %{session_id: "sess-stub", stop_reason: "end_turn"}}
      end
    end

    def stop_session(_session), do: :ok

    defp emit_chunks(_on_message, text) when text in [nil, ""], do: :ok

    defp emit_chunks(on_message, text) when is_binary(text) do
      on_message.(%{event: :assistant_message, payload: %{text: text}})
    end

    defp emit_chunks(on_message, chunks) when is_list(chunks) do
      Enum.each(chunks, fn chunk ->
        on_message.(%{event: :assistant_message, payload: %{text: chunk}})
      end)
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :overseer_sidecar_adapter, StubAdapter)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :overseer_sidecar_adapter)
      Application.delete_env(:symphony_elixir, :sidecar_stub)
    end)

    :ok
  end

  defp config(overrides \\ %{}) do
    struct(%OverseerConfig{model: "claude-sonnet-4-6", timeout_ms: 5_000}, overrides)
  end

  defp messages, do: %{system: "SYS", user: "USR"}

  defp put_stub(stub), do: Application.put_env(:symphony_elixir, :sidecar_stub, stub)

  @valid_json ~s({"verdict":"converging","confidence":0.9,"recommended_action":"continue","steering_message":null,"findings":null,"rationale":"progressing"})

  describe "classify/3 — happy path" do
    test "returns the raw verdict map from a bare-JSON response" do
      put_stub(%{mode: :ok, text: @valid_json})

      assert {:ok, raw} = SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
      assert raw["verdict"] == "converging"
      assert raw["recommended_action"] == "continue"
    end

    test "tolerates a ```json fenced response" do
      put_stub(%{mode: :ok, text: "```json\n#{@valid_json}\n```"})

      assert {:ok, raw} = SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
      assert raw["verdict"] == "converging"
    end

    test "tolerates prose wrapped around the JSON object (brace-scan fallback)" do
      put_stub(%{mode: :ok, text: "Here is my verdict:\n#{@valid_json}\nThanks!"})

      assert {:ok, raw} = SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
      assert raw["confidence"] == 0.9
    end

    test "does not close the object early on a brace inside a string value" do
      json = ~s({"verdict":"blocked","confidence":0.7,"recommended_action":"escalate","steering_message":null,"findings":null,"rationale":"saw a literal } brace in a message"})
      put_stub(%{mode: :ok, text: "noise " <> json <> " trailing"})

      assert {:ok, raw} = SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
      assert raw["verdict"] == "blocked"
      assert raw["rationale"] =~ "literal } brace"
    end

    test "joins multiple assistant_message chunks before extracting" do
      put_stub(%{mode: :ok, text: ["{\"verdict\":\"converging\",", "\"confidence\":0.9,\"recommended_action\":\"continue\",\"steering_message\":null,\"findings\":null,\"rationale\":\"ok\"}"]})

      assert {:ok, raw} = SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
      assert raw["verdict"] == "converging"
    end
  end

  describe "classify/3 — locked-down session" do
    test "launches an isolated, tool-less, single-turn session with the overseer model" do
      put_stub(%{mode: :ok, text: @valid_json})

      SidecarClient.classify(messages(), config(%{model: "claude-sonnet-4-6", timeout_ms: 1_234}), cwd: "/tmp/ws")

      assert_received {:sidecar_start, "/tmp/ws", cfg}
      assert cfg.allowed_tools == []
      assert cfg.setting_sources == []
      assert cfg.max_turns == 2
      assert cfg.max_budget_usd == nil
      assert cfg.model == "claude-sonnet-4-6"
      assert cfg.read_timeout_ms == 1_234
    end

    test "folds the system and user messages into the single turn prompt" do
      put_stub(%{mode: :ok, text: @valid_json})

      SidecarClient.classify(%{system: "SYSTEM-MARK", user: "USER-MARK"}, config(), cwd: "/tmp/ws")

      assert_received {:sidecar_prompt, prompt}
      assert prompt =~ "SYSTEM-MARK"
      assert prompt =~ "USER-MARK"
    end
  end

  describe "classify/3 — fail-open paths" do
    test "errors without a cwd before touching the adapter" do
      assert {:error, :overseer_sidecar_no_cwd} = SidecarClient.classify(messages(), config(), [])
      refute_received {:sidecar_start, _, _}
    end

    test "wraps a session start failure" do
      put_stub(%{mode: :start_error})
      assert {:error, {:overseer_sidecar_start_failed, :boom}} = SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
    end

    test "wraps a turn failure (e.g. an OAuth 401 surfaced by the sidecar)" do
      put_stub(%{mode: :turn_error})

      assert {:error, {:overseer_sidecar_turn_failed, {:claude_sdk_error, :invalid_request, "401"}}} =
               SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
    end

    test "fails open on an unparseable response" do
      put_stub(%{mode: :ok, text: "I cannot produce a verdict right now."})
      assert {:error, :overseer_sidecar_unparseable_verdict} = SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
    end

    test "fails open on an empty response" do
      put_stub(%{mode: :ok, text: ""})
      assert {:error, _} = SidecarClient.classify(messages(), config(), cwd: "/tmp/ws")
    end
  end

  describe "Overseer.run/3 dispatch to the sidecar engine" do
    test "builds JSON-mode evidence, threads cwd, and parses the verdict" do
      put_stub(%{mode: :ok, text: @valid_json})

      assert {:ok, %{verdict: :converging, recommended_action: :continue}} =
               Overseer.run(%{issue_title: "Ship"}, config(%{engine: "sidecar"}), cwd: "/tmp/ws")

      # The sidecar prompt carries the JSON-mode closing instruction, not the
      # forced-tool one.
      assert_received {:sidecar_prompt, prompt}
      assert prompt =~ "Respond with ONLY a single JSON object"
      refute prompt =~ "emit_verdict tool exactly once"
    end

    test "a missing cwd fails open to no judgement" do
      put_stub(%{mode: :ok, text: @valid_json})
      assert {:error, :overseer_sidecar_no_cwd} = Overseer.run(%{}, config(%{engine: "sidecar"}))
    end
  end
end
