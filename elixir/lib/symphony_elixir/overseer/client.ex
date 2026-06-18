defmodule SymphonyElixir.Overseer.Client do
  @moduledoc """
  Engine (a) for the Layer 2 overseer (IDE-212): a single read-only call to the
  Anthropic Messages API (`POST /v1/messages`).

  Read-only by construction — the only tool offered is `emit_verdict`, whose
  `input_schema` *is* the verdict contract, and `tool_choice` forces the model
  to call it. The model cannot read files, run commands, or touch the workspace;
  it can only emit the structured verdict. The returned value is the raw
  `tool_use.input` map (string keys); shape validation lives in
  `SymphonyElixir.Overseer`.

  Every failure path returns `{:error, reason}` — the caller (the overseer) is
  fail-open, so a transport/HTTP/parse error must never raise into the turn loop.
  """

  require Logger

  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig

  @anthropic_version "2023-06-01"
  @tool_name "emit_verdict"
  @max_tokens 1024

  @verdict_tool_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["verdict", "confidence", "recommended_action", "steering_message", "rationale"],
    "properties" => %{
      "verdict" => %{"type" => "string", "enum" => ["converging", "thrashing", "blocked"]},
      "confidence" => %{"type" => "number", "minimum" => 0, "maximum" => 1},
      "recommended_action" => %{
        "type" => "string",
        "enum" => ["continue", "nudge", "recommend_extend_budget", "escalate", "abort"]
      },
      "steering_message" => %{"type" => ["string", "null"]},
      "rationale" => %{"type" => "string"}
    }
  }

  @doc "The JSON schema the model must satisfy. Exposed for tests/docs."
  @spec verdict_tool_schema() :: map()
  def verdict_tool_schema, do: @verdict_tool_schema

  @doc """
  Classify a near-budget run. `messages` carries the rendered `:system` prompt
  and `:user` evidence message. Returns the raw verdict map (string keys) on
  success, or `{:error, reason}` on any transport/HTTP/shape failure.
  """
  @spec classify(%{system: String.t(), user: String.t()}, OverseerConfig.t()) ::
          {:ok, map()} | {:error, term()}
  def classify(%{system: system, user: user}, %OverseerConfig{} = config)
      when is_binary(system) and is_binary(user) do
    body = request_body(system, user, config)

    case post(body, config) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        extract_verdict(response_body)

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:overseer_http_error, status, summarize(response_body)}}

      {:error, reason} ->
        {:error, {:overseer_transport_error, reason}}
    end
  end

  @spec request_body(String.t(), String.t(), OverseerConfig.t()) :: map()
  defp request_body(system, user, config) do
    %{
      model: config.model,
      max_tokens: @max_tokens,
      system: system,
      messages: [%{role: "user", content: user}],
      tools: [
        %{
          name: @tool_name,
          description: "Emit the structured turn-budget overseer verdict. You MUST call this tool exactly once.",
          input_schema: @verdict_tool_schema
        }
      ],
      tool_choice: %{type: "tool", name: @tool_name}
    }
  end

  @spec post(map(), OverseerConfig.t()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp post(body, config) do
    Req.post(base_url() <> "/v1/messages",
      headers: [
        {"x-api-key", config.api_key},
        {"anthropic-version", @anthropic_version},
        {"content-type", "application/json"}
      ],
      json: body,
      receive_timeout: config.timeout_ms,
      retry: false
    )
  rescue
    exception -> {:error, {:overseer_request_raised, Exception.message(exception)}}
  end

  # Test seam (mirrors the orchestrator's task-supervisor override): point the
  # client at a Req.Test/Bypass stub without a live Anthropic endpoint.
  @spec base_url() :: String.t()
  defp base_url do
    Application.get_env(:symphony_elixir, :overseer_api_base_url, "https://api.anthropic.com")
  end

  @spec extract_verdict(term()) :: {:ok, map()} | {:error, term()}
  defp extract_verdict(%{"content" => content}) when is_list(content) do
    content
    |> Enum.find(fn block -> is_map(block) and block["type"] == "tool_use" end)
    |> case do
      %{"input" => input} when is_map(input) -> {:ok, input}
      _ -> {:error, :overseer_no_tool_use}
    end
  end

  defp extract_verdict(_other), do: {:error, :overseer_unexpected_response}

  @spec summarize(term()) :: String.t()
  defp summarize(body) when is_binary(body), do: String.slice(body, 0, 256)
  defp summarize(body), do: body |> inspect(limit: 20, printable_limit: 256) |> String.slice(0, 256)
end
