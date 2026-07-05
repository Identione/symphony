defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  require Logger

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Workpad

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @sync_workpad_tool "sync_workpad"
  @sync_workpad_description "Create or update a workpad comment on a Linear issue. Reads the body from a local file to keep the conversation context small."
  @sync_workpad_create "mutation($issueId: String!, $body: String!) { commentCreate(input: { issueId: $issueId, body: $body }) { success comment { id url } } }"
  @sync_workpad_update "mutation($id: String!, $body: String!) { commentUpdate(id: $id, input: { body: $body }) { success comment { id url } } }"
  # `file_path` is semantically required but deliberately NOT in `required`:
  # live sessions reliably guess `workpad_path` on the first call, and a
  # schema-level rejection burns a full model round-trip. The alias is
  # accepted here and normalized in `normalize_sync_workpad_args/1`; a call
  # with neither still gets a clear executor error the model can react to.
  @sync_workpad_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier (e.g. \"ENG-123\") or internal UUID."
      },
      "file_path" => %{
        "type" => "string",
        "description" => "Path to a local markdown file whose contents become the comment body. Required (unless the workpad_path alias is given)."
      },
      "workpad_path" => %{
        "type" => "string",
        "description" => "Alias for file_path; ignored when file_path is present."
      },
      "comment_id" => %{
        "type" => "string",
        "description" => "Existing comment ID to update. Omit to create a new comment."
      }
    }
  }

  # Corrective hints attached to Linear GraphQL `errors[]` for known,
  # recurring mistake classes. Each rule matches an error `message` and adds an
  # actionable hint *alongside* the verbatim `errors[]` — we never rewrite the
  # agent's call. For the `IssueRelationType` enum case the intended direction is
  # genuinely unknowable from the failed request (the bad value lives in the
  # `variables` payload), so auto-substituting `blocks` could silently invert the
  # dependency. Hint, never rewrite.
  #
  # Live-API fact (authoritative — do not "correct" against stale docs):
  # `IssueRelationType` has NO `blocked_by` member. The only directional value is
  # `blocks`; direction is encoded purely by operand order.
  @linear_error_hint_rules [
    %{
      match: ~r/does not exist in "IssueRelationType" enum/,
      hint:
        ~s|IssueRelationType has only `blocks` — there is no `blocked_by` member. | <>
          ~s|Direction is expressed by operand order, never by a type value: | <>
          ~s|issueRelationCreate(input: { issueId, relatedIssueId, type: "blocks" }) | <>
          ~s|means issueId BLOCKS relatedIssueId. To express "A is blocked by B", | <>
          ~s|swap the operands: set issueId to B and relatedIssueId to A, with | <>
          ~s|type "blocks". Do not pass "blocked_by".|
    }
  ]

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @sync_workpad_tool ->
        execute_sync_workpad(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @sync_workpad_tool,
        "description" => @sync_workpad_description,
        "inputSchema" => @sync_workpad_input_schema
      }
    ]
  end

  defp execute_sync_workpad(args, opts) do
    with {:ok, issue_id, file_path, comment_id} <- normalize_sync_workpad_args(args),
         {:ok, body} <- read_workpad_file(file_path) do
      {query, variables} =
        if comment_id,
          do: {@sync_workpad_update, %{"id" => comment_id, "body" => body}},
          else: {@sync_workpad_create, %{"issueId" => issue_id, "body" => body}}

      # Positive telemetry: a `sync_workpad_call` line is the durable proof the
      # agent used the dedicated tool (body bytes + marker presence only — never
      # the body itself, per docs/logging.md). Pairs with the guard's
      # `status=rejected reason=workpad_must_use_sync_workpad` line so the log
      # tells the whole story of which path each workpad write took.
      log_sync_workpad_call(comment_id, body, opts)

      # `sync_workpad` is the sanctioned path for workpad writes, so it bypasses
      # the raw-tool workpad guard below (the body legitimately carries the
      # `## Symphony Workpad` marker).
      response =
        execute_linear_graphql(
          %{"query" => query, "variables" => variables},
          Keyword.put(opts, :allow_workpad_write, true)
        )

      report_workpad_comment_id(response, opts)
      response
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  # Report the comment id a successful sync returned to the orchestrator (or a
  # test-injected sink) so a later re-run's continuation context can hand it
  # back to the agent instead of the agent re-scanning issue comments.
  # Best-effort: a missing issue in log_context, a decode failure, or an absent
  # orchestrator all degrade to a no-op — the tool result is never affected.
  defp report_workpad_comment_id(%{"success" => true, "output" => output}, opts)
       when is_binary(output) do
    with issue_id when is_binary(issue_id) <- workpad_issue_id(opts),
         comment_id when is_binary(comment_id) <- decode_workpad_comment_id(output) do
      sink =
        Keyword.get(opts, :workpad_comment_sink, &SymphonyElixir.Orchestrator.note_workpad_comment/2)

      sink.(issue_id, comment_id)
      :ok
    else
      _ -> :ok
    end
  end

  defp report_workpad_comment_id(_response, _opts), do: :ok

  defp workpad_issue_id(opts) do
    case Keyword.get(opts, :log_context) do
      %{issue: %{id: id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp decode_workpad_comment_id(output) do
    case Jason.decode(output) do
      {:ok, %{"data" => data}} when is_map(data) ->
        get_in(data, ["commentCreate", "comment", "id"]) ||
          get_in(data, ["commentUpdate", "comment", "id"])

      _ ->
        nil
    end
  end

  defp normalize_sync_workpad_args(%{} = args) do
    issue_id = nonempty_string_arg(args, "issue_id", :issue_id)

    file_path =
      nonempty_string_arg(args, "file_path", :file_path) ||
        nonempty_string_arg(args, "workpad_path", :workpad_path)

    comment_id = nonempty_string_arg(args, "comment_id", :comment_id)

    cond do
      is_nil(issue_id) -> {:error, {:sync_workpad, "`issue_id` is required"}}
      is_nil(file_path) -> {:error, {:sync_workpad, "`file_path` is required"}}
      true -> {:ok, issue_id, file_path, comment_id}
    end
  end

  defp normalize_sync_workpad_args(_args) do
    {:error, {:sync_workpad, "`issue_id` and `file_path` are required"}}
  end

  defp nonempty_string_arg(args, string_key, atom_key) do
    case Map.get(args, string_key) || Map.get(args, atom_key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp read_workpad_file(path) do
    case File.read(path) do
      {:ok, ""} -> {:error, {:sync_workpad, "file is empty: `#{path}`"}}
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:sync_workpad, "cannot read `#{path}`: #{:file.format_error(reason)}"}}
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    case normalize_linear_graphql_arguments(arguments) do
      {:ok, query, variables} ->
        run_linear_graphql(query, variables, opts)

      {:error, reason} ->
        # The call never reached Linear (missing/invalid query). Still record the
        # attempt so malformed operations surface in the same telemetry stream.
        log_linear_graphql_rejected(reason, opts)
        failure_response(tool_error_payload(reason))
    end
  end

  # The agent pasted the whole `## Symphony Workpad` body into a raw comment
  # mutation instead of calling `sync_workpad`. Refuse it loudly so the
  # multi-KB body never reaches Linear via this path (and never gets re-paid as
  # conversation context), and point the agent at the dedicated tool. The
  # internal sync_workpad call carries `allow_workpad_write: true` and is exempt.
  defp run_linear_graphql(query, variables, opts) do
    # Summarize once and reuse: both the guard (via `comment_mutation?`) and the
    # telemetry line need the op-shape, and this runs once per turn (~1,300 calls
    # in the spend window), so re-parsing the document twice is pure waste.
    summary = summarize_operation(query)

    if workpad_write_via_raw_tool?(summary, query, variables, opts) do
      log_workpad_redirect(summary, variables, opts)
      failure_response(workpad_redirect_payload())
    else
      linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
      result = linear_client.(query, variables, [])
      log_linear_graphql_call(summary, variables, result, opts)
      graphql_result_response(result)
    end
  end

  defp graphql_result_response({:ok, response}), do: graphql_response(response)
  defp graphql_result_response({:error, reason}), do: failure_response(tool_error_payload(reason))

  # ---------------------------------------------------------------------------
  # Workpad-write guard (IDE-257)
  #
  # `sync_workpad` exists to keep the multi-KB `## Symphony Workpad` body out of
  # the model's token stream — it reads the body from a local file on the
  # Symphony side. When the agent skips that tool and pastes the body into a raw
  # `linear_graphql` commentCreate/commentUpdate it defeats the whole point and
  # re-pays the body on every turn. We can't force the model to discover the
  # tool, so we make the raw fallback fail loudly: any comment mutation whose
  # body carries the workpad marker is rejected with a message pointing back at
  # `sync_workpad`. `sync_workpad`'s own forwarded mutation sets
  # `allow_workpad_write: true` and is exempt.
  # ---------------------------------------------------------------------------
  defp workpad_write_via_raw_tool?(summary, query, variables, opts) do
    not Keyword.get(opts, :allow_workpad_write, false) and
      comment_mutation?(summary) and
      contains_workpad_marker?(query, variables)
  end

  defp comment_mutation?(%{op_type: op_type, root_field: root_field}) do
    op_type == "mutation" and root_field in ["commentCreate", "commentUpdate"]
  end

  # The body may arrive as a top-level `body` variable, nested inside an `input`
  # object, or inlined directly in the document — scan all of them for the
  # marker rather than assuming a single shape.
  defp contains_workpad_marker?(query, variables) do
    marker = Workpad.marker()
    String.contains?(query, marker) or value_contains?(variables, marker)
  end

  defp value_contains?(value, marker) when is_binary(value), do: String.contains?(value, marker)
  defp value_contains?(value, marker) when is_map(value), do: Enum.any?(value, fn {_k, v} -> value_contains?(v, marker) end)
  defp value_contains?(value, marker) when is_list(value), do: Enum.any?(value, &value_contains?(&1, marker))
  defp value_contains?(_value, _marker), do: false

  defp workpad_redirect_payload do
    %{
      "error" => %{
        "message" =>
          "Workpad comments must not be created or updated through `linear_graphql`. " <>
            "This body carries the `#{Workpad.marker()}` marker, so it is the persistent " <>
            "workpad — posting it through `linear_graphql` floods the conversation context " <>
            "with the multi-KB body and re-pays it on every turn. Use the dedicated " <>
            "`sync_workpad` tool instead: write the body to a local markdown file and call " <>
            "`sync_workpad` with `issue_id`, `file_path`, and (to update an existing comment) " <>
            "`comment_id`. If the tool is not listed, run `ToolSearch` with " <>
            "`select:mcp__symphony_workpad__sync_workpad` first.",
        "use_tool" => "sync_workpad"
      }
    }
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    errors =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> errors
        %{errors: errors} when is_list(errors) and errors != [] -> errors
        _ -> []
      end

    success = errors == []

    # Even on HTTP 200 Linear can return `errors[]` (partial/execution errors).
    # Attach corrective hints under a namespaced key so Linear's `data`/`errors`
    # stay verbatim.
    payload =
      case linear_error_hints(errors) do
        [] -> response
        hints -> Map.put(response, "symphony_hint", hints)
      end

    dynamic_tool_response(success, encode_payload(payload))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  # Compact encoding (no `pretty: true`): every linear_graphql result is pasted
  # into the conversation and re-read on each subsequent turn (~1,327 calls in
  # the spend window), so pretty-print indentation is paid for many times over.
  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status, body}) do
    base = %{
      "message" => "Linear GraphQL request failed with HTTP #{status}.",
      "status" => status
    }

    # Forward Linear's GraphQL `errors[]` so the agent can self-correct
    # (e.g. "Cannot query field X. Did you mean Y?"). Without this the agent
    # only sees "HTTP 400" with no actionable detail.
    error =
      case body do
        %{"errors" => [_ | _] = errors} ->
          base
          |> Map.put("errors", errors)
          |> maybe_put_hint(linear_error_hints(errors))

        _ ->
          base
      end

    %{"error" => error}
  end

  defp tool_error_payload(:rate_limited) do
    %{
      "error" => %{
        "message" => "Linear API rate limit exhausted; Symphony is pausing Linear traffic until the window resets."
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:sync_workpad, message}) do
    %{"error" => %{"message" => "sync_workpad: #{message}"}}
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp maybe_put_hint(map, []), do: map
  defp maybe_put_hint(map, hints), do: Map.put(map, "hint", hints)

  # Scans an `errors[]` list against `@linear_error_hint_rules` and returns the
  # de-duplicated list of matching corrective hints (or `[]`). Handles string-
  # and atom-keyed error maps, mirroring `graphql_response/1`.
  defp linear_error_hints(errors) when is_list(errors) do
    messages = Enum.map(errors, &error_message/1)

    @linear_error_hint_rules
    |> Enum.filter(fn rule -> Enum.any?(messages, &Regex.match?(rule.match, &1)) end)
    |> Enum.map(& &1.hint)
    |> Enum.uniq()
  end

  defp linear_error_hints(_errors), do: []

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(_error), do: ""

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  # ---------------------------------------------------------------------------
  # Operation telemetry
  #
  # Every raw `linear_graphql` call is summarised to one compact, greppable log
  # line (`linear_graphql_call …`) so the set of operations the agent actually
  # issues can be mined over time to decide which typed, parameterised helpers
  # are worth building, e.g.:
  #
  #     grep -oE 'root_field=[A-Za-z0-9_]+' symphony.log | sort | uniq -c | sort -rn
  #
  # We log the operation *shape* only — op type, root field, the variable *keys*,
  # and the outcome — and never the document body or variable *values*, which can
  # be large and carry issue content (see docs/logging.md, "Avoid logging large
  # payloads").
  # ---------------------------------------------------------------------------
  defp log_linear_graphql_call(%{op_type: op_type, root_field: root_field}, variables, result, opts) do
    Logger.info(
      "linear_graphql_call op_type=#{op_type} root_field=#{root_field} " <>
        "var_keys=#{variable_keys(variables)} #{result_status(result)}" <>
        log_context_suffix(opts)
    )
  end

  defp log_linear_graphql_rejected(reason, opts) do
    Logger.info(
      "linear_graphql_call op_type=unknown root_field=unknown var_keys= " <>
        "status=rejected reason=#{reason}" <> log_context_suffix(opts)
    )
  end

  # The workpad guard rejects the call *after* a successful parse, so unlike
  # `log_linear_graphql_rejected/2` we know the real operation shape. Keep the
  # same op-shape format (op_type / root_field / var_keys only — never the body)
  # so `reason=workpad_must_use_sync_workpad` lines are greppable alongside the
  # normal call telemetry. This is the durable signal that a fallback was caught.
  defp log_sync_workpad_call(comment_id, body, opts) do
    action = if comment_id, do: "update", else: "create"

    Logger.info(
      "sync_workpad_call action=#{action} body_bytes=#{byte_size(body)} " <>
        "has_marker=#{String.contains?(body, Workpad.marker())}" <> log_context_suffix(opts)
    )
  end

  defp log_workpad_redirect(%{op_type: op_type, root_field: root_field}, variables, opts) do
    Logger.info(
      "linear_graphql_call op_type=#{op_type} root_field=#{root_field} " <>
        "var_keys=#{variable_keys(variables)} status=rejected " <>
        "reason=workpad_must_use_sync_workpad" <> log_context_suffix(opts)
    )
  end

  # Cheap structural summary — extract the operation type and first root field
  # via regex rather than a full GraphQL parse. Variable definition lists carry
  # no braces, so the first `{` reliably opens the top-level selection set.
  defp summarize_operation(query) do
    trimmed = String.trim(query)

    op_type =
      case Regex.run(~r/^\s*(query|mutation|subscription)\b/i, trimmed) do
        [_, keyword] -> String.downcase(keyword)
        # Anonymous shorthand (`{ viewer { id } }`) is always a query.
        _ -> "query"
      end

    root_field =
      case Regex.run(~r/\{\s*([A-Za-z_][A-Za-z0-9_]*)/, trimmed) do
        [_, field] -> field
        _ -> "unknown"
      end

    %{op_type: op_type, root_field: root_field}
  end

  defp variable_keys(variables) when is_map(variables) and map_size(variables) > 0 do
    variables
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.join(",")
    |> String.slice(0, 200)
  end

  defp variable_keys(_variables), do: ""

  defp result_status({:ok, response}) do
    case response_error_codes(response) do
      [] -> "status=ok"
      codes -> "status=graphql_error codes=#{Enum.join(codes, ",")}"
    end
  end

  defp result_status({:error, {:linear_api_status, status, _body}}), do: "status=error http=#{status}"
  defp result_status({:error, :rate_limited}), do: "status=error reason=rate_limited"
  defp result_status({:error, {:linear_api_request, _reason}}), do: "status=error reason=request_failed"
  defp result_status({:error, reason}), do: "status=error reason=#{inspect(reason)}"

  # Pulls Linear's `errors[].extensions.code` (e.g. GRAPHQL_VALIDATION_FAILED)
  # for HTTP-200-with-errors responses, mirroring `linear_error_hints/1`'s
  # tolerance of string- and atom-keyed maps.
  defp response_error_codes(response) do
    errors =
      case response do
        %{"errors" => errors} when is_list(errors) -> errors
        %{errors: errors} when is_list(errors) -> errors
        _ -> []
      end

    errors
    |> Enum.map(&error_code/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp error_code(%{"extensions" => %{"code" => code}}) when is_binary(code), do: code
  defp error_code(%{extensions: %{code: code}}) when is_binary(code), do: code
  defp error_code(_error), do: nil

  defp log_context_suffix(opts) do
    case Keyword.get(opts, :log_context) do
      %{} = ctx ->
        [issue_fields(Map.get(ctx, :issue)), session_field(Map.get(ctx, :session_id) || Map.get(ctx, :thread_id))]
        |> Enum.reject(&(&1 == ""))
        |> Enum.map_join("", &(" " <> &1))

      _ ->
        ""
    end
  end

  defp issue_fields(%{id: id, identifier: identifier}), do: "issue_id=#{id} issue_identifier=#{identifier}"
  defp issue_fields(_issue), do: ""

  defp session_field(session) when is_binary(session) and session != "", do: "session_id=#{session}"
  defp session_field(_session), do: ""
end
