defmodule Sacrum.Accounts.SessionLogs.IngestionTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.SessionLogs
  alias Sacrum.Accounts.SessionLogs.UsageRollups
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
    assert [%SessionLog{id: ^id}] = Repo.all(SessionLog)
    refute_received %Phoenix.Socket.Broadcast{}

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

    stop_ingestion(context.execution.id)

    assert {:ok, _} = ingest(context, HarnessFixture.text("late", "delta", "!"))
    refute_received %Phoenix.Socket.Broadcast{}

    assert {:ok, _} =
             ingest(
               context,
               usage_event("codex-2", "snapshot", 3, %{"turn_delta" => usage(1, 0, 1)})
             )

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

  test "a delta writes nothing and only process start reads history", context do
    assert {:ok, _} = ingest(context, HarnessFixture.text("first", "delta", "a"))

    queries =
      capture_queries(context, fn ->
        assert {:ok, _} = ingest(context, HarnessFixture.text("second", "delta", "b"))
      end)

    assert [authorization] = queries
    assert authorization =~ ~s(FROM "step_executions")

    queries =
      capture_queries(context, fn ->
        assert {:ok, _} = ingest(context, HarnessFixture.text("final", "snapshot", "ab"))
      end)

    refute Enum.any?(queries, &(&1 =~ ~s("format" = 'harness')))
    assert Enum.count(queries, &(&1 =~ ~r/^INSERT/)) == 1
  end

  defp ingest(context, event) do
    SessionLogs.insert(context.user.id, Map.put(event, :step_execution_id, context.execution.id))
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
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sacrum, :repo, :query],
        fn _, _, metadata, _ -> send(owner, {:query, self(), metadata.query}) end,
        nil
      )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    pids = [owner, ingestion_pid(context.execution.id)]

    for {pid, query} <- received_queries([]),
        pid in pids,
        not Regex.match?(~r/^(begin|commit|savepoint|release)/i, query),
        do: query
  end

  defp received_queries(queries) do
    receive do
      {:query, pid, query} -> received_queries([{pid, query} | queries])
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
