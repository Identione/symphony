defmodule SymphonyElixir.AgentRunnerHandlerTest do
  @moduledoc """
  Asserts the shape of the per-event Logger lines `AgentRunner` produces for
  the Claude adapter, and that the Codex adapter remains log-line-free
  (regression guard against accidentally enabling Claude logging for Codex).
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue

  defp issue do
    %Issue{id: "issue-1", identifier: "ENT-42", title: "x", state: "Todo", description: nil}
  end

  defp event(type, payload, session_id \\ "sess-x") do
    %{
      event: type,
      session_id: session_id,
      agent_kind: :claude,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  defp run_handler(adapter, event, opts \\ [verbose_logging: true]) do
    handler = AgentRunner.compose_message_handler(adapter, self(), issue(), opts)
    handler.(event)
  end

  describe "compose_message_handler/4 for the Claude adapter (verbose_logging=true)" do
    test "logs `tool_call` with name + folded input + issue + session context" do
      event =
        event(:tool_call, %{
          name: "Read",
          tool_use_id: "tu1",
          input: %{"file_path" => "/x/y.txt"}
        })

      log =
        capture_log(fn -> run_handler(SymphonyElixir.Claude.AppServer, event) end)

      assert log =~ "claude tool_call"
      assert log =~ "issue_id=issue-1"
      assert log =~ "issue_identifier=ENT-42"
      assert log =~ "session_id=sess-x"
      assert log =~ "name=Read"
      assert log =~ "/x/y.txt"
    end

    test "logs `assistant_message` with text body" do
      event = event(:assistant_message, %{text: "Looking at the file, I see…"})

      log =
        capture_log(fn -> run_handler(SymphonyElixir.Claude.AppServer, event) end)

      assert log =~ "claude assistant_message"
      assert log =~ "issue_identifier=ENT-42"
      assert log =~ "Looking at the file"
    end

    test "logs `turn_completed` with stop_reason + usage breakdown" do
      event =
        event(:turn_completed, %{
          stop_reason: "end_turn",
          num_turns: 2,
          usage: %{
            input_tokens: 1234,
            output_tokens: 567,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 8
          }
        })

      log =
        capture_log(fn -> run_handler(SymphonyElixir.Claude.AppServer, event) end)

      assert log =~ "claude turn_completed"
      assert log =~ "stop_reason=end_turn"
      assert log =~ "num_turns=2"
      assert log =~ "usage.input_tokens=1234"
      assert log =~ "usage.output_tokens=567"
    end

    test "logs `permission_request` with folded request body" do
      event =
        event(:permission_request, %{
          permission_request_id: "p1",
          request: %{"tool" => "Bash", "input" => %{"cmd" => "rm -rf /"}}
        })

      log =
        capture_log(fn -> run_handler(SymphonyElixir.Claude.AppServer, event) end)

      assert log =~ "claude permission_request"
      assert log =~ "Bash"
    end

    test "logs `:log` envelopes with the source prefix" do
      event =
        event(:log, %{level: "info", source: "claude_cli", message: "boot ok"})

      log =
        capture_log(fn -> run_handler(SymphonyElixir.Claude.AppServer, event) end)

      assert log =~ "claude_cli: boot ok"
    end

    test "drops session_id from the line when nil" do
      event = event(:assistant_message, %{text: "hi"}, nil)

      log =
        capture_log(fn -> run_handler(SymphonyElixir.Claude.AppServer, event) end)

      refute log =~ "session_id="
      assert log =~ "issue_identifier=ENT-42"
    end

    test "caps very long values with `…(N more chars)` suffix" do
      huge = String.duplicate("x", 5_000)
      event = event(:assistant_message, %{text: huge})

      log =
        capture_log(fn -> run_handler(SymphonyElixir.Claude.AppServer, event) end)

      assert log =~ "more chars"
    end

    test "still send/2's events to the recipient (so the dashboard works)" do
      parent = self()

      handler =
        AgentRunner.compose_message_handler(
          SymphonyElixir.Claude.AppServer,
          parent,
          issue(),
          verbose_logging: true
        )

      ev = event(:assistant_message, %{text: "hi"})
      capture_log(fn -> handler.(ev) end)

      assert_received {:codex_worker_update, "issue-1", _msg}
    end
  end

  describe "compose_message_handler/4 for the Claude adapter (verbose_logging=false)" do
    # Quiet mode is the default and the documented "noticeably less Claude
    # noise" posture (IDE-62). The handler must skip every per-envelope log
    # line — including forwarded `claude_cli` stderr — while still
    # forwarding events to the dashboard recipient.

    for type <- [:tool_call, :assistant_message, :turn_completed, :permission_request, :system_init, :log] do
      @tag claude_event: type
      test "drops `#{type}` log line when verbose_logging is off", %{claude_event: type} do
        payload =
          case type do
            :tool_call -> %{name: "Read", input: %{"path" => "/x"}}
            :assistant_message -> %{text: "hello"}
            :turn_completed -> %{stop_reason: "end_turn", num_turns: 1, usage: %{input_tokens: 1, output_tokens: 2}}
            :permission_request -> %{request: %{"tool" => "Bash"}}
            :system_init -> %{}
            :log -> %{level: "info", source: "claude_cli", message: "boot ok"}
          end

        log =
          capture_log(fn ->
            run_handler(SymphonyElixir.Claude.AppServer, event(type, payload), verbose_logging: false)
          end)

        assert log == "",
               "expected no log lines for #{inspect(type)} when verbose_logging=false, got: #{log}"
      end
    end

    test "still send/2's events to the recipient when quiet" do
      parent = self()

      handler =
        AgentRunner.compose_message_handler(
          SymphonyElixir.Claude.AppServer,
          parent,
          issue(),
          verbose_logging: false
        )

      capture_log(fn -> handler.(event(:tool_call, %{name: "Read", input: %{}})) end)

      assert_received {:codex_worker_update, "issue-1", _msg}
    end

    test "default opts (no `:verbose_logging` key) behave as quiet mode" do
      log =
        capture_log(fn ->
          handler =
            AgentRunner.compose_message_handler(SymphonyElixir.Claude.AppServer, self(), issue())

          handler.(event(:tool_call, %{name: "Read", input: %{}}))
        end)

      assert log == "", "expected default-quiet handler to emit no log lines, got: #{log}"
      assert_received {:codex_worker_update, "issue-1", _msg}
    end
  end

  describe "compose_message_handler/4 for non-Claude adapters" do
    test "Codex adapter produces no log lines (regression guard)" do
      event = event(:tool_call, %{name: "shell", input: %{"cmd" => "ls"}})

      log =
        capture_log(fn -> run_handler(SymphonyElixir.Codex.AppServer, event) end)

      assert log == "", "expected no log lines for the Codex adapter, got: #{log}"
    end

    test "Codex adapter still send/2's events to the recipient" do
      parent = self()
      handler = AgentRunner.compose_message_handler(SymphonyElixir.Codex.AppServer, parent, issue())
      handler.(%{event: :anything, agent_kind: :codex, payload: %{}, timestamp: DateTime.utc_now()})

      assert_received {:codex_worker_update, "issue-1", _msg}
    end
  end
end
