defmodule Sacrum.Orchestrator.TaskRuns.RetryExhaustionTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{Projects, StepExecutions, TaskRuns, Tasks, Workflows}
  alias Sacrum.Orchestrator.TaskRuns.RetryExhaustion
  alias Sacrum.Repo.Users

  test "changeset stores retry outcome metadata without copying execution output" do
    task_run = task_run_struct()
    execution = failed_execution_struct(task_run, %{output: "daemon error"})

    changed =
      task_run
      |> RetryExhaustion.changeset(execution, %{
        failed_execution_id: execution.id,
        task_id: task_run.task_id,
        current_step_id: execution.step_id,
        current_attempt: 5,
        max_attempts: 5
      })
      |> Ecto.Changeset.apply_changes()

    assert changed.status == :failed
    assert changed.latest_step_execution_id == execution.id
    assert changed.outcome_kind == "retry_exhausted"
    assert changed.outcome_context["failed_execution_id"] == execution.id
    assert changed.outcome_context["task_id"] == task_run.task_id
    assert changed.outcome_context["current_step_id"] == execution.step_id
    assert changed.outcome_context["current_attempt"] == 5
    assert changed.outcome_context["max_attempts"] == 5
    assert changed.outcome_context["execution_found"]
    refute Map.has_key?(changed.outcome_context, "output_preview")
  end

  test "mark scopes failed execution lookup to the task run" do
    user = create_user()
    {project, task, workflow} = create_task_with_workflow(user)
    {:ok, task_run} = TaskRuns.insert(user.id, project.id, task.id)
    {:ok, other_task_run} = TaskRuns.insert(user.id, project.id, task.id)

    {:ok, other_run_attempt} =
      StepExecutions.insert(user.id, %{
        "task_id" => task.id,
        "task_run_id" => other_task_run.id,
        "project_id" => project.id,
        "workflow_id" => workflow.id,
        "step_name" => "retryable_step",
        "status" => "failed"
      })

    assert {:ok, exhausted} =
             RetryExhaustion.mark(task_run, other_run_attempt.id, %{
               task_id: task.id,
               current_step_id: other_run_attempt.step_id,
               current_attempt: 5,
               max_attempts: 5
             })

    assert exhausted.status == :failed
    assert exhausted.latest_step_execution_id == nil
    assert exhausted.outcome_context["failed_execution_id"] == other_run_attempt.id
    assert exhausted.outcome_context["execution_found"] == false
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "task-runs-retry-#{suffix}@example.com",
        username: "taskrunsretry#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task_with_workflow(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Retry Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Retry Workflow"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Retry Task"})

    {project, task, workflow}
  end

  defp task_run_struct(attrs \\ %{}) do
    Map.merge(
      %Sacrum.Repo.Schemas.TaskRun{
        id: Ecto.UUID.generate(),
        task_id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        status: :executing
      },
      attrs
    )
  end

  defp failed_execution_struct(task_run, attrs) do
    Map.merge(
      %Sacrum.Repo.Schemas.StepExecution{
        id: Ecto.UUID.generate(),
        task_run_id: task_run.id,
        task_id: task_run.task_id,
        project_id: task_run.project_id,
        step_id: Ecto.UUID.generate(),
        step_name: "retryable_step",
        status: "failed"
      },
      attrs
    )
  end
end
