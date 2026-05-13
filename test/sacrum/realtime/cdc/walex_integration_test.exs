defmodule Sacrum.Realtime.Cdc.WalExIntegrationTest do
  use ExUnit.Case, async: false

  import Sacrum.CdcAssertions

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Users
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    committed_db(&cleanup_committed_cdc_rows/0)

    slot = "sacrum_cdc_test_#{System.unique_integer([:positive])}"

    config =
      Sacrum.Realtime.Cdc.Config.walex_config()
      |> Keyword.put(:slot_name, slot)
      |> Keyword.put(:durable_slot, false)

    {:ok, walex} = start_supervised({WalEx.Supervisor, config})

    on_exit(fn ->
      if Process.alive?(walex), do: Process.exit(walex, :normal)
    end)

    :ok
  end

  test "committed task inserts, updates, and deletes are projected to default clients" do
    committed_db(fn ->
      {user, project} = create_project()

      try do
        :ok = subscribe_project(project.id)

        {:ok, task} = Tasks.insert(project, %{title: "CDC task"})

        assert_project_broadcast(
          "task_created",
          %{
            id: task.id,
            title: "CDC task",
            project_id: project.id
          },
          1_000
        )

        {:ok, updated_task} = Tasks.update(task, %{title: "CDC task updated"})

        assert_project_broadcast(
          "task_updated",
          %{
            id: task.id,
            title: "CDC task updated",
            project_id: project.id
          },
          1_000
        )

        {:ok, _deleted_task} = Tasks.delete(updated_task)

        assert_project_broadcast(
          "task_deleted",
          %{
            id: task.id
          },
          1_000
        )
      after
        cleanup_user(user.id)
      end
    end)
  end

  test "committed execution status and public chat events are projected" do
    committed_db(fn ->
      {user, project} = create_project()

      try do
        {:ok, task} = Tasks.insert(project, %{title: "CDC execution"})
        {:ok, session} = Accounts.LiveChat.create_session(user.id, project.id, %{})

        {:ok, execution} =
          %StepExecution{user_id: user.id, task_id: task.id, project_id: project.id}
          |> StepExecution.create_changeset(%{
            task_id: task.id,
            step_name: "run",
            status: "started"
          })
          |> Repo.insert()

        :ok = subscribe_project(project.id)

        {:ok, _updated_execution} =
          execution
          |> StepExecution.update_changeset(%{status: "completed"})
          |> Repo.update()

        assert_project_broadcast(
          "step_execution_status_changed",
          %{
            id: execution.id,
            status: "completed",
            project_id: project.id
          },
          1_000
        )

        {:ok, chat_event} =
          Accounts.ChatEvents.append(user.id, project.id, session.id, %{
            event_type: "runner.progress",
            visibility: :public,
            public_payload: %{"message" => "done"},
            internal_payload: %{}
          })

        assert_project_broadcast(
          "chat_event_created",
          %{
            id: chat_event.id,
            project_id: project.id,
            payload: %{"message" => "done"}
          },
          1_000
        )
      after
        cleanup_user(user.id)
      end
    end)
  end

  defp committed_db(fun) do
    Sandbox.unboxed_run(Repo, fun)
  end

  defp create_project do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "real-cdc-#{suffix}@example.com",
        username: "real_cdc_#{suffix}",
        password: "password123"
      })

    {:ok, project} = Projects.insert(user, %{name: "Real CDC #{suffix}"})

    drain_project_broadcasts()

    {user, project}
  end

  defp drain_project_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{} -> drain_project_broadcasts()
    after
      0 -> :ok
    end
  end

  defp cleanup_user(user_id) do
    user_id
    |> project_ids_for_user()
    |> Enum.each(&cleanup_project/1)

    Repo.query!("DELETE FROM users WHERE id = $1", [uuid_param(user_id)])
  end

  defp cleanup_committed_cdc_rows do
    %{rows: rows} =
      Repo.query!("SELECT id FROM users WHERE email LIKE 'real-cdc-%@example.com'", [])

    rows
    |> List.flatten()
    |> Enum.each(&cleanup_user/1)
  end

  defp project_ids_for_user(user_id) do
    %{rows: rows} =
      Repo.query!("SELECT id FROM projects WHERE user_id = $1", [uuid_param(user_id)])

    List.flatten(rows)
  end

  defp cleanup_project(project_id) do
    project_id = uuid_param(project_id)

    Repo.query!(
      """
      UPDATE task_runs
      SET latest_step_execution_id = NULL,
          triggered_by_step_execution_id = NULL
      WHERE project_id = $1
      """,
      [project_id]
    )

    Repo.query!("UPDATE step_executions SET task_run_id = NULL WHERE project_id = $1", [
      project_id
    ])

    for table <- [
          "session_logs",
          "chat_events",
          "chat_messages",
          "chat_sessions",
          "code_refs",
          "task_sections",
          "task_dependencies",
          "step_transitions",
          "workflow_transitions",
          "task_runs",
          "step_executions",
          "tasks",
          "workflow_steps",
          "workflows"
        ] do
      Repo.query!("DELETE FROM #{table} WHERE project_id = $1", [project_id])
    end

    Repo.query!("DELETE FROM projects WHERE id = $1", [project_id])
  end

  defp uuid_param(<<_::128>> = id), do: id

  defp uuid_param(id) do
    {:ok, uuid} = Ecto.UUID.dump(id)
    uuid
  end
end
