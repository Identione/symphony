defmodule LinearSim.Compat.ContextTest do
  use LinearSim.DataCase, async: false

  alias LinearSim.Compat.Context

  test "resolves a known token to its user and organization" do
    ctx = Context.from_auth("Bearer user_hakan")

    assert ctx.current_user.id == "user_hakan"
    assert ctx.current_organization.id == "org_default"
    assert ctx.simulator_token == "user_hakan"
  end

  test "falls back to the default user when no header is present" do
    ctx = Context.from_auth(nil)

    refute is_nil(ctx.current_user)
    refute is_nil(ctx.current_organization)
  end

  test "marks an unknown token with auth_error: :invalid_token" do
    ctx = Context.from_auth("Bearer not_a_real_token")

    assert ctx.current_user == nil
    assert ctx.auth_error == :invalid_token
    assert ctx.simulator_token == "not_a_real_token"
  end

  test "accepts a bare token without the Bearer prefix" do
    ctx = Context.from_auth("user_hakan")
    assert ctx.current_user.id == "user_hakan"
  end
end
