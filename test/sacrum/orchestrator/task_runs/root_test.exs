defmodule Sacrum.Orchestrator.TaskRuns.RootTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{Projects, TaskRuns, Tasks}
  alias Sacrum.Orchestrator.TaskRuns.Root
  alias Sacrum.Repo.Users

  test "get_or_create creates a queued root run when no active run exists" do
    user = create_user()
    {_project, task} = create_task(user)

    assert {:ok, task_run} = Root.get_or_create(task)
    assert task_run.status == :queued
    assert task_run.task_id == task.id
    assert task_run.project_id == task.project_id
    assert task_run.user_id == user.id
    assert task_run.parent_task_run_id == nil
    assert task_run.root_task_run_id == nil
  end

  test "get_or_create reuses an active root run" do
    user = create_user()
    {_project, task} = create_task(user)

    {:ok, existing_run} =
      TaskRuns.insert(user.id, task.project_id, task.id, %{status: :executing})

    assert {:ok, task_run} = Root.get_or_create(task)
    assert task_run.id == existing_run.id
  end

  test "validate_dispatchable rejects terminal runs" do
    user = create_user()
    {_project, task} = create_task(user)

    {:ok, completed_run} =
      TaskRuns.insert(user.id, task.project_id, task.id, %{status: :completed})

    assert {:error, {:task_run_not_dispatchable, :completed}} =
             Root.validate_dispatchable(completed_run)
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "task-runs-root-#{suffix}@example.com",
        username: "taskrunsroot#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Root Project"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Root Task"})

    {project, task}
  end
end
