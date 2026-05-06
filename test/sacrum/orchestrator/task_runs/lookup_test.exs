defmodule Sacrum.Orchestrator.TaskRuns.LookupTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{Projects, TaskRuns, Tasks}
  alias Sacrum.Orchestrator.TaskRuns.Lookup
  alias Sacrum.Repo.Users

  test "fetch returns an existing task run by id" do
    user = create_user()
    {_project, task} = create_task(user)
    {:ok, task_run} = TaskRuns.insert(user.id, task.project_id, task.id)

    assert {:ok, found} = Lookup.fetch(task_run.id)
    assert found.id == task_run.id
  end

  test "fetch returns task_run_not_found for unknown ids" do
    assert {:error, :task_run_not_found} = Lookup.fetch(Ecto.UUID.generate())
  end

  test "fetch_active_for_task returns only active runs" do
    user = create_user()
    {_project, task} = create_task(user)
    {:ok, _completed} = TaskRuns.insert(user.id, task.project_id, task.id, %{status: :completed})
    {:ok, active} = TaskRuns.insert(user.id, task.project_id, task.id, %{status: :waiting})

    assert {:ok, found} = Lookup.fetch_active_for_task(task.id)
    assert found.id == active.id
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "task-runs-lookup-#{suffix}@example.com",
        username: "taskrunslookup#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Lookup Project"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Lookup Task"})

    {project, task}
  end
end
