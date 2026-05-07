defmodule Sacrum.Tasks.StatusTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Tasks.Status

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Repo.Users.insert(attrs)
    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
    project
  end

  defp create_workflow(user, project, attrs \\ %{}) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, Map.merge(%{name: "Test Workflow"}, attrs))

    workflow
  end

  defp create_step(workflow, attrs \\ %{}) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(workflow, Map.merge(%{name: "Test Step"}, attrs))

    step
  end

  defp create_task(user, project, workflow \\ nil, current_step \\ nil) do
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Test Task"})

    task
    |> maybe_assign_workflow(workflow)
    |> maybe_advance_to_step(current_step)
  end

  defp maybe_assign_workflow(task, nil), do: task

  defp maybe_assign_workflow(task, workflow) do
    {:ok, _} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)
    Repo.get!(Task, task.id)
  end

  defp maybe_advance_to_step(task, nil), do: task

  defp maybe_advance_to_step(task, step) do
    {:ok, _} =
      Sacrum.Repo.TaskWorkflows.advance_to_step(task, step.id, skip_orchestrator_check: true)

    Repo.get!(Task, task.id)
  end

  defp insert_execution(task, workflow, step, status, attrs \\ %{}) do
    Accounts.StepExecutions.insert(
      task.user_id,
      Map.merge(
        %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: status
        },
        attrs
      )
    )
  end

  defp mark_completed(task) do
    {:ok, completed} = Accounts.Tasks.update(task, %{completed_at: DateTime.utc_now()})
    completed
  end

  describe "derive/1 - ready state" do
    test "returns :ready for task with current_step_id and no StepExecution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      assert Status.derive(task) == :ready
    end

    test "returns :ready for newly inserted task (auto-assigned default workflow)" do
      user = create_user()
      project = create_project(user)
      task = create_task(user, project)

      assert Status.derive(task) == :ready
    end
  end

  describe "derive/1 - automation lifecycle split" do
    test "does not derive running or waiting task status from active StepExecution states" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      for status <- ["started", "in_progress", "cancelling", "waiting"] do
        task = create_task(user, project, workflow, step)

        {:ok, execution} = insert_execution(task, workflow, step, status)

        assert execution.status == status
        assert Status.derive(task) == :ready
      end
    end

    test "keeps transient failed attempts out of durable task status" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)
      task = create_task(user, project, workflow, step)

      {:ok, task_run} =
        Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})

      {:ok, failed_attempt} =
        insert_execution(task, workflow, step, "failed", %{task_run_id: task_run.id})

      assert failed_attempt.status == "failed"
      assert task_run.status == :executing
      assert Status.derive(task) == :ready
    end

    test "does not infer task completion from a completed StepExecution alone" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{is_final: true})
      final_step = create_step(workflow, %{is_final: true})
      task = create_task(user, project, workflow, final_step)

      {:ok, completed_attempt} = insert_execution(task, workflow, final_step, "completed")

      assert completed_attempt.status == "completed"
      assert task.completed_at == nil
      assert Status.derive(task) == :ready
    end
  end

  describe "derive/1 - done state" do
    test "returns :done when task completion has been stamped" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{is_final: true})
      final_step = create_step(workflow, %{is_final: true})

      task =
        user
        |> create_task(project, workflow, final_step)
        |> mark_completed()

      assert task.completed_at != nil
      assert Status.derive(task) == :done
    end

    test "stays :done when the latest historical StepExecution failed after completion" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{is_final: true})
      final_step = create_step(workflow, %{is_final: true})

      task =
        user
        |> create_task(project, workflow, final_step)
        |> mark_completed()

      {:ok, completed_attempt} = insert_execution(task, workflow, final_step, "completed")
      {:ok, failed_attempt} = insert_execution(task, workflow, final_step, "failed")

      assert completed_attempt.status == "completed"
      assert failed_attempt.status == "failed"
      assert Status.derive(task) == :done
    end
  end

  describe "refresh/1" do
    test "writes ready instead of running for a started StepExecution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      {:ok, _} = insert_execution(task, workflow, step, "started")

      {:ok, refreshed} = Status.refresh(task)
      assert refreshed.status == "ready"
      assert Repo.get!(Task, task.id).status == "ready"
    end

    test "writes done when task completion has been stamped" do
      user = create_user()
      project = create_project(user)

      task =
        user
        |> create_task(project)
        |> mark_completed()

      {:ok, refreshed} = Status.refresh(task)
      assert refreshed.status == "done"
      assert Repo.get!(Task, task.id).status == "done"
    end
  end

  describe "workflow assignment on insert" do
    test "auto-assigns the project's default workflow when none is given" do
      user = create_user()
      project = create_project(user)

      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Auto-assigned Task"})

      assert task.workflow_id != nil
      assert task.current_step_id != nil
    end

    test "respects explicit workflow_id and current_step_id" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      {:ok, task} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "Task with explicit workflow",
          workflow_id: workflow.id,
          current_step_id: step.id
        })

      assert task.workflow_id == workflow.id
      assert task.current_step_id == step.id
    end
  end
end
