defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Linear.Pagination
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 5_000

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 5_000

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 5_000

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "issue-1" => [%{id: "c1", body: "## Symphony Workpad\n", resolved_at: nil}]
    })

    assert {:ok, [%{id: "c1", body: "## Symphony Workpad\n", resolved_at: nil}]} =
             SymphonyElixir.Tracker.fetch_comments("issue-1")

    assert {:ok, []} = SymphonyElixir.Tracker.fetch_comments("unknown-issue")

    assert :ok = SymphonyElixir.Tracker.update_comment("c1", "edited")
    assert_receive {:memory_tracker_comment_update, "c1", "edited"}

    # Error-injection hooks short-circuit the happy path so tests can drive
    # the DeterministicFailure error branches without a real transport.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_comments_response, {:error, :boom})
    assert {:error, :boom} = SymphonyElixir.Tracker.fetch_comments("issue-1")
    Application.delete_env(:symphony_elixir, :memory_tracker_fetch_comments_response)

    Application.put_env(:symphony_elixir, :memory_tracker_update_comment_response, {:error, :boom})
    assert {:error, :boom} = SymphonyElixir.Tracker.update_comment("c1", "edited")
    Application.delete_env(:symphony_elixir, :memory_tracker_update_comment_response)

    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_response, {:error, :boom})
    assert {:error, :boom} = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_response)

    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_response, {:error, :boom})
    assert {:error, :boom} = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_response)

    Application.delete_env(:symphony_elixir, :memory_tracker_comments)
    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")
    assert {:ok, []} = Memory.fetch_comments("issue-1")
    assert :ok = Memory.update_comment("c1", "quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")

    # The query advertises pagination metadata (`pageInfo { hasNextPage
    # endCursor }`) so callers can rely on every comment being returned even on
    # issues with more than `@comments_page_size` comments (IDE-103).
    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [
                 %{"id" => "c1", "body" => "hi", "resolvedAt" => nil},
                 %{"id" => "c2", "body" => "resolved", "resolvedAt" => "2025-01-01T00:00:00Z"},
                 %{"id" => "c3"}
               ],
               "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
             }
           }
         }
       }}
    )

    assert {:ok, comments} = Adapter.fetch_comments("issue-1")

    assert_receive {:graphql_called, fetch_comments_query, %{first: 50, issueId: "issue-1", after: nil}}

    assert fetch_comments_query =~ "orderBy: createdAt"
    assert fetch_comments_query =~ "pageInfo"
    assert fetch_comments_query =~ "hasNextPage"
    assert fetch_comments_query =~ "endCursor"

    assert comments == [
             %{id: "c1", body: "hi", resolved_at: nil},
             %{id: "c2", body: "resolved", resolved_at: "2025-01-01T00:00:00Z"},
             %{id: "c3", body: "", resolved_at: nil}
           ]

    # Multi-page walk: the workpad sits on page 2 and must still be surfaced
    # so `DeterministicFailure.find_workpad_comment/1` appends to the workpad
    # instead of posting a standalone blocker (IDE-103).
    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "comments" => %{
                 "nodes" => [
                   %{"id" => "page1-c1", "body" => "first", "resolvedAt" => nil},
                   %{"id" => "page1-c2", "body" => "second", "resolvedAt" => nil}
                 ],
                 "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-page-2"}
               }
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "comments" => %{
                 "nodes" => [
                   %{
                     "id" => "page2-workpad",
                     "body" => "## Symphony Workpad\n\nlives on page 2",
                     "resolvedAt" => nil
                   },
                   %{"id" => "page2-tail", "body" => "last", "resolvedAt" => nil}
                 ],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => "cursor-end"}
               }
             }
           }
         }}
      ]
    )

    assert {:ok, paginated} = Adapter.fetch_comments("issue-1")

    assert_receive {:graphql_called, _page1_query, %{first: 50, issueId: "issue-1", after: nil}}

    assert_receive {:graphql_called, _page2_query, %{first: 50, issueId: "issue-1", after: "cursor-page-2"}}

    assert paginated == [
             %{id: "page1-c1", body: "first", resolved_at: nil},
             %{id: "page1-c2", body: "second", resolved_at: nil},
             %{id: "page2-workpad", body: "## Symphony Workpad\n\nlives on page 2", resolved_at: nil},
             %{id: "page2-tail", body: "last", resolved_at: nil}
           ]

    assert Enum.any?(paginated, &(&1.id == "page2-workpad")),
           "workpad on page 2 must be surfaced once pagination is in effect"

    # `hasNextPage: true` with a missing/empty `endCursor` is treated as a
    # malformed Linear response — surface a clean error rather than looping
    # forever or silently dropping pages.
    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [%{"id" => "c", "body" => "", "resolvedAt" => nil}],
               "pageInfo" => %{"hasNextPage" => true, "endCursor" => nil}
             }
           }
         }
       }}
    )

    assert {:error, :linear_missing_end_cursor} = Adapter.fetch_comments("issue-1")

    # Transport failure on a later page propagates so callers don't act on a
    # partial result.
    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{
               "comments" => %{
                 "nodes" => [%{"id" => "p1", "body" => "ok", "resolvedAt" => nil}],
                 "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-2"}
               }
             }
           }
         }},
        {:error, :transport_down}
      ]
    )

    assert {:error, :transport_down} = Adapter.fetch_comments("issue-1")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{"issue" => nil}}})
    assert {:error, :comments_fetch_failed} = Adapter.fetch_comments("issue-1")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :transport_down})
    assert {:error, :transport_down} = Adapter.fetch_comments("issue-1")

    # A `comments` payload with no `pageInfo` key at all is treated as terminal
    # (defensive fallback for a Linear response missing pagination metadata):
    # the single page is returned and the walk stops without another call.
    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [%{"id" => "solo", "body" => "no page info", "resolvedAt" => nil}]
             }
           }
         }
       }}
    )

    assert {:ok, [%{id: "solo", body: "no page info", resolved_at: nil}]} =
             Adapter.fetch_comments("issue-1")

    # update_comment/2: happy path + GraphQL error + success:false +
    # malformed-payload fallback.
    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.update_comment("comment-1", "edited")
    assert_receive {:graphql_called, update_comment_query, %{body: "edited", id: "comment-1"}}
    assert update_comment_query =~ "commentUpdate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => false}}}}
    )

    assert {:error, :comment_update_failed} = Adapter.update_comment("comment-1", "edited")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :transport_down})
    assert {:error, :transport_down} = Adapter.update_comment("comment-1", "edited")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_update_failed} = Adapter.update_comment("comment-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_update_failed} = Adapter.update_comment("comment-1", "odd")
  end

  test "linear adapter caps fetch_comments pagination at @max_comment_pages and stops calling the client" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    # `fetch_comments/1` uses its own, more generous comment-specific cap
    # (`@max_comment_pages`, 2500 comments at a 50-row page size) rather than
    # the shared `Pagination.max_pages()` budget — a single busy issue can
    # legitimately carry hundreds of comments (IDE-110).
    max_pages = Adapter.max_comment_pages()
    assert max_pages > Pagination.max_pages()

    advancing_response = fn cursor ->
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [%{"id" => "c-#{cursor}", "body" => "x", "resolvedAt" => nil}],
               "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor-#{cursor}"}
             }
           }
         }
       }}
    end

    # Server keeps advertising another page with a *new* cursor every call:
    # this is the cap path (no stuck-cursor short-circuit), so the cap must fire
    # after exactly `@max_comment_pages` GraphQL calls — never more. Pre-seed
    # enough distinct responses; if the paginator overshoots it falls back to
    # the `nil` default response and the assert messages would surface that.
    # Both pagination guards collapse into a single loud error so the
    # deterministic-failure escalation path sees one signal (IDE-110).
    responses = Enum.map(1..(max_pages + 5), &advancing_response.(&1))
    Process.put({FakeLinearClient, :graphql_results}, responses)
    Process.put({FakeLinearClient, :graphql_result}, nil)

    assert {:error, :comment_pagination_exceeded} = Adapter.fetch_comments("issue-1")

    for _ <- 1..max_pages do
      assert_receive {:graphql_called, _query, %{issueId: "issue-1"}}
    end

    refute_receive {:graphql_called, _query, %{issueId: "issue-1"}}, 50

    # A non-advancing (stuck) `endCursor` — Linear returns `hasNextPage: true`
    # with the SAME cursor repeatedly — must short-circuit on the second call,
    # well before the cap, and surface the same unified error.
    stuck_cursor_response =
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "comments" => %{
               "nodes" => [%{"id" => "stuck-c", "body" => "x", "resolvedAt" => nil}],
               "pageInfo" => %{"hasNextPage" => true, "endCursor" => "STUCK"}
             }
           }
         }
       }}

    Process.put({FakeLinearClient, :graphql_results}, List.duplicate(stuck_cursor_response, max_pages + 5))
    Process.put({FakeLinearClient, :graphql_result}, nil)

    assert {:error, :comment_pagination_exceeded} = Adapter.fetch_comments("issue-2")

    assert_receive {:graphql_called, _query, %{issueId: "issue-2", after: nil}}
    assert_receive {:graphql_called, _query, %{issueId: "issue-2", after: "STUCK"}}
    refute_receive {:graphql_called, _query, %{issueId: "issue-2"}}, 50
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "agent_kind" => "codex",
             "linear_project" => "project",
             "hero_tint" => state_payload["hero_tint"],
             "counts" => %{
               "running" => 1,
               "retrying" => 1,
               "blocked" => 1,
               "dependency_blocked" => 1
             },
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "agent_kind" => "codex",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "blocked" => [
               %{
                 "issue_id" => "issue-blocked",
                 "issue_identifier" => "MT-BLOCKED",
                 "state" => "In Progress",
                 "error" => "codex turn requires operator input",
                 "worker_host" => "dm-dev2",
                 "workspace_path" => "/workspaces/MT-BLOCKED",
                 "session_id" => "thread-blocked",
                 "blocked_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("blocked_at"),
                 "last_event" => "turn_input_required",
                 "last_message" => "turn blocked: waiting for user input",
                 "last_event_at" => state_payload["blocked"] |> List.first() |> Map.fetch!("last_event_at")
               }
             ],
             "dependency_blocked" => [
               %{
                 "issue_id" => "issue-dep",
                 "issue_identifier" => "MT-DEP",
                 "title" => "Waiting on the upstream migration",
                 "state" => "Todo",
                 "blocked_by" => [
                   %{
                     "issue_id" => "issue-upstream",
                     "issue_identifier" => "MT-UP",
                     "state" => "In Progress"
                   }
                 ],
                 "observed_at" => state_payload["dependency_blocked"] |> List.first() |> Map.fetch!("observed_at")
               }
             ],
             "dependency_graph" => %{
               "nodes" => [
                 %{
                   "id" => "issue-dep",
                   "issue_identifier" => "MT-DEP",
                   "title" => "Waiting on the upstream migration",
                   "state" => "Todo",
                   "state_type" => "unstarted",
                   "priority" => 3,
                   "priority_label" => "Medium",
                   "url" => "https://linear.app/example/MT-DEP",
                   "placeholder" => false,
                   "symphony_status" => "waiting_on_blockers",
                   "symphony_status_label" => "Waiting on blockers"
                 },
                 %{
                   "id" => "issue-upstream",
                   "issue_identifier" => "MT-UP",
                   "title" => "Upstream migration",
                   "state" => "In Progress",
                   "state_type" => "started",
                   "priority" => 2,
                   "priority_label" => "High",
                   "url" => "https://linear.app/example/MT-UP",
                   "placeholder" => false,
                   "symphony_status" => nil,
                   "symphony_status_label" => nil
                 }
               ],
               "edges" => [
                 %{"source" => "issue-upstream", "target" => "issue-dep"}
               ]
             },
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "claude_totals" => %{
               "input_tokens" => 0,
               "output_tokens" => 0,
               "total_tokens" => 0,
               "cache_creation_input_tokens" => 0,
               "cache_read_input_tokens" => 0,
               "seconds_running" => 0
             },
             "provider_quotas" => %{},
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "agent_kind" => "codex",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "blocked" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-BLOCKED")

    assert %{
             "status" => "blocked",
             "last_error" => "codex turn requires operator input",
             "blocked" => %{
               "session_id" => "thread-blocked",
               "state" => "In Progress",
               "error" => "codex turn requires operator input"
             }
           } = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api exposes claude tokens with cache fields and claude_totals" do
    snapshot = static_claude_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ClaudeObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    [running_entry | _] = state_payload["running"]

    assert running_entry["agent_kind"] == "claude"

    assert running_entry["tokens"] == %{
             "input_tokens" => 100,
             "output_tokens" => 50,
             "total_tokens" => 150,
             "cache_creation_input_tokens" => 10,
             "cache_read_input_tokens" => 200
           }

    assert state_payload["claude_totals"] == %{
             "input_tokens" => 100,
             "output_tokens" => 50,
             "total_tokens" => 150,
             "cache_creation_input_tokens" => 10,
             "cache_read_input_tokens" => 200,
             "seconds_running" => 0
           }

    issue_payload = json_response(get(build_conn(), "/api/v1/MT-CLAUDE"), 200)
    assert issue_payload["running"]["agent_kind"] == "claude"

    assert issue_payload["running"]["tokens"] == %{
             "input_tokens" => 100,
             "output_tokens" => 50,
             "total_tokens" => 150,
             "cache_creation_input_tokens" => 10,
             "cache_read_input_tokens" => 200
           }
  end

  test "dashboard liveview branches Total tokens panel on agent.kind for claude with cache sublabel" do
    previous_kind = Application.get_env(:symphony_elixir, :agent_kind_override)

    on_exit(fn ->
      if is_nil(previous_kind) do
        Application.delete_env(:symphony_elixir, :agent_kind_override)
      else
        Application.put_env(:symphony_elixir, :agent_kind_override, previous_kind)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(), agent_kind: "claude")
    if Process.whereis(WorkflowStore), do: WorkflowStore.force_reload()

    snapshot = static_claude_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ClaudeDashboardOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)
    ensure_workflow_store_running()

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Total tokens"
    # Total = input + output (codex parity), excludes cache fields.
    assert html =~ "150"
    # Cache sublabel uses created N · read N.
    assert html =~ "Cache: created 10"
    assert html =~ "read 200"
    # Per-issue token row also exposes cache fields.
    assert html =~ "MT-CLAUDE"
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/dashboard.js"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    assert html =~ "/vendor/cytoscape/cytoscape.min.js"
    assert html =~ "/vendor/dagre/dagre.min.js"
    assert html =~ "/vendor/cytoscape-dagre/cytoscape-dagre.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ ".graph-canvas"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"

    for path <- [
          "/dashboard.js",
          "/vendor/cytoscape/cytoscape.min.js",
          "/vendor/dagre/dagre.min.js",
          "/vendor/cytoscape-dagre/cytoscape-dagre.js"
        ] do
      conn = get(build_conn(), path)
      assert conn.status == 200, "expected 200 for #{path}, got #{conn.status}"

      assert conn |> Plug.Conn.get_resp_header("content-type") |> List.first() =~ "application/javascript",
             "expected application/javascript content-type for #{path}"
    end

    dashboard_js = response(get(build_conn(), "/dashboard.js"), 200)
    assert dashboard_js =~ "SymphonyHooks"
    assert dashboard_js =~ "DependencyGraph"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "MT-BLOCKED"
    assert html =~ "rendered"
    assert html =~ "turn blocked: waiting for user input"
    assert html =~ "--hero-tint-bg:"
    assert html =~ "--hero-tint-border:"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Agent update"
    assert html =~ "Waiting on blockers"
    assert html =~ "Dependency graph"
    assert html =~ "MT-DEP"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200

    assert response.body["counts"] == %{
             "running" => 1,
             "retrying" => 1,
             "blocked" => 1,
             "dependency_blocked" => 1
           }

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    observed_at = DateTime.utc_now()

    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          blocked_at: DateTime.utc_now(),
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: DateTime.utc_now()
          },
          last_codex_timestamp: DateTime.utc_now()
        }
      ],
      dependency_blocked: [
        %{
          issue_id: "issue-dep",
          identifier: "MT-DEP",
          title: "Waiting on the upstream migration",
          state: "Todo",
          blocked_by: [
            %{id: "issue-upstream", identifier: "MT-UP", state: "In Progress"}
          ],
          observed_at: observed_at
        }
      ],
      dependency_graph: [
        %{
          issue_id: "issue-dep",
          id: "issue-dep",
          identifier: "MT-DEP",
          title: "Waiting on the upstream migration",
          state: "Todo",
          state_type: "unstarted",
          priority: 3,
          url: "https://linear.app/example/MT-DEP",
          blocked_by: [
            %{id: "issue-upstream", identifier: "MT-UP", state: "In Progress"}
          ],
          placeholder: false,
          symphony_status: :waiting_on_blockers
        },
        %{
          issue_id: "issue-upstream",
          id: "issue-upstream",
          identifier: "MT-UP",
          title: "Upstream migration",
          state: "In Progress",
          state_type: "started",
          priority: 2,
          url: "https://linear.app/example/MT-UP",
          blocked_by: [],
          placeholder: false,
          symphony_status: nil
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp static_claude_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-claude-http",
          identifier: "MT-CLAUDE",
          state: "In Progress",
          session_id: "claude-http",
          turn_count: 1,
          agent_kind: :claude,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :turn_completed,
          claude_input_tokens: 100,
          claude_output_tokens: 50,
          claude_total_tokens: 150,
          claude_cache_creation_input_tokens: 10,
          claude_cache_read_input_tokens: 200,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      claude_totals: %{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        cache_creation_input_tokens: 10,
        cache_read_input_tokens: 200,
        seconds_running: 0
      },
      rate_limits: nil
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
