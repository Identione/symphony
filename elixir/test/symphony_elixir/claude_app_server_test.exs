defmodule SymphonyElixir.ClaudeAppServerTest do
  @moduledoc """
  Drives the Elixir-side Claude adapter against scripted bash subprocesses
  that emit JSON lines mimicking the Python sidecar. This keeps the test
  suite hermetic — no Python or claude-agent-sdk required.
  """

  use SymphonyElixir.TestSupport
  import ExUnit.CaptureLog
  alias SymphonyElixir.Claude.AppServer
  alias SymphonyElixir.Linear.Issue

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "claude-app-server-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "test", state: "Todo", description: nil}
  end

  defp scripted_command(lines) when is_list(lines) do
    body = Enum.map_join(lines, " ; ", fn line -> ~s(printf '%s\\n' #{escape(line)}) end)

    # Read and discard each line of input so the subprocess survives until
    # all expected stdin envelopes have arrived.
    "(#{body} ; while IFS= read -r _; do :; done)"
  end

  defp scripted_command_with_input(prelude, after_input) when is_list(prelude) and is_list(after_input) do
    prelude_body = Enum.map_join(prelude, " ; ", fn line -> ~s(printf '%s\\n' #{escape(line)}) end)
    post_body = Enum.map_join(after_input, " ; ", fn line -> ~s(printf '%s\\n' #{escape(line)}) end)

    "(#{prelude_body} ; IFS= read -r _line ; #{post_body} ; while IFS= read -r _; do :; done)"
  end

  # More flexible variant: caller supplies a list of `:print | :read` ops, plus
  # a final `:tail` that idles waiting for stdin so the subprocess survives
  # until Symphony tears it down.
  defp scripted_ops(ops) when is_list(ops) do
    body =
      Enum.map_join(ops, " ; ", fn
        {:print, line} -> ~s(printf '%s\\n' #{escape(line)})
        :read -> "IFS= read -r _line"
      end)

    "(#{body} ; while IFS= read -r _; do :; done)"
  end

  defp envelope(map), do: Jason.encode!(map)

  defp escape(str) do
    "'" <> String.replace(str, "'", ~s('"'"')) <> "'"
  end

  defp default_claude_config do
    %{
      command: "true",
      model: "claude-sonnet-4-6",
      permission_mode: "dontAsk",
      allowed_tools: ["Read"],
      disallowed_tools: [],
      system_prompt_preset: "claude_code",
      setting_sources: [],
      extra_env: %{},
      config_dir: nil,
      read_timeout_ms: 1_500
    }
  end

  test "start_session succeeds on `ready` alone (Claude SDK delivers system_init only during a turn)",
       %{workspace: workspace} do
    # Mirrors the real Python sidecar's behaviour: emit `ready` after the SDK
    # client's __aenter__ completes, then idle. system_init only arrives
    # later, inside a `turn`, when SDK delivers SystemMessage(subtype="init").
    cmd = scripted_command([envelope(%{type: "ready"})])

    assert {:ok, session} =
             AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    # No session_id yet — we'll learn it during the first turn.
    assert session.session_id == nil
    assert session.workspace == workspace

    AppServer.stop_session(session)
  end

  test "session_id is captured lazily from system_init during the first turn",
       %{workspace: workspace} do
    # The Claude SDK only emits SystemMessage(subtype="init") inside
    # `client.receive_response`, i.e. during a turn — never during init.
    # Symphony must capture it from the first turn's stream and surface it on
    # the turn result.
    cmd =
      scripted_command_with_input(
        [envelope(%{type: "ready"})],
        [
          envelope(%{type: "system_init", session_id: "sess-late-1"}),
          envelope(%{
            type: "turn_end",
            stop_reason: "end_turn",
            num_turns: 1,
            usage: %{
              input_tokens: 0,
              output_tokens: 0,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0
            }
          })
        ]
      )

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    # Init phase has not seen system_init yet.
    assert session.session_id == nil

    {:ok, result} =
      AppServer.run_turn(session, "Hello", issue(), turn_timeout_ms: 5_000)

    # First turn picked up the SDK-supplied session_id.
    assert result.session_id == "sess-late-1"

    AppServer.stop_session(session)
  end

  test "init envelope advertises tool_specs from Codex.DynamicTool to the sidecar",
       %{workspace: workspace} do
    # Stub sidecar consumes Symphony's init line, writes it to a known path,
    # then completes the handshake. After start_session returns, we re-read
    # the captured init envelope and assert the tool_specs flowed through.
    init_capture_path = Path.join(workspace, "captured-init.json")

    cmd =
      "(IFS= read -r init_line ; printf '%s' \"$init_line\" > " <>
        Path.absname(init_capture_path) <>
        " ; printf '%s\\n' '{\"type\":\"ready\"}' ; while IFS= read -r _; do :; done)"

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    assert {:ok, body} = File.read(init_capture_path)
    assert {:ok, init_payload} = Jason.decode(body)
    assert init_payload["type"] == "init"
    assert is_list(init_payload["tool_specs"])

    assert [%{"name" => "linear_graphql", "inputSchema" => schema} | _] =
             init_payload["tool_specs"]

    assert schema["required"] == ["query"]
    assert schema["properties"]["query"]["type"] == "string"
    assert schema["additionalProperties"] == false

    AppServer.stop_session(session)
  end

  test "start_session fails with response_timeout when sidecar never replies", %{workspace: workspace} do
    # Subprocess just blocks reading stdin without ever printing.
    cmd = "cat > /dev/null"

    config = %{default_claude_config() | command: cmd, read_timeout_ms: 100}

    assert {:error, :response_timeout} = AppServer.start_session(workspace, config: config)
  end

  test "start_session rejects a non-nil worker_host with a clear error", %{workspace: workspace} do
    # Codex's adapter routes remote workers through SSH.start_port; the Claude
    # sidecar is local-only for now (the sidecar's `uv run …` command points at
    # an absolute path on the orchestrator host). Until remote worker support
    # is implemented, fail loudly instead of silently spawning a local bash
    # against a workspace path that lives on a different host.
    cmd = "true"
    config = %{default_claude_config() | command: cmd}

    assert {:error, {:claude_remote_worker_unsupported, "alice@host"}} =
             AppServer.start_session(workspace, config: config, worker_host: "alice@host")
  end

  test "run_turn returns turn_end with usage when sidecar replies", %{workspace: workspace} do
    # Sidecar pre-scripts the full happy-path: ready, system_init, then a
    # turn_end keyed off whatever the test sends. In this lightweight stub,
    # the turn_end is simply printed after stdin receives one line.
    cmd =
      scripted_command_with_input(
        [
          envelope(%{type: "ready"}),
          envelope(%{type: "system_init", session_id: "s-run-1"})
        ],
        [
          envelope(%{type: "assistant_message", text: "hello"}),
          envelope(%{
            type: "turn_end",
            stop_reason: "end_turn",
            num_turns: 1,
            usage: %{
              input_tokens: 42,
              output_tokens: 7,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 1
            }
          })
        ]
      )

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    assert {:ok, result} =
             AppServer.run_turn(session, "Do the thing", issue(), turn_timeout_ms: 5_000)

    assert result.session_id == "s-run-1"
    assert result.stop_reason == "end_turn"
    assert result.num_turns == 1
    assert result.usage.input_tokens == 42
    assert result.usage.output_tokens == 7
    assert result.usage.cache_read_input_tokens == 1

    AppServer.stop_session(session)
  end

  test "run_turn forwards events via on_message callback", %{workspace: workspace} do
    cmd =
      scripted_command_with_input(
        [
          envelope(%{type: "ready"}),
          envelope(%{type: "system_init", session_id: "s-cb-1"})
        ],
        [
          envelope(%{type: "assistant_message", text: "step 1"}),
          envelope(%{type: "assistant_message", text: "step 2"}),
          envelope(%{
            type: "turn_end",
            stop_reason: "end_turn",
            num_turns: 1,
            usage: %{
              input_tokens: 1,
              output_tokens: 1,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0
            }
          })
        ]
      )

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    parent = self()
    on_message = fn msg -> send(parent, {:claude_event, msg}) end

    assert {:ok, _result} =
             AppServer.run_turn(session, "Go", issue(),
               on_message: on_message,
               turn_timeout_ms: 5_000
             )

    # We expect at least one assistant_message event plus the turn_completed.
    assert_received {:claude_event, %{event: :assistant_message}}
    assert_received {:claude_event, %{event: :turn_completed}}

    AppServer.stop_session(session)
  end

  test "run_turn forwards `log` envelopes via on_message with atomized payload",
       %{workspace: workspace} do
    # The sidecar forwards Anthropic CLI stderr (and its own warnings) as
    # `log` envelopes. They must reach Symphony's on_message callback so the
    # AgentRunner Logger handler can prefix them as `claude_cli: …`.
    cmd =
      scripted_command_with_input(
        [
          envelope(%{type: "ready"}),
          envelope(%{type: "system_init", session_id: "s-log-1"})
        ],
        [
          envelope(%{
            type: "log",
            level: "info",
            source: "claude_cli",
            message: "boot ok"
          }),
          envelope(%{
            type: "turn_end",
            stop_reason: "end_turn",
            num_turns: 1,
            usage: %{
              input_tokens: 0,
              output_tokens: 0,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0
            }
          })
        ]
      )

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    parent = self()
    on_message = fn msg -> send(parent, {:claude_event, msg}) end

    assert {:ok, _result} =
             AppServer.run_turn(session, "Go", issue(),
               on_message: on_message,
               turn_timeout_ms: 5_000
             )

    assert_received {:claude_event,
                     %{
                       event: :log,
                       payload: %{
                         level: "info",
                         source: "claude_cli",
                         message: "boot ok"
                       }
                     }}

    AppServer.stop_session(session)
  end

  describe "session lifecycle Logger lines (mirroring Codex)" do
    test "happy path emits `Claude session started` then `Claude session completed` with session_id and issue context",
         %{workspace: workspace} do
      cmd =
        scripted_command_with_input(
          [
            envelope(%{type: "ready"}),
            envelope(%{type: "system_init", session_id: "s-life-ok"})
          ],
          [
            envelope(%{
              type: "turn_end",
              stop_reason: "end_turn",
              num_turns: 1,
              usage: %{
                input_tokens: 0,
                output_tokens: 0,
                cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0
              }
            })
          ]
        )

      {:ok, session} =
        AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 5_000)
        end)

      assert log =~ "Claude session started for issue_id=issue-1 issue_identifier=MT-1"
      assert log =~ "Claude session completed for issue_id=issue-1 issue_identifier=MT-1 session_id=s-life-ok"

      AppServer.stop_session(session)
    end

    test "error envelope emits `Claude session ended with error` at warning level",
         %{workspace: workspace} do
      cmd =
        scripted_command_with_input(
          [
            envelope(%{type: "ready"}),
            envelope(%{type: "system_init", session_id: "s-life-err"})
          ],
          [envelope(%{type: "error", error: "kaboom", category: "claude_sdk_error"})]
        )

      {:ok, session} =
        AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

      log =
        capture_log(fn ->
          assert {:error, {:claude_sdk_error, :unknown, "kaboom"}} =
                   AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 5_000)
        end)

      assert log =~ "[warning]"
      assert log =~ "Claude session ended with error for issue_id=issue-1 issue_identifier=MT-1"
      assert log =~ "kaboom"

      AppServer.stop_session(session)
    end

    test "start_session port-spawn failure emits `Claude session failed` at error level",
         %{workspace: workspace} do
      log =
        capture_log(fn ->
          assert {:error, _} =
                   AppServer.start_session(workspace,
                     config: %{default_claude_config() | command: ""}
                   )
        end)

      assert log =~ "[error]"
      assert log =~ "Claude session failed (startup)"
      assert log =~ "claude_sidecar_not_found"
    end
  end

  test "run_turn translates `error` envelope into adapter error", %{workspace: workspace} do
    cmd =
      scripted_command_with_input(
        [
          envelope(%{type: "ready"}),
          envelope(%{type: "system_init", session_id: "s-err-1"})
        ],
        [envelope(%{type: "error", error: "boom", category: "claude_sdk_error"})]
      )

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    # No `error_code` on the envelope — adapter must default to `:unknown` so
    # downstream consumers always see an atom in the 2nd position.
    assert {:error, {:claude_sdk_error, :unknown, "boom"}} =
             AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 5_000)

    AppServer.stop_session(session)
  end

  describe "run_turn propagates structured error_code from sidecar (IDE-71)" do
    # One scripted error envelope per taxonomy code. The adapter must atomize
    # the whitelisted code through `Claude.Wire` and surface it as the 2nd
    # element of `{:claude_sdk_error, code, msg}`. Anything outside the
    # whitelist must collapse to `:unknown`.
    for {code_string, code_atom, message} <- [
          {"context_window_exhausted", :context_window_exhausted, "prompt is too long: 250000 tokens > 200000 maximum"},
          {"rate_limited", :rate_limited, "rate_limit_error: too many requests"},
          {"overloaded", :overloaded, "OverloadedError: 529"},
          {"quota_exceeded", :quota_exceeded, "credit balance is too low"},
          {"invalid_request", :invalid_request, "BadRequestError: malformed input"}
        ] do
      test "code=#{code_string} maps to #{inspect(code_atom)}", %{workspace: workspace} do
        cmd =
          scripted_command_with_input(
            [
              envelope(%{type: "ready"}),
              envelope(%{type: "system_init", session_id: "s-err-tax"})
            ],
            [
              envelope(%{
                type: "error",
                error: unquote(message),
                category: "claude_sdk_error",
                error_code: unquote(code_string)
              })
            ]
          )

        {:ok, session} =
          AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

        assert {:error, {:claude_sdk_error, unquote(code_atom), unquote(message)}} =
                 AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 5_000)

        AppServer.stop_session(session)
      end
    end

    test "unknown error_code value collapses to :unknown", %{workspace: workspace} do
      # `Claude.Wire` leaves out-of-whitelist values as binaries; the adapter
      # falls back to `:unknown` so the orchestrator never sees a raw string
      # in the structured position.
      cmd =
        scripted_command_with_input(
          [
            envelope(%{type: "ready"}),
            envelope(%{type: "system_init", session_id: "s-err-unk"})
          ],
          [
            envelope(%{
              type: "error",
              error: "mystery",
              category: "claude_sdk_error",
              error_code: "future_taxonomy_value"
            })
          ]
        )

      {:ok, session} =
        AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

      assert {:error, {:claude_sdk_error, :unknown, "mystery"}} =
               AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 5_000)

      AppServer.stop_session(session)
    end
  end

  test "run_turn fails with turn_timeout when no terminal envelope arrives", %{workspace: workspace} do
    cmd =
      scripted_command([
        envelope(%{type: "ready"}),
        envelope(%{type: "system_init", session_id: "s-to-1"})
      ])

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    assert {:error, :turn_timeout} =
             AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 200)

    AppServer.stop_session(session)
  end

  test "run_turn round-trips a tool_call to the configured tool_executor", %{workspace: workspace} do
    # Sequence after start_session returns:
    #   1. sidecar reads `turn` from stdin
    #   2. sidecar prints `tool_call`
    #   3. sidecar reads `tool_result` from stdin (Symphony's reply)
    #   4. sidecar prints `turn_end`
    cmd =
      scripted_ops([
        {:print, envelope(%{type: "ready"})},
        {:print, envelope(%{type: "system_init", session_id: "s-tool-1"})},
        :read,
        {:print,
         envelope(%{
           type: "tool_call",
           tool_use_id: "u-1",
           name: "linear_graphql",
           input: %{"query" => "query { viewer { id } }"}
         })},
        :read,
        {:print,
         envelope(%{
           type: "turn_end",
           stop_reason: "end_turn",
           num_turns: 1,
           usage: %{
             input_tokens: 1,
             output_tokens: 1,
             cache_creation_input_tokens: 0,
             cache_read_input_tokens: 0
           }
         })}
      ])

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    parent = self()

    tool_executor = fn name, input ->
      send(parent, {:tool_executor_called, name, input})
      %{"success" => true, "data" => "executor-stub-result"}
    end

    assert {:ok, _result} =
             AppServer.run_turn(session, "Go", issue(),
               tool_executor: tool_executor,
               turn_timeout_ms: 5_000
             )

    assert_received {:tool_executor_called, "linear_graphql", %{"query" => "query { viewer { id } }"}}

    AppServer.stop_session(session)
  end

  test "run_turn round-trips a permission_request to the configured permission_handler",
       %{workspace: workspace} do
    cmd =
      scripted_ops([
        {:print, envelope(%{type: "ready"})},
        {:print, envelope(%{type: "system_init", session_id: "s-perm-1"})},
        :read,
        {:print,
         envelope(%{
           type: "permission_request",
           permission_request_id: "p-1",
           request: %{"tool" => "Bash", "input" => %{"cmd" => "rm -rf /"}}
         })},
        :read,
        {:print,
         envelope(%{
           type: "turn_end",
           stop_reason: "end_turn",
           num_turns: 1,
           usage: %{
             input_tokens: 1,
             output_tokens: 1,
             cache_creation_input_tokens: 0,
             cache_read_input_tokens: 0
           }
         })}
      ])

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    parent = self()

    permission_handler = fn req ->
      send(parent, {:permission_handler_called, req})
      %{decision: "deny", reason: "no shell tools allowed"}
    end

    assert {:ok, _result} =
             AppServer.run_turn(session, "Go", issue(),
               permission_handler: permission_handler,
               turn_timeout_ms: 5_000
             )

    assert_received {:permission_handler_called,
                     %{
                       type: :permission_request,
                       permission_request_id: "p-1",
                       request: %{"tool" => "Bash"}
                     }}

    AppServer.stop_session(session)
  end

  # Helper: builds a sidecar stub that prints `ready`, then on the first turn
  # input prints a `system_init` whose session_id is the expansion of `var`
  # in the subprocess env, plus a turn_end so run_turn returns.
  defp env_echo_command(var) do
    turn_end_json =
      ~s({"type":"turn_end","stop_reason":"end_turn","num_turns":1,) <>
        ~s("usage":{"input_tokens":0,"output_tokens":0,) <>
        ~s("cache_creation_input_tokens":0,"cache_read_input_tokens":0}})

    [
      ~s|(printf '{"type":"ready"}\\n'|,
      "IFS= read -r _line",
      ~s|printf '{"type":"system_init","session_id":"%s"}\\n' "$#{var}"|,
      ~s|printf '%s\\n' '#{turn_end_json}'|,
      "while IFS= read -r _; do :; done)"
    ]
    |> Enum.join(" ; ")
  end

  test "sidecar inherits host env (so ANTHROPIC_API_KEY reaches it without explicit listing)",
       %{workspace: workspace} do
    sentinel = "SYMPHONY_CLAUDE_TEST_SENTINEL_#{System.unique_integer([:positive])}"
    sentinel_value = "claude-env-passthrough-ok"
    System.put_env(sentinel, sentinel_value)
    on_exit(fn -> System.delete_env(sentinel) end)

    {:ok, session} =
      AppServer.start_session(workspace,
        config: %{default_claude_config() | command: env_echo_command(sentinel)}
      )

    {:ok, result} = AppServer.run_turn(session, "go", issue(), turn_timeout_ms: 5_000)

    assert result.session_id == sentinel_value,
           "expected sidecar to see #{sentinel}=#{sentinel_value} from inherited env, got session_id=#{inspect(result.session_id)}"

    AppServer.stop_session(session)
  end

  test "agent.claude.config_dir is exposed to the sidecar as CLAUDE_CONFIG_DIR",
       %{workspace: workspace} do
    override_dir =
      Path.join(System.tmp_dir!(), "symphony-claude-cfg-#{System.unique_integer([:positive])}")

    File.mkdir_p!(override_dir)
    on_exit(fn -> File.rm_rf(override_dir) end)

    {:ok, session} =
      AppServer.start_session(workspace,
        config: %{
          default_claude_config()
          | command: env_echo_command("CLAUDE_CONFIG_DIR"),
            config_dir: override_dir
        }
      )

    {:ok, result} = AppServer.run_turn(session, "go", issue(), turn_timeout_ms: 5_000)

    assert result.session_id == Path.expand(override_dir)

    AppServer.stop_session(session)
  end

  test "sidecar receives SYMPHONY_CLAUDE_PRIV_DIR pointing at the claude_agent priv dir",
       %{workspace: workspace} do
    {:ok, session} =
      AppServer.start_session(workspace,
        config: %{
          default_claude_config()
          | command: env_echo_command("SYMPHONY_CLAUDE_PRIV_DIR")
        }
      )

    {:ok, result} = AppServer.run_turn(session, "go", issue(), turn_timeout_ms: 5_000)

    priv_dir = result.session_id

    assert is_binary(priv_dir) and priv_dir != ""

    assert Path.type(priv_dir) == :absolute,
           "SYMPHONY_CLAUDE_PRIV_DIR must be absolute so the default command works under cd: workspace"

    assert String.ends_with?(priv_dir, "claude_agent"),
           "expected path to point at the claude_agent priv subdir, got #{priv_dir}"

    assert File.dir?(priv_dir),
           "SYMPHONY_CLAUDE_PRIV_DIR must resolve to an existing directory, got #{priv_dir}"

    AppServer.stop_session(session)
  end

  test "extra_env can override SYMPHONY_CLAUDE_PRIV_DIR when explicitly supplied",
       %{workspace: workspace} do
    override = "/tmp/symphony-claude-priv-override-#{System.unique_integer([:positive])}"

    {:ok, session} =
      AppServer.start_session(workspace,
        config: %{
          default_claude_config()
          | command: env_echo_command("SYMPHONY_CLAUDE_PRIV_DIR"),
            extra_env: %{"SYMPHONY_CLAUDE_PRIV_DIR" => override}
        }
      )

    {:ok, result} = AppServer.run_turn(session, "go", issue(), turn_timeout_ms: 5_000)

    assert result.session_id == override

    AppServer.stop_session(session)
  end

  test "sidecar receives extra_env entries on top of inherited host env",
       %{workspace: workspace} do
    custom_var = "SYMPHONY_CLAUDE_EXTRA_ENV_#{System.unique_integer([:positive])}"
    custom_value = "from-extra-env"

    {:ok, session} =
      AppServer.start_session(workspace,
        config: %{
          default_claude_config()
          | command: env_echo_command(custom_var),
            extra_env: %{custom_var => custom_value}
        }
      )

    {:ok, result} = AppServer.run_turn(session, "go", issue(), turn_timeout_ms: 5_000)

    assert result.session_id == custom_value

    AppServer.stop_session(session)
  end

  test "default permission_handler denies any unhandled permission_request",
       %{workspace: workspace} do
    cmd =
      scripted_ops([
        {:print, envelope(%{type: "ready"})},
        {:print, envelope(%{type: "system_init", session_id: "s-deny-1"})},
        :read,
        {:print,
         envelope(%{
           type: "permission_request",
           permission_request_id: "p-2",
           request: %{"tool" => "WebFetch"}
         })},
        :read,
        {:print,
         envelope(%{
           type: "turn_end",
           stop_reason: "end_turn",
           num_turns: 1,
           usage: %{
             input_tokens: 1,
             output_tokens: 1,
             cache_creation_input_tokens: 0,
             cache_read_input_tokens: 0
           }
         })}
      ])

    {:ok, session} =
      AppServer.start_session(workspace, config: %{default_claude_config() | command: cmd})

    # No permission_handler supplied — Symphony should default to deny rather
    # than crash or stall (matches the dontAsk policy posture in SPEC §10.8).
    assert {:ok, _result} =
             AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 5_000)

    AppServer.stop_session(session)
  end
end
