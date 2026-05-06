defmodule SymphonyElixir.ClaudeWireTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.Wire

  describe "encode/1" do
    test "encodes Symphony->sidecar init request as a single JSON line" do
      assert {:ok, line} =
               Wire.encode(%{
                 type: "init",
                 session_id: "abc",
                 cwd: "/tmp/ws",
                 model: "claude-sonnet-4-6",
                 permission_mode: "dontAsk",
                 allowed_tools: ["Read", "Edit"],
                 disallowed_tools: ["Bash"],
                 system_prompt: "You are a coding agent.",
                 setting_sources: [],
                 max_turns: 20,
                 extra_env: %{}
               })

      assert String.ends_with?(line, "\n")
      assert {:ok, decoded} = Jason.decode(String.trim_trailing(line, "\n"))
      assert decoded["type"] == "init"
      assert decoded["cwd"] == "/tmp/ws"
      assert decoded["allowed_tools"] == ["Read", "Edit"]
    end

    test "encodes turn request" do
      assert {:ok, line} = Wire.encode(%{type: "turn", turn_id: "t1", prompt: "Do the thing"})

      assert {:ok, %{"type" => "turn", "turn_id" => "t1", "prompt" => "Do the thing"}} =
               Jason.decode(String.trim_trailing(line, "\n"))
    end

    test "encodes interrupt and shutdown" do
      assert {:ok, interrupt} = Wire.encode(%{type: "interrupt"})
      assert {:ok, %{"type" => "interrupt"}} = Jason.decode(String.trim_trailing(interrupt, "\n"))

      assert {:ok, shutdown} = Wire.encode(%{type: "shutdown"})
      assert {:ok, %{"type" => "shutdown"}} = Jason.decode(String.trim_trailing(shutdown, "\n"))
    end
  end

  describe "decode/1" do
    test "decodes a `system_init` line and exposes session_id" do
      raw = ~s({"type":"system_init","session_id":"f6e7c1d2-..."}\n)
      assert {:ok, %{type: :system_init, session_id: "f6e7c1d2-..."}} = Wire.decode(raw)
    end

    test "decodes a `ready` line" do
      assert {:ok, %{type: :ready}} = Wire.decode(~s({"type":"ready"}\n))
    end

    test "decodes an `assistant_message` line preserving body" do
      raw = ~s({"type":"assistant_message","text":"hi","session_id":"s1"}\n)
      assert {:ok, %{type: :assistant_message, text: "hi", session_id: "s1"}} = Wire.decode(raw)
    end

    test "decodes a `tool_call` line" do
      raw = ~s({"type":"tool_call","tool_use_id":"u1","name":"Read","input":{"path":"x"}}\n)

      assert {:ok,
              %{
                type: :tool_call,
                tool_use_id: "u1",
                name: "Read",
                input: %{"path" => "x"}
              }} = Wire.decode(raw)
    end

    test "decodes a `turn_end` line with usage" do
      raw =
        ~s({"type":"turn_end","stop_reason":"end_turn","num_turns":2,) <>
          ~s("usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}\n)

      assert {:ok,
              %{
                type: :turn_end,
                stop_reason: "end_turn",
                num_turns: 2,
                usage: %{
                  input_tokens: 10,
                  output_tokens: 5,
                  cache_creation_input_tokens: 0,
                  cache_read_input_tokens: 0
                }
              }} = Wire.decode(raw)
    end

    test "decodes an `error` line" do
      raw = ~s({"type":"error","error":"boom","category":"claude_sdk_error"}\n)

      assert {:ok, %{type: :error, error: "boom", category: "claude_sdk_error"}} =
               Wire.decode(raw)
    end

    test "rejects unknown type with structured error" do
      raw = ~s({"type":"mystery"}\n)
      assert {:error, {:unknown_envelope, "mystery"}} = Wire.decode(raw)
    end

    test "rejects malformed JSON" do
      assert {:error, {:malformed_json, _}} = Wire.decode("not json\n")
    end
  end

  describe "split_lines/1" do
    test "splits a buffer into complete lines and a remaining tail" do
      assert Wire.split_lines("a\nb\nc") == {["a", "b"], "c"}
    end

    test "returns no lines when the buffer ends mid-line" do
      assert Wire.split_lines("abc") == {[], "abc"}
    end

    test "handles empty buffer" do
      assert Wire.split_lines("") == {[], ""}
    end

    test "preserves windows-style CRLF endings as part of lines" do
      assert Wire.split_lines("hello\r\nworld\n") == {["hello\r", "world"], ""}
    end
  end

  describe "encode/1 error paths" do
    test "rejects a map without a :type field" do
      assert {:error, :missing_type_field} = Wire.encode(%{foo: "bar"})
    end

    test "stringifies nested keys (atoms become strings) before JSON encoding" do
      assert {:ok, line} =
               Wire.encode(%{type: "init", nested: %{inner_atom: 1, list: [%{a: :b}]}})

      assert {:ok, decoded} = Jason.decode(String.trim_trailing(line, "\n"))
      assert decoded["nested"]["inner_atom"] == 1
      assert decoded["nested"]["list"] == [%{"a" => "b"}]
    end

    test "preserves string keys in nested maps without re-stringifying" do
      assert {:ok, line} = Wire.encode(%{:type => "init", "string_key" => "value"})
      assert {:ok, %{"string_key" => "value"}} = Jason.decode(String.trim_trailing(line, "\n"))
    end

    test "returns json_encode_error when payload contains an unencodable value" do
      # PIDs are not JSON-encodable.
      assert {:error, {:json_encode_error, _}} = Wire.encode(%{type: "init", pid: self()})
    end
  end

  describe "decode/1 edge cases" do
    test "rejects a JSON object missing the type field" do
      assert {:error, :missing_type_field} = Wire.decode(~s({"hello":"world"}\n))
    end

    test "decodes a `permission_request` envelope" do
      raw =
        ~s({"type":"permission_request","permission_request_id":"r1",) <>
          ~s("request":{"tool":"Bash"}}\n)

      assert {:ok,
              %{
                type: :permission_request,
                permission_request_id: "r1",
                request: %{"tool" => "Bash"}
              }} = Wire.decode(raw)
    end

    test "decodes a `log` envelope and preserves message body" do
      raw = ~s({"type":"log","level":"warning","message":"slow tool"}\n)
      assert {:ok, %{type: :log, level: "warning", message: "slow tool"}} = Wire.decode(raw)
    end

    test "decodes a `log` envelope with `source` field as an atom key" do
      # Sidecar tags stderr captured from the Anthropic CLI with
      # `"source":"claude_cli"` so the Symphony-side handler can prefix log
      # lines (e.g. `claude_cli: <line>`). Atomising the key lets the handler
      # pattern-match on `payload[:source]` instead of `payload["source"]`.
      raw =
        ~s({"type":"log","level":"info","source":"claude_cli","message":"boot ok"}\n)

      assert {:ok,
              %{
                type: :log,
                level: "info",
                source: "claude_cli",
                message: "boot ok"
              }} = Wire.decode(raw)
    end

    test "decodes an `assistant_delta` envelope" do
      raw = ~s({"type":"assistant_delta","text":"partial"}\n)
      assert {:ok, %{type: :assistant_delta, text: "partial"}} = Wire.decode(raw)
    end

    test "decodes a `token_usage` envelope with snake_case usage keys" do
      raw =
        ~s({"type":"token_usage","usage":) <>
          ~s({"input_tokens":3,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}\n)

      assert {:ok,
              %{
                type: :token_usage,
                usage: %{input_tokens: 3, output_tokens: 2}
              }} = Wire.decode(raw)
    end
  end
end
