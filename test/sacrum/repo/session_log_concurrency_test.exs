defmodule Sacrum.Repo.SessionLogConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Repo
  alias Sacrum.Repo.{Projects, SessionLogs, StepExecutions, Tasks, Users, Workflows}
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  test "independent connections serialize concurrent retries and out-of-order usage" do
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
    owner = self()
    events = [event("high", 8, 80), event("low", 2, 20), event("high", 8, 80)]

    supervisor = start_supervised!({Task.Supervisor, []})

    writers =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, writers} =
          Repo.transaction(fn ->
            Repo.one!(
              from execution in StepExecution,
                where: execution.id == ^context.execution.id,
                lock: "FOR UPDATE"
            )

            writers =
              Enum.map(events, fn event ->
                Task.Supervisor.async_nolink(supervisor, fn ->
                  Sandbox.unboxed_run(Repo, fn ->
                    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
                    send(owner, {:ready, self(), backend})

                    receive do
                      :write -> :ok
                    end

                    SessionLogs.insert(context.user.id, %{
                      project_id: context.project.id,
                      step_execution_id: context.execution.id,
                      logical_key: "harness:" <> event["event_id"],
                      content: Jason.encode!(event)
                    })
                  end)
                end)
              end)

            backends =
              for writer <- writers do
                pid = writer.pid
                assert_receive {:ready, ^pid, backend}, 5_000
                backend
              end

            assert length(Enum.uniq(backends)) == 3
            Enum.each(writers, &send(&1.pid, :write))
            await_blocked(backends, System.monotonic_time(:millisecond) + 5_000)
            writers
          end)

        writers
      end)

    results = Enum.map(writers, &Task.await(&1, 10_000))
    assert Enum.all?(results, &match?({:ok, %SessionLog{}}, &1))

    Sandbox.unboxed_run(Repo, fn ->
      logs = SessionLogs.all(conditions: [step_execution_id: context.execution.id])
      assert Enum.sort(Enum.map(logs, & &1.logical_key)) == ["harness:high", "harness:low"]
      execution = Repo.get!(StepExecution, context.execution.id)
      assert execution.session_input_tokens == 100
      assert execution.session_cache_read_input_tokens == 4
      assert execution.session_output_tokens == 6
      assert execution.session_total_tokens == 106
      assert execution.context_window_input_tokens == 80
      assert execution.context_window_cache_read_input_tokens == 2
      assert execution.context_window_total_tokens == 83
    end)
  end

  defp await_blocked(backends, deadline) do
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1) AND wait_event_type = 'Lock'",
        [backends]
      )

    if count != length(backends) do
      assert System.monotonic_time(:millisecond) < deadline,
             "writers did not all contend on execution lock"

      await_blocked(backends, deadline)
    end
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
