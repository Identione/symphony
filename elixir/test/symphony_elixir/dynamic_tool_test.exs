defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Workpad

  test "tool_specs advertises the linear_graphql and sync_workpad input contracts" do
    specs = DynamicTool.tool_specs()
    names = Enum.map(specs, & &1["name"])

    assert "linear_graphql" in names
    assert "sync_workpad" in names

    linear_spec = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert %{
             "description" => linear_description,
             "inputSchema" => %{
               "properties" => %{
                 "query" => _,
                 "variables" => _
               },
               "required" => ["query"],
               "type" => "object"
             }
           } = linear_spec

    assert linear_description =~ "Linear"

    workpad_spec = Enum.find(specs, &(&1["name"] == "sync_workpad"))

    # `file_path` is intentionally NOT schema-required: the model reliably
    # guesses `workpad_path` on the first call, and a schema-level rejection
    # burns a round-trip. The executor enforces one of the two being present.
    assert %{
             "description" => workpad_description,
             "inputSchema" => %{
               "properties" => %{
                 "issue_id" => _,
                 "file_path" => _,
                 "workpad_path" => _,
                 "comment_id" => _
               },
               "required" => ["issue_id"],
               "type" => "object"
             }
           } = workpad_spec

    assert workpad_description =~ "workpad"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "sync_workpad"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql encodes responses compactly (no pretty-print whitespace)" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123", "name" => "Ada"}}}}
        end
      )

    # Pretty-printing inflates every linear_graphql result (1,327 calls in the
    # spend window). The compact encoding must carry no newline-indentation and
    # no indentation runs, while still round-tripping to the same payload.
    refute response["output"] =~ "\n"
    refute response["output"] =~ ~r/:\s/
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123", "name" => "Ada"}}}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503, nil}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    # Bug fix (2026-05-07): when Linear returns a GraphQL validation error
    # (most commonly HTTP 400 with `{"errors":[{"message":"Cannot query
    # field …"}]}`), the agent needs to see the `errors[]` array so it can
    # rewrite the query. Previously the body was discarded and the agent only
    # saw "Linear GraphQL request failed with HTTP 400.", which left it
    # unable to self-correct and the session stalled.
    body = %{
      "errors" => [
        %{
          "message" => "Cannot query field \"resolved\" on type \"Comment\". Did you mean \"resolvedAt\"?",
          "extensions" => %{"code" => "GRAPHQL_VALIDATION_FAILED"}
        }
      ]
    }

    validation_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query GetIssue { issue(id: \"X\") { comments { nodes { resolved } } } }"},
        linear_client: fn _q, _v, _opts -> {:error, {:linear_api_status, 400, body}} end
      )

    assert validation_error["success"] == false
    decoded = Jason.decode!(validation_error["output"])
    assert decoded["error"]["status"] == 400
    assert decoded["error"]["message"] =~ "Linear GraphQL request failed"
    assert is_list(decoded["error"]["errors"])

    assert hd(decoded["error"]["errors"])["message"] =~
             "Cannot query field \"resolved\" on type \"Comment\""

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql hints IssueRelationType enum coercion errors without rewriting (HTTP 400)" do
    # Literal symptom (2026-06-17): a batched issueRelationCreate aliased two
    # relations; $input2 used the non-existent enum value "blocked_by". Linear
    # rejected it at variable-value coercion (BAD_USER_INPUT, HTTP 400).
    body = %{
      "errors" => [
        %{
          "message" =>
            ~s|Variable "$input2" got invalid value "blocked_by" at "input2.type"; | <>
              ~s|Value "blocked_by" does not exist in "IssueRelationType" enum. | <>
              ~s|Did you mean the enum value "blocks"?|,
          "extensions" => %{"code" => "BAD_USER_INPUT"}
        }
      ]
    }

    result =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation { input2: issueRelationCreate(input: {issueId: \"A\", relatedIssueId: \"B\", type: \"blocked_by\"}) { success } }"
        },
        linear_client: fn _q, _v, _opts -> {:error, {:linear_api_status, 400, body}} end
      )

    assert result["success"] == false
    decoded = Jason.decode!(result["output"])
    assert decoded["error"]["status"] == 400

    # Verbatim forwarding is preserved alongside the hint.
    assert hd(decoded["error"]["errors"])["message"] =~
             "Value \"blocked_by\" does not exist in \"IssueRelationType\" enum"

    # An actionable hint is attached.
    hints = decoded["error"]["hint"]
    assert is_list(hints)
    hint = Enum.join(hints, "\n")
    assert hint =~ "only `blocks`"
    assert hint =~ "no `blocked_by`"
    assert hint =~ "swap the operands"
    assert hint =~ ~s(type: "blocks")

    # P3 is deliberately NOT auto-rewritten: the rejected value is still
    # present verbatim (no silent substitution to "blocks"), and the hint tells
    # the agent to swap operands rather than presenting a corrected mutation.
    refute decoded["error"]["errors"] |> hd() |> Map.has_key?("rewritten")
    assert hint =~ "swap"
    refute hint =~ "we have corrected"
  end

  test "linear_graphql hints IssueRelationType enum coercion errors on HTTP 200 bodies" do
    body = %{
      "data" => nil,
      "errors" => [
        %{
          "message" => "Value \"blocked_by\" does not exist in \"IssueRelationType\" enum.",
          "extensions" => %{"code" => "BAD_USER_INPUT"}
        }
      ]
    }

    result =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation { issueRelationCreate(input: {type: \"blocked_by\"}) { success } }"},
        linear_client: fn _q, _v, _opts -> {:ok, body} end
      )

    assert result["success"] == false
    decoded = Jason.decode!(result["output"])

    # Linear's data/errors stay verbatim; the hint lands under a namespaced key.
    assert decoded["data"] == nil
    assert is_list(decoded["errors"])
    hints = decoded["symphony_hint"]
    assert is_list(hints)
    assert Enum.join(hints, "\n") =~ "swap the operands"
  end

  test "linear_graphql does not attach IssueRelationType hints to unrelated errors" do
    # A GRAPHQL_VALIDATION_FAILED error (distinct class) must not trigger the
    # enum hint — no false positives.
    body = %{
      "errors" => [
        %{
          "message" => "Cannot query field \"resolved\" on type \"Comment\". Did you mean \"resolvedAt\"?",
          "extensions" => %{"code" => "GRAPHQL_VALIDATION_FAILED"}
        }
      ]
    }

    result =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query { issue(id: \"X\") { comments { nodes { resolved } } } }"},
        linear_client: fn _q, _v, _opts -> {:error, {:linear_api_status, 400, body}} end
      )

    decoded = Jason.decode!(result["output"])
    refute Map.has_key?(decoded["error"], "hint")
    refute Map.has_key?(decoded, "symphony_hint")
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  test "linear_graphql logs each call as an op-shape telemetry line with context" do
    log =
      capture_log(fn ->
        DynamicTool.execute(
          "linear_graphql",
          %{
            "query" => "mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }",
            "variables" => %{"id" => "iss_1", "input" => %{"stateId" => "done"}}
          },
          linear_client: fn _q, _v, _o -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}} end,
          log_context: %{issue: %{id: "uuid-1", identifier: "IDE-200"}, session_id: "thr_1-turn_1"}
        )
      end)

    assert log =~ "linear_graphql_call"
    assert log =~ "op_type=mutation"
    assert log =~ "root_field=issueUpdate"
    assert log =~ "var_keys=id,input"
    assert log =~ "status=ok"
    assert log =~ "issue_id=uuid-1 issue_identifier=IDE-200"
    assert log =~ "session_id=thr_1-turn_1"
  end

  test "linear_graphql telemetry never leaks the document body or variable values" do
    log =
      capture_log(fn ->
        DynamicTool.execute(
          "linear_graphql",
          %{
            "query" => "mutation CommentCreate($input: CommentCreateInput!) { commentCreate(input: $input) { success } }",
            "variables" => %{"input" => %{"body" => "SECRET ISSUE CONTENT"}}
          },
          linear_client: fn _q, _v, _o -> {:ok, %{"data" => %{}}} end
        )
      end)

    assert log =~ "root_field=commentCreate"
    assert log =~ "var_keys=input"
    refute log =~ "SECRET ISSUE CONTENT"
    refute log =~ "commentCreate(input:"
  end

  test "linear_graphql telemetry records validation errors with their Linear code" do
    log =
      capture_log(fn ->
        DynamicTool.execute(
          "linear_graphql",
          %{"query" => "mutation { issueUpdate { bogusField } }"},
          linear_client: fn _q, _v, _o ->
            {:error, {:linear_api_status, 400, %{"errors" => [%{"extensions" => %{"code" => "GRAPHQL_VALIDATION_FAILED"}}]}}}
          end
        )
      end)

    assert log =~ "root_field=issueUpdate"
    assert log =~ "status=error http=400"
  end

  test "linear_graphql telemetry records calls rejected before reaching Linear" do
    log =
      capture_log(fn ->
        DynamicTool.execute("linear_graphql", %{"query" => "   "})
      end)

    assert log =~ "linear_graphql_call"
    assert log =~ "status=rejected"
    assert log =~ "reason=missing_query"
  end

  # ── workpad-write guard (IDE-257) ───────────────────────────────────
  #
  # The agent must funnel the `## Symphony Workpad` comment through the
  # dedicated `sync_workpad` tool (which reads the multi-KB body Symphony-side
  # so it never enters the token stream). When `sync_workpad` is available the
  # model nonetheless sometimes skips it and pastes the whole body into a raw
  # `linear_graphql` commentCreate/commentUpdate — the exact token-expensive
  # fallback we want to eliminate. The guard turns that silent fallback into a
  # loud, self-correcting failure.

  test "linear_graphql rejects a raw commentUpdate carrying a workpad body and redirects to sync_workpad" do
    marker = Workpad.marker()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success } }",
          "variables" => %{"id" => "c1", "body" => "#{marker}\n\n## Plan\n\n- step one"}
        },
        linear_client: fn _q, _v, _o ->
          flunk("linear client must not be called for a workpad write via linear_graphql")
        end
      )

    assert response["success"] == false
    decoded = Jason.decode!(response["output"])
    assert decoded["error"]["message"] =~ "sync_workpad"
    assert decoded["error"]["use_tool"] == "sync_workpad"
  end

  test "linear_graphql rejects a raw commentCreate with a workpad body nested in input variables" do
    marker = Workpad.marker()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id } } }",
          "variables" => %{"input" => %{"issueId" => "iss_1", "body" => "#{marker}\n\nbootstrap"}}
        },
        linear_client: fn _q, _v, _o -> flunk("linear client must not be called") end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "sync_workpad"
  end

  test "linear_graphql rejects a workpad body inlined directly in the mutation document" do
    marker = Workpad.marker()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => ~s|mutation { commentCreate(input: { issueId: "iss_1", body: "#{marker}\\n\\nplan" }) { success } }|
        },
        linear_client: fn _q, _v, _o -> flunk("linear client must not be called") end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "sync_workpad"
  end

  test "linear_graphql allows ordinary (non-workpad) comment writes" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success } }",
          "variables" => %{"id" => "c1", "body" => "Plain status update, no workpad marker here."}
        },
        linear_client: fn query, variables, _o ->
          send(test_pid, {:called, query, variables})
          {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
        end
      )

    assert_received {:called, _q, _v}
    assert response["success"] == true
  end

  test "linear_graphql allows a read query that merely mentions the workpad marker" do
    marker = Workpad.marker()
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query { issue(id: \"X\") { comments { nodes { id body } } } }",
          "variables" => %{"needle" => marker}
        },
        linear_client: fn _q, _v, _o ->
          send(test_pid, :called)
          {:ok, %{"data" => %{"issue" => %{"comments" => %{"nodes" => []}}}}}
        end
      )

    assert_received :called
    assert response["success"] == true
  end

  test "linear_graphql logs a rejected workpad write as a redirect telemetry line without leaking the body" do
    marker = Workpad.marker()

    log =
      capture_log(fn ->
        DynamicTool.execute(
          "linear_graphql",
          %{
            "query" => "mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success } }",
            "variables" => %{"id" => "c1", "body" => "#{marker}\n\nSECRET WORKPAD CONTENT"}
          },
          linear_client: fn _q, _v, _o -> flunk("linear client must not be called") end,
          log_context: %{issue: %{id: "uuid-1", identifier: "IDE-257"}, session_id: "thr_1-turn_1"}
        )
      end)

    assert log =~ "linear_graphql_call"
    assert log =~ "op_type=mutation"
    assert log =~ "root_field=commentUpdate"
    assert log =~ "status=rejected"
    assert log =~ "reason=workpad_must_use_sync_workpad"
    assert log =~ "issue_id=uuid-1 issue_identifier=IDE-257"
    refute log =~ "SECRET WORKPAD CONTENT"
  end

  # ── sync_workpad ───────────────────────────────────────────────────

  defp write_tmp_workpad(content) do
    path = Path.join(System.tmp_dir!(), "test_workpad_#{:erlang.unique_integer([:positive])}.md")
    File.write!(path, content)
    path
  end

  test "sync_workpad creates a comment from file when no comment_id given" do
    test_pid = self()
    path = write_tmp_workpad("## Codex Workpad\n\nProgress.")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => path},
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:graphql, query, variables})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c1", "url" => "https://linear.app/c1"}}}}}
        end
      )

    assert_received {:graphql, query, %{"issueId" => "ENG-42", "body" => "## Codex Workpad\n\nProgress."}}
    assert query =~ "commentCreate"
    assert response["success"] == true
  end

  test "sync_workpad updates an existing comment when comment_id given" do
    test_pid = self()
    path = write_tmp_workpad("Updated.")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => path, "comment_id" => "c1"},
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:graphql, query, variables})
          {:ok, %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => "c1", "url" => "https://linear.app/c1"}}}}}
        end
      )

    assert_received {:graphql, query, %{"id" => "c1", "body" => "Updated."}}
    assert query =~ "commentUpdate"
    assert response["success"] == true
  end

  test "sync_workpad accepts workpad_path as an alias for file_path" do
    # Every analyzed live session's first sync_workpad call guessed
    # `workpad_path` and burned a round-trip on the validation error
    # (docs/investigations/claude-session-token-optimization.md), so the
    # schema advertises the alias and the executor honors it.
    test_pid = self()
    path = write_tmp_workpad("## Codex Workpad\n\nAliased.")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "workpad_path" => path},
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:graphql, query, variables})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c1", "url" => "https://linear.app/c1"}}}}}
        end
      )

    assert_received {:graphql, _query, %{"issueId" => "ENG-42", "body" => "## Codex Workpad\n\nAliased."}}
    assert response["success"] == true

    workpad_spec = Enum.find(DynamicTool.tool_specs(), &(&1["name"] == "sync_workpad"))
    assert %{"inputSchema" => %{"properties" => %{"workpad_path" => _}}} = workpad_spec
  end

  test "sync_workpad reports the returned comment id to the workpad-comment sink" do
    # The orchestrator caches the workpad comment id per issue so a later
    # re-run's continuation context can hand it to the agent instead of the
    # agent re-scanning issue comments (finding 5 in
    # docs/investigations/claude-session-token-optimization.md).
    test_pid = self()
    path = write_tmp_workpad("## Codex Workpad\n\nProgress.")

    issue = %SymphonyElixir.Linear.Issue{id: "uuid-42", identifier: "ENG-42"}

    DynamicTool.execute(
      "sync_workpad",
      %{"issue_id" => "ENG-42", "file_path" => path},
      linear_client: fn _query, _variables, _opts ->
        {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-new", "url" => "u"}}}}}
      end,
      log_context: %{issue: issue, session_id: "sess-1"},
      workpad_comment_sink: fn issue_id, comment_id ->
        send(test_pid, {:workpad_comment, issue_id, comment_id})
      end
    )

    assert_received {:workpad_comment, "uuid-42", "c-new"}

    DynamicTool.execute(
      "sync_workpad",
      %{"issue_id" => "ENG-42", "file_path" => path, "comment_id" => "c-new"},
      linear_client: fn _query, _variables, _opts ->
        {:ok, %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => "c-new", "url" => "u"}}}}}
      end,
      log_context: %{issue: issue, session_id: "sess-1"},
      workpad_comment_sink: fn issue_id, comment_id ->
        send(test_pid, {:workpad_comment_update, issue_id, comment_id})
      end
    )

    assert_received {:workpad_comment_update, "uuid-42", "c-new"}
  end

  test "sync_workpad does not invoke the sink on GraphQL failure or without an issue in log_context" do
    test_pid = self()
    path = write_tmp_workpad("## Codex Workpad\n\nProgress.")

    DynamicTool.execute(
      "sync_workpad",
      %{"issue_id" => "ENG-42", "file_path" => path},
      linear_client: fn _query, _variables, _opts ->
        {:ok, %{"errors" => [%{"message" => "boom"}], "data" => nil}}
      end,
      log_context: %{issue: %SymphonyElixir.Linear.Issue{id: "uuid-42"}, session_id: "s"},
      workpad_comment_sink: fn issue_id, comment_id ->
        send(test_pid, {:workpad_comment, issue_id, comment_id})
      end
    )

    refute_received {:workpad_comment, _, _}

    DynamicTool.execute(
      "sync_workpad",
      %{"issue_id" => "ENG-42", "file_path" => path},
      linear_client: fn _query, _variables, _opts ->
        {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c-9", "url" => "u"}}}}}
      end,
      workpad_comment_sink: fn issue_id, comment_id ->
        send(test_pid, {:workpad_comment, issue_id, comment_id})
      end
    )

    refute_received {:workpad_comment, _, _}
  end

  test "sync_workpad prefers file_path when workpad_path is also given" do
    test_pid = self()
    canonical = write_tmp_workpad("canonical body")
    alias_path = write_tmp_workpad("alias body")

    DynamicTool.execute(
      "sync_workpad",
      %{"issue_id" => "ENG-42", "file_path" => canonical, "workpad_path" => alias_path},
      linear_client: fn query, variables, _opts ->
        send(test_pid, {:graphql, query, variables})
        {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c1", "url" => "https://linear.app/c1"}}}}}
      end
    )

    assert_received {:graphql, _query, %{"body" => "canonical body"}}
  end

  test "sync_workpad bypasses the workpad-write guard for a real Symphony Workpad body" do
    test_pid = self()
    marker = Workpad.marker()
    path = write_tmp_workpad("#{marker}\n\n## Plan\n\n- step one")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => path, "comment_id" => "c1"},
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:graphql, query, variables})
          {:ok, %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => "c1"}}}}}
        end
      )

    assert_received {:graphql, query, %{"id" => "c1", "body" => body}}
    assert query =~ "commentUpdate"
    assert body =~ marker
    assert response["success"] == true
  end

  test "sync_workpad logs a positive sync_workpad_call telemetry line without the body" do
    marker = Workpad.marker()
    path = write_tmp_workpad("#{marker}\n\nSECRET WORKPAD CONTENT")

    log =
      capture_log(fn ->
        DynamicTool.execute(
          "sync_workpad",
          %{"issue_id" => "ENG-42", "file_path" => path, "comment_id" => "c1"},
          linear_client: fn _q, _v, _o -> {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}} end,
          log_context: %{issue: %{id: "uuid-1", identifier: "IDE-256"}, session_id: "s1"}
        )
      end)

    assert log =~ "sync_workpad_call"
    assert log =~ "action=update"
    assert log =~ "has_marker=true"
    assert log =~ "issue_identifier=IDE-256"
    refute log =~ "SECRET WORKPAD CONTENT"
  end

  test "sync_workpad validates required arguments before calling Linear" do
    no_issue =
      DynamicTool.execute(
        "sync_workpad",
        %{"file_path" => "/tmp/x"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert no_issue["success"] == false
    assert [%{"text" => no_issue_text}] = no_issue["contentItems"]
    assert Jason.decode!(no_issue_text)["error"]["message"] =~ "issue_id"

    no_path =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert no_path["success"] == false
    assert [%{"text" => no_path_text}] = no_path["contentItems"]
    assert Jason.decode!(no_path_text)["error"]["message"] =~ "file_path"
  end

  test "sync_workpad rejects an empty workpad file" do
    path = write_tmp_workpad("")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => path},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the file is empty")
        end
      )

    assert response["success"] == false
    assert [%{"text" => text}] = response["contentItems"]
    assert Jason.decode!(text)["error"]["message"] =~ "file is empty"
  end

  test "sync_workpad reports unreadable file paths" do
    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "ENG-42", "file_path" => "/tmp/does_not_exist_#{:erlang.unique_integer([:positive])}.md"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the file cannot be read")
        end
      )

    assert response["success"] == false
    assert [%{"text" => text}] = response["contentItems"]
    assert Jason.decode!(text)["error"]["message"] =~ "cannot read"
  end
end
