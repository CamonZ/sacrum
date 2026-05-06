defmodule Sacrum.Orchestrator.TaskRuns.FailureTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{Projects, TaskRuns, Tasks}
  alias Sacrum.Orchestrator.TaskRuns.Failure
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.TaskRun
  alias Sacrum.Repo.Users

  test "mark_if_active marks stoppable runs failed with normalized outcome context" do
    user = create_user()
    {_project, task} = create_task(user)
    {:ok, task_run} = TaskRuns.insert(user.id, task.project_id, task.id, %{status: :executing})

    assert {:ok, failed_run} =
             Failure.mark_if_active(task_run, {:dispatch_failed, :not_found}, %{
               current_execution_id: Ecto.UUID.generate()
             })

    assert failed_run.status == :failed
    assert failed_run.ended_at
    assert failed_run.outcome_kind == "dispatch_failed"
    assert failed_run.outcome_context["reason"] == "not_found"
    assert failed_run.outcome_context["current_execution_id"]
  end

  test "mark_if_active leaves non-stoppable runs unchanged" do
    user = create_user()
    {_project, task} = create_task(user)
    {:ok, task_run} = TaskRuns.insert(user.id, task.project_id, task.id, %{status: :stopping})

    assert {:ok, :unchanged} = Failure.mark_if_active(task_run, :dispatch_failed)

    reloaded = Repo.get!(TaskRun, task_run.id)
    assert reloaded.status == :stopping
    assert reloaded.outcome_kind == nil
    assert reloaded.outcome_context == %{}
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "task-runs-failure-#{suffix}@example.com",
        username: "taskrunsfailure#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Failure Project"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Failure Task"})

    {project, task}
  end
end
