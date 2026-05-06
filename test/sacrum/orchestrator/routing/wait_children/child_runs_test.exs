defmodule Sacrum.Orchestrator.Routing.WaitChildren.ChildRunsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.{Projects, StepExecutions, TaskRuns, Tasks, Workflows}
  alias Sacrum.Orchestrator.Routing.WaitChildren.ChildRuns
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.TaskRun
  alias Sacrum.Repo.Users

  test "get_or_create creates a queued child run with parent lineage" do
    user = create_user()
    {project, parent_task, workflow} = create_task_with_workflow(user)
    {:ok, child_task} = Tasks.insert(user.id, project.id, %{title: "Child Task"})
    {:ok, parent_run} = TaskRuns.insert(user.id, project.id, parent_task.id)
    {:ok, trigger_execution} = waiting_execution(user, project, workflow, parent_task, parent_run)

    assert {:ok, child_run} =
             ChildRuns.get_or_create(child_task, parent_run, trigger_execution.id)

    assert child_run.status == :queued
    assert child_run.parent_task_run_id == parent_run.id
    assert child_run.root_task_run_id == parent_run.id
    assert child_run.triggered_by_step_execution_id == trigger_execution.id
  end

  test "get_or_create rejects a manual child root run" do
    user = create_user()
    {project, parent_task, workflow} = create_task_with_workflow(user)
    {:ok, child_task} = Tasks.insert(user.id, project.id, %{title: "Manual Child"})
    {:ok, parent_run} = TaskRuns.insert(user.id, project.id, parent_task.id)
    {:ok, manual_child_run} = TaskRuns.insert(user.id, project.id, child_task.id)
    {:ok, trigger_execution} = waiting_execution(user, project, workflow, parent_task, parent_run)

    assert {:error, {:child_task_run_has_manual_root, manual_child_run_id}} =
             ChildRuns.get_or_create(child_task, parent_run, trigger_execution.id)

    assert manual_child_run_id == manual_child_run.id

    reloaded = Repo.get!(TaskRun, manual_child_run.id)
    assert reloaded.parent_task_run_id == nil
    assert reloaded.root_task_run_id == nil
    assert reloaded.triggered_by_step_execution_id == nil
  end

  test "get_or_create rejects active child runs from a stale trigger" do
    user = create_user()
    {project, parent_task, workflow} = create_task_with_workflow(user)
    {:ok, child_task} = Tasks.insert(user.id, project.id, %{title: "Stale Child"})
    {:ok, parent_run} = TaskRuns.insert(user.id, project.id, parent_task.id)
    {:ok, old_trigger} = waiting_execution(user, project, workflow, parent_task, parent_run)
    {:ok, current_trigger} = waiting_execution(user, project, workflow, parent_task, parent_run)

    {:ok, stale_child_run} =
      TaskRuns.insert(user.id, project.id, child_task.id, %{
        status: :queued,
        parent_task_run_id: parent_run.id,
        root_task_run_id: parent_run.id,
        triggered_by_step_execution_id: old_trigger.id
      })

    assert {:error, {:child_task_run_lineage_conflict, stale_child_run_id}} =
             ChildRuns.get_or_create(child_task, parent_run, current_trigger.id)

    assert stale_child_run_id == stale_child_run.id
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Users.insert(%{
        email: "child-runs-#{suffix}@example.com",
        username: "childruns#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_task_with_workflow(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Child Runs Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Child Runs Workflow"})
    {:ok, task} = Tasks.insert(user.id, project.id, %{title: "Parent Task"})

    {project, task, workflow}
  end

  defp waiting_execution(user, project, workflow, task, task_run) do
    StepExecutions.insert(user.id, %{
      "task_id" => task.id,
      "task_run_id" => task_run.id,
      "project_id" => project.id,
      "workflow_id" => workflow.id,
      "step_name" => "wait_children",
      "status" => "waiting"
    })
  end
end
