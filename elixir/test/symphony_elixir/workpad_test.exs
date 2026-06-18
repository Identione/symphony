defmodule SymphonyElixir.WorkpadTest do
  @moduledoc """
  Coverage for the shared `## Symphony Workpad` finder (IDE-230) extracted from
  `DeterministicFailure`: only an *active* (unresolved) comment carrying the
  marker is eligible, and the comment fetch's `{:error, _}` is propagated.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workpad

  setup do
    # Route Tracker.fetch_comments/1 through the in-memory adapter.
    path = Workflow.workflow_file_path()
    content = File.read!(path)
    File.write!(path, String.replace(content, ~s(kind: "linear"), ~s(kind: "memory")))

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_comments_response)
    end)

    :ok
  end

  describe "candidate?/1" do
    test "true for an unresolved comment carrying the marker" do
      assert Workpad.candidate?(%{body: "## Symphony Workpad\n- plan", resolved_at: nil})
    end

    test "false for a resolved comment, a non-marker comment, or a bad shape" do
      refute Workpad.candidate?(%{body: "## Symphony Workpad", resolved_at: "2026-01-01"})
      refute Workpad.candidate?(%{body: "just a comment", resolved_at: nil})
      refute Workpad.candidate?(%{body: nil, resolved_at: nil})
      refute Workpad.candidate?(:not_a_map)
    end
  end

  describe "find/1" do
    test "returns the first active workpad comment" do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-wp" => [
          %{id: "c1", body: "unrelated", resolved_at: nil},
          %{id: "c2", body: "## Symphony Workpad\n- plan", resolved_at: nil}
        ]
      })

      assert {:ok, %{id: "c2"}} = Workpad.find("issue-wp")
    end

    test "skips a resolved workpad comment" do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-wp" => [%{id: "c1", body: "## Symphony Workpad", resolved_at: "2026-01-01"}]
      })

      assert :not_found = Workpad.find("issue-wp")
    end

    test "returns :not_found when no comment matches" do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{"issue-wp" => []})
      assert :not_found = Workpad.find("issue-wp")
    end

    test "propagates a comment-fetch error" do
      Application.put_env(:symphony_elixir, :memory_tracker_fetch_comments_response, {:error, :boom})
      assert {:error, :boom} = Workpad.find("issue-wp")
    end
  end
end
