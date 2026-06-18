defmodule LinearSim.Compat.Context do
  @moduledoc """
  Builds the Absinthe context from an `Authorization` value (docs/linear-sim.md §14).

  This is the single token→context path. `LinearSimWeb.GraphQL.Plugs.Context`
  (the HTTP path) and `mix linear_sim.replay_operations` (the `Absinthe.run/3`
  path) both delegate here so the two replay surfaces resolve identity
  identically.
  """

  alias LinearSim.Linear

  @doc """
  Resolves an `Authorization` header value (e.g. `"Bearer user_hakan"`, a bare
  token, or `nil`) into an Absinthe context map. A missing header yields the
  default scenario user; an unrecognised token sets `auth_error: :invalid_token`.
  """
  @spec from_auth(String.t() | nil) :: map()
  def from_auth(authorization) do
    authorization
    |> parse_authorization()
    |> build_context()
  end

  defp parse_authorization("Bearer " <> token), do: String.trim(token)
  defp parse_authorization(token) when is_binary(token), do: String.trim(token)
  defp parse_authorization(_), do: nil

  defp build_context(nil) do
    %{
      current_user: Linear.default_user(),
      current_organization: Linear.default_organization()
    }
  end

  defp build_context(token) do
    case Linear.resolve_token(token) do
      {:ok, user, organization} ->
        %{current_user: user, current_organization: organization, simulator_token: token}

      :error ->
        %{
          current_user: nil,
          current_organization: nil,
          simulator_token: token,
          auth_error: :invalid_token
        }
    end
  end
end
