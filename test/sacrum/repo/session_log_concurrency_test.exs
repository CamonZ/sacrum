defmodule Sacrum.Repo.SessionLogConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Accounts
  alias Sacrum.Accounts.SessionLogs.Ingestion
  alias Sacrum.Repo
  alias Sacrum.Repo.{Projects, SessionLogs, StepExecutions, Tasks, Users, Workflows}
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  test "ingestion accepts and broadcasts without the execution row lock and rolls up out-of-order usage" do
    context =
      Sandbox.unboxed_run(Repo, fn ->
        unique = System.unique_integer([:positive])

        {:ok, user} =
          Users.insert(%{
            email: "race-#{unique}@example.com",
            username: "race_#{unique}",
            password: "password123"
          })

        {:ok, project} = Projects.insert(user, %{name: "race"})
        {:ok, _workflow} = Workflows.insert(project, %{name: "Default"})
        {:ok, task} = Tasks.insert(project.id, user.id, %{title: "race"})

        {:ok, execution} =
          StepExecutions.insert(user.id, %{
            project_id: project.id,
            task_id: task.id,
            step_name: "race"
          })

        %{user: user, project: project, execution: execution}
      end)

    on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> Repo.delete!(context.user) end) end)
    :ok = SacrumWeb.Endpoint.subscribe("project:#{context.project.id}")
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:sacrum, :repo, :query],
        fn _, _, metadata, _ -> send(owner, {:query, metadata.query}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    events = [
      event("high", 8, 80),
      event("low", 2, 20),
      event("high", 8, 80),
      event("tool", 1, nil),
      event("later", 9, 30)
    ]

    supervisor = start_supervised!({Task.Supervisor, []})

    callers =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, callers} =
          Repo.transaction(fn ->
            # Another session holds the execution row; ingestion must not need it
            # to accept, broadcast or reply.
            Repo.one!(
              from execution in StepExecution,
                where: execution.id == ^context.execution.id,
                lock: "FOR UPDATE"
            )

            callers =
              Enum.map(events, fn event ->
                Task.Supervisor.async_nolink(supervisor, fn ->
                  Sandbox.unboxed_run(Repo, fn ->
                    result =
                      Accounts.SessionLogs.insert(context.user.id, %{
                        step_execution_id: context.execution.id,
                        logical_key: "harness:" <> event["event_id"],
                        content: Jason.encode!(event)
                      })

                    send(owner, {:replied, self(), result})

                    # Writes run on the latest caller's behalf; stay alive until
                    # they are flushed.
                    receive do
                      :done -> result
                    end
                  end)
                end)
              end)

            replies =
              for caller <- callers do
                pid = caller.pid
                assert_receive {:replied, ^pid, result}, 5_000
                result
              end

            assert Enum.all?(replies, &match?({:ok, %SessionLog{}}, &1))

            for _accepted <- 1..4 do
              assert_receive %Phoenix.Socket.Broadcast{event: "session_log_created"}, 1_000
            end

            refute_received %Phoenix.Socket.Broadcast{event: "session_log_created"}
            callers
          end)

        callers
      end)

    assert Ingestion.flush(context.execution.id, 5_000) == :flushed
    Enum.each(callers, &send(&1.pid, :done))
    Enum.each(callers, &Task.await(&1, 5_000))

    queries = collect_queries([])
    assert Enum.any?(queries, &(&1 =~ ~r/^UPDATE "step_executions"/))
    assert Enum.count(queries, &(&1 =~ "FOR UPDATE")) == 1

    Sandbox.unboxed_run(Repo, fn ->
      logs = SessionLogs.all(conditions: [step_execution_id: context.execution.id])

      assert Enum.sort(Enum.map(logs, & &1.logical_key)) ==
               ["harness:high", "harness:later", "harness:low", "harness:tool"]

      execution = Repo.get!(StepExecution, context.execution.id)
      assert execution.session_input_tokens == 130
      assert execution.session_cache_read_input_tokens == 6
      assert execution.session_output_tokens == 9
      assert execution.session_total_tokens == 139
      assert execution.context_window_input_tokens == 30
      assert execution.context_window_cache_read_input_tokens == 2
      assert execution.context_window_total_tokens == 33
    end)
  end

  defp collect_queries(queries) do
    receive do
      {:query, query} -> collect_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp event(id, sequence, nil) do
    %{
      "version" => 1,
      "event_id" => id,
      "stream_id" => "race",
      "sequence" => sequence,
      "timestamp" => "2026-10-04T00:00:00Z",
      "semantics" => "snapshot",
      "type" => "tool_call",
      "correlation" => %{"tool_call_id" => id},
      "data" => %{"name" => "bash"}
    }
  end

  defp event(id, sequence, input) do
    usage = %{
      tokens: %{
        input_tokens: input,
        cached_input_tokens: 2,
        output_tokens: 3,
        reasoning_tokens: 1
      },
      cost_microusd: 5
    }

    %{
      "version" => 1,
      "event_id" => id,
      "stream_id" => "race",
      "sequence" => sequence,
      "timestamp" => "2026-10-04T00:00:00Z",
      "semantics" => "snapshot",
      "type" => "usage",
      "correlation" => %{},
      "data" => %{turn_delta: usage, session_snapshot: usage}
    }
  end
end
