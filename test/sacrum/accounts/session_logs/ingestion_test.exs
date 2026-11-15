defmodule Sacrum.Accounts.SessionLogs.IngestionTest do
  use Sacrum.DataCase, async: true

  import ExUnit.CaptureLog

  alias Sacrum.Accounts.{SessionLogs, StepExecutions}
  alias Sacrum.Accounts.SessionLogs.{Ingestion, UsageRollups}
  alias Sacrum.HarnessFixture
  alias Sacrum.Realtime.ProjectChannelCdcContract
  alias Sacrum.Repo.{Projects, Tasks, Users, Workflows}
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  setup do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "ingestion-#{unique}@example.com",
        username: "ingestion_#{unique}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user, %{name: "Ingestion #{unique}"})
    {:ok, _workflow} = Workflows.insert(project, %{name: "Default"})
    {:ok, task} = Tasks.insert(project.id, user.id, %{title: "Ingestion"})

    {:ok, execution} =
      Sacrum.Repo.StepExecutions.insert(user.id, %{
        project_id: project.id,
        task_id: task.id,
        step_name: "execute"
      })

    :ok = SacrumWeb.Endpoint.subscribe("project:#{project.id}")
    %{user: user, project: project, execution: execution}
  end

  test "text deltas need an item id and text", context do
    for event <- [
          HarnessFixture.text("no-item", "delta", "a", item_id: nil),
          HarnessFixture.text("empty-item", "delta", "a", item_id: ""),
          HarnessFixture.text("no-text", "delta", nil)
        ] do
      assert {:error, changeset} = ingest(context, event)
      assert %{content: [_]} = errors_on(changeset)
    end

    refute_received %Phoenix.Socket.Broadcast{}

    assert {:ok, _log} =
             ingest(context, HarnessFixture.text("bare-snapshot", "snapshot", "a", item_id: nil))

    flush(context)
  end

  test "a delta is published with the projected log shape and not stored", context do
    delta = HarnessFixture.text("delta", "delta", "Hel")
    assert {:ok, log} = ingest(context, delta)

    assert_received %Phoenix.Socket.Broadcast{event: "session_log_created", payload: payload}
    {:ok, contract} = ProjectChannelCdcContract.contract_for("session_log_created")
    assert Enum.sort(Map.keys(payload)) == Enum.sort(contract.payload_keys)

    assert %{
             id: log_id,
             step_execution_id: execution_id,
             project_id: project_id,
             content: content,
             logical_key: logical_key,
             format: "harness"
           } = payload

    assert {log_id, execution_id, project_id} ==
             {log.id, context.execution.id, context.project.id}

    assert {content, logical_key} == {delta.content, delta.logical_key}
    assert Repo.aggregate(SessionLog, :count) == 0
  end

  test "each snapshot finalizes only its own item and later deltas for it are dropped",
       context do
    for {id, stream, item} <- [{"a1", "s1", "a"}, {"a2", "s2", "a"}, {"b1", "s1", "b"}] do
      assert {:ok, _} =
               ingest(
                 context,
                 HarnessFixture.text(id, "delta", id, stream_id: stream, item_id: item)
               )

      assert_received %Phoenix.Socket.Broadcast{event: "session_log_created"}
    end

    snapshot = HarnessFixture.text("a-final", "snapshot", "a1", stream_id: "s1", item_id: "a")
    assert {:ok, %SessionLog{id: id}} = ingest(context, snapshot)

    assert_received %Phoenix.Socket.Broadcast{
      event: "session_log_created",
      payload: %{id: ^id}
    }

    flush(context)
    assert [%SessionLog{id: ^id}] = Repo.all(SessionLog)

    assert {:ok, _} =
             ingest(
               context,
               HarnessFixture.text("a-late", "delta", "!", stream_id: "s1", item_id: "a")
             )

    refute_received %Phoenix.Socket.Broadcast{}

    for {id, stream, item} <- [{"a3", "s2", "a"}, {"b2", "s1", "b"}] do
      assert {:ok, _} =
               ingest(
                 context,
                 HarnessFixture.text(id, "delta", id, stream_id: stream, item_id: item)
               )

      assert_received %Phoenix.Socket.Broadcast{event: "session_log_created"}
    end
  end

  test "a restarted process seeds totals and finalized items from persisted logs", context do
    claude_terminal =
      usage_event("claude", "delta", 1, %{"turn_delta" => usage(10, 4, 3)})

    codex_usage =
      usage_event("codex", "snapshot", 2, %{
        "turn_delta" => usage(5, 1, 2),
        "session_snapshot" => Map.put(usage(40, 8, 6), "context_tokens", 48)
      })

    assert {:ok, _} = ingest(context, claude_terminal)
    assert {:ok, _} = ingest(context, codex_usage)
    assert {:ok, _} = ingest(context, HarnessFixture.text("final", "snapshot", "done"))

    flush(context)
    stop_ingestion(context.execution.id)
    drain_broadcasts()

    assert {:ok, _} = ingest(context, HarnessFixture.text("late", "delta", "!"))
    refute_received %Phoenix.Socket.Broadcast{}

    assert {:ok, _} =
             ingest(
               context,
               usage_event("codex-2", "snapshot", 3, %{"turn_delta" => usage(1, 0, 1)})
             )

    flush(context)
    execution = Repo.get!(StepExecution, context.execution.id)

    assert {execution.session_input_tokens, execution.session_cache_read_input_tokens,
            execution.session_output_tokens, execution.session_total_tokens} == {16, 5, 6, 22}

    assert {execution.context_window_input_tokens,
            execution.context_window_cache_read_input_tokens,
            execution.context_window_total_tokens} == {40, 8, 48}

    recomputed =
      Repo.all(SessionLog)
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.reduce(UsageRollups.new(), &UsageRollups.add(&2, &1))
      |> UsageRollups.attrs()

    assert Map.take(execution, Map.keys(recomputed)) == recomputed
  end

  test "the reply never waits on a write; only process start reads history", context do
    assert {:ok, _} = ingest(context, HarnessFixture.text("first", "delta", "a"))

    queries =
      capture_queries(context, fn ->
        assert {:ok, _} = ingest(context, HarnessFixture.text("second", "delta", "b"))
      end)

    assert [authorization] = queries
    assert authorization =~ ~s(FROM "step_executions")

    {reply_path, writes} =
      capture_queries(context, [:writers], fn ->
        assert {:ok, _} = ingest(context, HarnessFixture.text("final", "snapshot", "ab"))
        flush(context)
      end)

    assert [authorization] = reply_path
    assert authorization =~ ~s(FROM "step_executions")
    assert [insert, counters] = writes
    assert insert =~ ~r/^INSERT INTO "session_logs"/
    assert counters =~ ~r/^UPDATE "step_executions"/
    refute Enum.any?(reply_path ++ writes, &(&1 =~ "FOR UPDATE"))
  end

  test "every event is broadcast with its row id in acceptance order", context do
    events = [
      HarnessFixture.text("d1", "delta", "He"),
      usage_event("u1", "snapshot", 1, %{"turn_delta" => usage(3, 1, 2)}),
      HarnessFixture.text("d2", "delta", "llo"),
      tool_event("t1"),
      HarnessFixture.text("final", "snapshot", "Hello"),
      usage_event("u2", "snapshot", 2, %{"turn_delta" => usage(4, 0, 1)})
    ]

    replies =
      for event <- events do
        assert {:ok, %SessionLog{} = log} = ingest(context, event)
        log
      end

    broadcasts =
      for _event <- events do
        assert_received %Phoenix.Socket.Broadcast{event: "session_log_created", payload: payload}
        payload
      end

    assert Enum.map(broadcasts, & &1.logical_key) == Enum.map(events, & &1.logical_key)
    assert Enum.map(broadcasts, & &1.id) == Enum.map(replies, & &1.id)
    assert broadcasts == Enum.sort_by(broadcasts, & &1.inserted_at, DateTime)

    flush(context)
    persisted = Map.new(Repo.all(SessionLog), &{&1.logical_key, &1})
    assert map_size(persisted) == 4

    for broadcast <- broadcasts, stored = persisted[broadcast.logical_key] do
      assert {stored.id, stored.inserted_at} == {broadcast.id, broadcast.inserted_at}
    end

    execution = Repo.get!(StepExecution, context.execution.id)
    assert {execution.session_input_tokens, execution.session_output_tokens} == {7, 3}
  end

  test "redelivery of an accepted event replies with it and is not broadcast again", context do
    event = tool_event("tool")
    assert {:ok, %SessionLog{id: id}} = ingest(context, event)
    assert_received %Phoenix.Socket.Broadcast{event: "session_log_created"}

    assert {:ok, %SessionLog{id: ^id}} = ingest(context, event)
    refute_received %Phoenix.Socket.Broadcast{}

    conflicting = %{event | content: String.replace(event.content, "\"ls\"", "\"rm\"")}
    assert {:error, :event_identity_conflict} = ingest(context, conflicting)

    flush(context)
    stop_ingestion(context.execution.id)
    assert {:ok, %SessionLog{id: ^id}} = ingest(context, event)
    refute_received %Phoenix.Socket.Broadcast{}
    assert [%SessionLog{id: ^id}] = Repo.all(SessionLog)
  end

  test "a status change waits until accepted events are persisted", context do
    Repo.query!(
      "ALTER TABLE session_logs ADD CONSTRAINT injected_write_failure CHECK (logical_key <> 'harness:blocked')"
    )

    capture_log(fn ->
      assert {:ok, _} =
               ingest(
                 context,
                 usage_event("blocked", "snapshot", 1, %{"turn_delta" => usage(5, 1, 2)})
               )

      owner = self()

      update =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
          StepExecutions.update(context.execution, %{status: "completed"})
        end)

      refute Task.yield(update, 300)
      assert Repo.get!(StepExecution, context.execution.id).status != "completed"

      Repo.query!("ALTER TABLE session_logs DROP CONSTRAINT injected_write_failure")

      assert {:ok, %StepExecution{status: "completed"} = execution} = Task.await(update)
      assert execution.session_input_tokens == 5
      assert [%SessionLog{logical_key: "harness:blocked"}] = Repo.all(SessionLog)
    end)
  end

  describe "items" do
    test "a tool item is stored once it completes, as its final state only", context do
      events = [
        harness(
          "call",
          "tool_call",
          "snapshot",
          tool("t1", "started", %{"input" => %{"cmd" => "ls"}})
        ),
        HarnessFixture.text("d1", "delta", "Lis"),
        harness(
          "progress",
          "tool_output",
          "delta",
          tool("t1", "running", %{"output" => %{"kind" => "progress"}})
        ),
        HarnessFixture.text("d2", "delta", "ting"),
        harness("partial", "tool_output", "snapshot", tool("t1", "running", %{"output" => "a"})),
        HarnessFixture.text("answer", "snapshot", "Listing")
      ]

      replies = Map.new(events, &{&1.logical_key, elem(ingest(context, &1), 1)})

      for _event <- events do
        assert_received %Phoenix.Socket.Broadcast{event: "session_log_created"}
      end

      # The text item completed; the tool item is still open and nothing of it
      # is stored.
      settle(context)
      assert stored_keys() == ["harness:answer"]

      done =
        harness("done", "tool_output", "snapshot", tool("t1", "completed", %{"output" => "a b"}))

      assert {:ok, done_log} = ingest(context, done)
      settle(context)

      # Final state: the latest tool_call and the completing tool_output; the
      # superseded running snapshot and every delta are never stored.
      assert stored_keys() == ["harness:call", "harness:answer", "harness:done"]

      for %SessionLog{logical_key: key} = stored <- Repo.all(SessionLog) do
        expected = Map.get(replies, key, done_log)
        assert {stored.id, stored.inserted_at} == {expected.id, expected.inserted_at}
      end

      late = harness("late", "tool_output", "delta", tool("t1", "running", %{"output" => "x"}))
      drain_broadcasts()
      assert {:ok, _} = ingest(context, late)
      refute_received %Phoenix.Socket.Broadcast{}
    end

    test "a stream's terminal event stores the items still open on that stream", context do
      ingest!(context, harness("a", "tool_call", "snapshot", tool("ta", "started"), stream: "s1"))
      ingest!(context, harness("b", "tool_call", "snapshot", tool("tb", "started"), stream: "s2"))

      log =
        capture_log(fn ->
          ingest!(
            context,
            harness("end", "turn_finished", "snapshot", %{"status" => "completed"}, stream: "s1")
          )

          settle(context)
          assert stored_keys() == ["harness:a", "harness:end"]

          # The other stream's item stays open until it completes or is flushed,
          # and is stored where it was accepted.
          flush(context)
          assert stored_keys() == ["harness:a", "harness:b", "harness:end"]
        end)

      assert log =~ ~s(unfinished harness item {:tool, "s1", "ta"} at s1 terminal event)
      assert log =~ ~s(unfinished harness item {:tool, "s2", "tb"} at flush)
    end

    test "flush stores open items before a status change is applied", context do
      ingest!(context, harness("open", "tool_call", "snapshot", tool("t1", "started")))
      settle(context)
      assert stored_keys() == []

      log =
        capture_log(fn ->
          assert {:ok, %StepExecution{status: "completed"}} =
                   StepExecutions.update(context.execution, %{status: "completed"})
        end)

      assert log =~ "Storing unfinished harness item"
      assert stored_keys() == ["harness:open"]
    end

    test "a restarted process treats stored completed tool items as complete", context do
      ingest!(context, harness("call", "tool_call", "snapshot", tool("t1", "started")))

      ingest!(
        context,
        harness("done", "tool_output", "snapshot", tool("t1", "failed", %{"output" => "boom"}))
      )

      flush(context)
      stop_ingestion(context.execution.id)
      drain_broadcasts()

      ingest!(context, harness("late", "tool_output", "delta", tool("t1", "running")))
      refute_received %Phoenix.Socket.Broadcast{}
    end
  end

  defp ingest(context, event) do
    SessionLogs.insert(context.user.id, Map.put(event, :step_execution_id, context.execution.id))
  end

  defp ingest!(context, event) do
    assert {:ok, log} = ingest(context, event)
    log
  end

  defp stored_keys do
    SessionLog |> order_by(:inserted_at) |> Repo.all() |> Enum.map(& &1.logical_key)
  end

  # Wait until every completed unit is stored without closing open items.
  defp settle(context), do: assert(Ingestion.drain(context.execution.id) == :flushed)

  defp tool(id, status, extra \\ %{}),
    do: Map.merge(%{"tool_call_id" => id, "name" => "bash", "status" => status}, extra)

  defp harness(id, type, semantics, data, opts \\ []) do
    content =
      Jason.encode!(%{
        version: 1,
        event_id: id,
        stream_id: Keyword.get(opts, :stream, "fixture"),
        sequence: 1,
        timestamp: "2026-10-04T00:00:00Z",
        semantics: semantics,
        type: type,
        correlation: %{},
        data: data
      })

    %{logical_key: "harness:" <> id, content: content}
  end

  defp flush(context), do: assert(Ingestion.flush(context.execution.id) == :flushed)

  defp drain_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{} -> drain_broadcasts()
    after
      0 -> :ok
    end
  end

  defp ingestion_pid(execution_id) do
    [{pid, _value}] =
      Registry.lookup(Sacrum.Accounts.SessionLogs.IngestionRegistry, execution_id)

    pid
  end

  defp stop_ingestion(execution_id) do
    :ok = GenServer.stop(ingestion_pid(execution_id))
  end

  defp capture_queries(context, fun) do
    {queries, []} = capture_queries(context, [], fun)
    queries
  end

  # Statements from the caller and the ingestion process; with `[:writers]`,
  # also returns the statements of writer tasks separately.
  defp capture_queries(context, include, fun) do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sacrum, :repo, :query],
        fn _, _, metadata, _ ->
          send(owner, {:query, self(), Process.get(:"$callers", []), metadata.query})
        end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    ingestion = ingestion_pid(context.execution.id)

    statements =
      for {pid, callers, query} <- received_queries([]),
          not Regex.match?(~r/^(begin|commit|savepoint|release)/i, query),
          source = query_source(pid, callers, owner, ingestion),
          do: {source, query}

    reply_path = for {:reply_path, query} <- statements, do: query
    writes = if :writers in include, do: for({:writer, query} <- statements, do: query), else: []

    if include == [], do: {reply_path, []}, else: {reply_path, writes}
  end

  defp query_source(pid, callers, owner, ingestion) do
    cond do
      pid in [owner, ingestion] -> :reply_path
      ingestion in callers -> :writer
      true -> nil
    end
  end

  defp received_queries(queries) do
    receive do
      {:query, pid, callers, query} -> received_queries([{pid, callers, query} | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp usage_event(id, semantics, sequence, data) do
    content =
      Jason.encode!(%{
        version: 1,
        event_id: id,
        stream_id: "usage",
        sequence: sequence,
        timestamp: "2026-10-04T00:00:00Z",
        semantics: semantics,
        type: "usage",
        correlation: %{},
        data: data
      })

    %{logical_key: "harness:" <> id, content: content}
  end

  defp tool_event(id) do
    content =
      Jason.encode!(%{
        version: 1,
        event_id: id,
        stream_id: "tools",
        sequence: 1,
        timestamp: "2026-10-04T00:00:00Z",
        semantics: "snapshot",
        type: "tool_call",
        correlation: %{tool_call_id: id},
        data: %{name: "bash", input: %{command: "ls"}}
      })

    %{logical_key: "harness:" <> id, content: content}
  end

  defp usage(input, cached, output) do
    %{
      "tokens" => %{
        "input_tokens" => input,
        "cached_input_tokens" => cached,
        "output_tokens" => output
      }
    }
  end
end
