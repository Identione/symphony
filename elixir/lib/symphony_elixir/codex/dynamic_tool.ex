defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

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

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
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

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
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
end
