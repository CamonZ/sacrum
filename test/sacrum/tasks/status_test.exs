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

  describe "derive/1 - ready state" do
    test "returns :ready for task with current_step_id and no active StepExecution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      assert Status.derive(task) == :ready
    end

    test "returns :ready when task is on a step but no execution yet created" do
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

  describe "derive/1 - running state" do
    test "returns :running when latest StepExecution is started" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      # Create a started execution
      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "started"
        })

      assert Status.derive(task) == :running
    end

    test "returns :running when latest StepExecution is in_progress" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "in_progress"
        })

      assert Status.derive(task) == :running
    end
  end

  describe "derive/1 - waiting state" do
    test "returns :waiting when latest StepExecution is waiting" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow, %{step_type: "wait_children"})

      task = create_task(user, project, workflow, step)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "waiting"
        })

      assert Status.derive(task) == :waiting
    end

    test "blockers do not affect status — task with running blocker remains :ready" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)
      blocker_task = create_task(user, project, workflow, step)

      {:ok, _dep} = Repo.TaskDependencies.add_dependency(task, blocker_task)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(blocker_task.user_id, %{
          task_id: blocker_task.id,
          project_id: blocker_task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "started"
        })

      assert Status.derive(task) == :ready
    end
  end

  describe "derive/1 - failed state" do
    test "returns :failed when latest StepExecution is failed" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "failed"
        })

      assert Status.derive(task) == :failed
    end

    test "does not derive as :ready when execution is failed" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "failed"
        })

      assert Status.derive(task) != :ready
    end
  end

  describe "derive/1 - done state" do
    test "returns :done when on final step of terminal workflow with completed execution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{is_final: true})
      final_step = create_step(workflow, %{is_final: true})

      task = create_task(user, project, workflow, final_step)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: final_step.id,
          step_name: final_step.name,
          status: "completed"
        })

      assert Status.derive(task) == :done
    end

    test "does not return :done when not on final step despite completed execution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      non_final_step = create_step(workflow, %{is_final: false})

      task = create_task(user, project, workflow, non_final_step)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: non_final_step.id,
          step_name: non_final_step.name,
          status: "completed"
        })

      assert Status.derive(task) != :done
    end

    test "does not return :done when on final step but execution not completed" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      final_step = create_step(workflow, %{is_final: true})

      task = create_task(user, project, workflow, final_step)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: final_step.id,
          step_name: final_step.name,
          status: "started"
        })

      assert Status.derive(task) != :done
    end

    test "does not return :done when on final step of non-terminal workflow" do
      user = create_user()
      project = create_project(user)
      wf1 = create_workflow(user, project, %{name: "WF1", is_final: false})
      wf2 = create_workflow(user, project, %{name: "WF2"})

      final_step_wf1 = create_step(wf1, %{is_final: true})

      {:ok, _transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          from_workflow_id: wf1.id,
          to_workflow_id: wf2.id,
          project_id: project.id
        })

      task = create_task(user, project, wf1, final_step_wf1)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: wf1.id,
          step_id: final_step_wf1.id,
          step_name: final_step_wf1.name,
          status: "completed"
        })

      assert Status.derive(task) != :done
    end
  end

  describe "derive/1 - done state safety" do
    test "returns :done even when current step has outgoing step transitions" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{is_final: true})

      mistakenly_final = create_step(workflow, %{is_final: true})
      next_step = create_step(workflow)

      {:ok, _transition} =
        Accounts.StepTransitions.insert(user.id, %{
          from_step_id: mistakenly_final.id,
          to_step_id: next_step.id,
          project_id: project.id
        })

      task = create_task(user, project, workflow, mistakenly_final)

      {:ok, _execution} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: mistakenly_final.id,
          step_name: mistakenly_final.name,
          status: "completed"
        })

      assert Status.derive(task) == :done
    end
  end

  describe "multiple execution histories" do
    test "uses the latest StepExecution when multiple exist" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      # Create first execution (completed)
      {:ok, _first} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "completed"
        })

      # Wait a moment to ensure different timestamps
      Process.sleep(10)

      # Create second execution (started) — this should be considered latest
      {:ok, _second} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "started"
        })

      # Should be running (latest is started)
      assert Status.derive(task) == :running
    end
  end

  describe "refresh/1" do
    test "writes the derived status to the column" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(workflow)

      task = create_task(user, project, workflow, step)

      {:ok, _} =
        Accounts.StepExecutions.insert(task.user_id, %{
          task_id: task.id,
          project_id: task.project_id,
          workflow_id: workflow.id,
          step_id: step.id,
          step_name: step.name,
          status: "started"
        })

      {:ok, refreshed} = Status.refresh(task)
      assert refreshed.status == "running"
      assert Repo.get!(Task, task.id).status == "running"
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
