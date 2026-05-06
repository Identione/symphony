defmodule SymphonyElixir.AgentAdapterBehaviourTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.Adapter
  alias SymphonyElixir.Codex.AppServer, as: CodexAppServer

  describe "Adapter behaviour" do
    test "declares start_session/2, run_turn/4, stop_session/1 callbacks" do
      callbacks = Adapter.behaviour_info(:callbacks) |> Enum.sort()

      assert {:start_session, 2} in callbacks
      assert {:run_turn, 4} in callbacks
      assert {:stop_session, 1} in callbacks
    end
  end

  describe "Codex adapter" do
    test "implements the Adapter behaviour" do
      behaviours =
        CodexAppServer.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Adapter in behaviours
    end
  end
end
