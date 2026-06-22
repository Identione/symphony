defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  require Logger

  alias SymphonyElixir.Linear.Client

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
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    case normalize_linear_graphql_arguments(arguments) do
      {:ok, query, variables} ->
        result = linear_client.(query, variables, [])
        log_linear_graphql_call(query, variables, result, opts)

        case result do
          {:ok, response} -> graphql_response(response)
          {:error, reason} -> failure_response(tool_error_payload(reason))
        end

      {:error, reason} ->
        # The call never reached Linear (missing/invalid query). Still record the
        # attempt so malformed operations surface in the same telemetry stream.
        log_linear_graphql_rejected(reason, opts)
        failure_response(tool_error_payload(reason))
    end
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
  defp log_linear_graphql_call(query, variables, result, opts) do
    %{op_type: op_type, root_field: root_field} = summarize_operation(query)

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
