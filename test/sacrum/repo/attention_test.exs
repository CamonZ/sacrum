defmodule Sacrum.Repo.AttentionTest do
  use Sacrum.DataCase

  import Sacrum.Repo.Attention
  import SacrumWeb.ConnCase, only: [create_user: 1]

  alias Sacrum.Repo.{Projects, StepExecutions, Tasks, Workflows, WorkflowSteps}

  describe "attention rows for four causes" do
    setup do
      # Create a user
      user = create_user(%{username: "testuser"})

      # Create a project
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})

      # Create a workflow with multiple step types
      {:ok, workflow} =
        Workflows.insert(project, %{
          name: "Test Workflow",
          user_id: user.id
        })

      # Create various workflow steps
      {:ok, execute_step} =
        WorkflowSteps.insert(workflow, %{
          name: "Execute Step",
          step_type: "execute",
          step_order: 1
        })

      {:ok, wait_children_step} =
        WorkflowSteps.insert(workflow, %{
          name: "Gate Step",
          step_type: "wait_children",
          step_order: 2
        })

      {:ok, final_step} =
        WorkflowSteps.insert(workflow, %{
          name: "Final Step",
          step_type: "execute",
          is_final: true,
          step_order: 3
        })

      {
        :ok,
        user: user,
        project: project,
        workflow: workflow,
        execute_step: execute_step,
        wait_children_step: wait_children_step,
        final_step: final_step
      }
    end

    test "failed_runs: returns task with failed step execution", %{
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step
    } do
      # Create a task
      {:ok, task} = Tasks.insert(project, %{title: "Failed Task", user_id: user.id})

      # Create a failed step execution
      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "failed"
        })

      rows = failed_runs(project.id)

      assert length(rows) == 1
      row = hd(rows)
      assert row.cause == :failed
      assert row.task_id == task.id
      assert row.task_title == "Failed Task"
      assert row.project_name == "Test Project"
      assert row.workflow_name == "Test Workflow"
      assert row.step_name == "Execute Step"
      assert row.detail == "step: Execute Step (failed)"
      assert row.triggered_at != nil
    end

    test "gates_awaiting_input: returns task in wait_children step with pending status", %{
      user: user,
      project: project,
      workflow: workflow,
      wait_children_step: wait_children_step
    } do
      # Create a task
      {:ok, task} = Tasks.insert(project, %{title: "Gate Task", user_id: user.id})

      # Create a pending step execution in a wait_children step
      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          step_id: wait_children_step.id,
          project_id: project.id,
          step_name: "Gate Step",
          status: "pending"
        })

      rows = gates_awaiting_input(project.id)

      assert length(rows) == 1
      row = hd(rows)
      assert row.cause == :gate
      assert row.task_id == task.id
      assert row.task_title == "Gate Task"
      assert row.project_name == "Test Project"
      assert row.workflow_name == "Test Workflow"
      assert row.step_name == "Gate Step"
      assert row.detail == "awaiting your approval"
    end

    test "context_window_pressure: returns task with high token count execution", %{
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step
    } do
      # Create a task
      {:ok, task} = Tasks.insert(project, %{title: "CTX Task", user_id: user.id})

      # Create a step execution with high token count (>100k)
      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "completed",
          input_tokens: 60_000,
          output_tokens: 45_000
        })

      rows = context_window_pressure(project.id)

      assert length(rows) == 1
      row = hd(rows)
      assert row.cause == :context_pressure
      assert row.task_id == task.id
      assert row.task_title == "CTX Task"
      assert row.project_name == "Test Project"
      assert row.workflow_name == "Test Workflow"
      assert row.step_name == "Execute Step"
      assert row.detail =~ "105.0k tok"
    end

    test "context_window_pressure: formats tokens correctly for million threshold", %{
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step
    } do
      # Create a task with high token count in millions
      {:ok, task_1m} = Tasks.insert(project, %{title: "1M Task", user_id: user.id})

      # 1.5M tokens
      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task_1m.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "completed",
          input_tokens: 1_000_000,
          output_tokens: 500_000
        })

      rows = context_window_pressure(project.id)

      assert length(rows) == 1
      row = hd(rows)
      assert row.detail =~ "1.5M tok"
    end
  end

  describe "get_rows: unified query" do
    setup do
      user = create_user(%{username: "testuser"})
      {:ok, project} = Projects.insert(user, %{name: "Test Project"})

      {:ok, workflow} =
        Workflows.insert(project, %{
          name: "Test Workflow",
          user_id: user.id
        })

      {:ok, execute_step} =
        WorkflowSteps.insert(workflow, %{
          name: "Execute Step",
          step_type: "execute",
          step_order: 1
        })

      {:ok, wait_children_step} =
        WorkflowSteps.insert(workflow, %{
          name: "Gate Step",
          step_type: "wait_children",
          step_order: 2
        })

      {
        :ok,
        user: user,
        project: project,
        workflow: workflow,
        execute_step: execute_step,
        wait_children_step: wait_children_step
      }
    end

    test "returns one row per UoW + cause combination", %{
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step,
      wait_children_step: wait_children_step
    } do
      # Create tasks
      {:ok, failed_task} = Tasks.insert(project, %{title: "Failed", user_id: user.id})
      {:ok, gate_task} = Tasks.insert(project, %{title: "Gate", user_id: user.id})

      # Create executions
      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: failed_task.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "failed"
        })

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: gate_task.id,
          workflow_id: workflow.id,
          step_id: wait_children_step.id,
          project_id: project.id,
          step_name: "Gate Step",
          status: "pending"
        })

      rows = get_rows(project.id)

      assert length(rows) == 2

      # Check both causes are present
      causes = Enum.map(rows, & &1.cause)
      assert :failed in causes
      assert :gate in causes
    end

    test "orders rows by recency (most recent first)", %{
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step
    } do
      # Create two tasks
      {:ok, task1} = Tasks.insert(project, %{title: "Task 1", user_id: user.id})
      {:ok, task2} = Tasks.insert(project, %{title: "Task 2", user_id: user.id})

      # Create executions with specific timestamps
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -3600, :second)

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task1.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "failed",
          inserted_at: earlier
        })

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task2.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "failed",
          inserted_at: now
        })

      rows = get_rows(project.id)

      assert length(rows) == 2
      # First row should be the most recent (task2)
      assert hd(rows).task_id == task2.id
    end

    test "filters by project_id when provided", %{
      user: user,
      project: project,
      workflow: workflow,
      execute_step: execute_step
    } do
      # Create another project
      {:ok, other_project} = Projects.insert(user, %{name: "Other Project"})

      {:ok, other_workflow} =
        Workflows.insert(other_project, %{
          name: "Other Workflow",
          user_id: user.id
        })

      {:ok, other_step} =
        WorkflowSteps.insert(other_workflow, %{
          name: "Other Step",
          step_type: "execute",
          step_order: 1
        })

      # Create task in first project
      {:ok, task1} = Tasks.insert(project, %{title: "Project 1 Task", user_id: user.id})

      # Create task in other project
      {:ok, task2} = Tasks.insert(other_project, %{title: "Project 2 Task", user_id: user.id})

      # Create failed executions for both
      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task1.id,
          workflow_id: workflow.id,
          step_id: execute_step.id,
          project_id: project.id,
          step_name: "Execute Step",
          status: "failed"
        })

      {:ok, _} =
        StepExecutions.insert(user.id, %{
          task_id: task2.id,
          workflow_id: other_workflow.id,
          step_id: other_step.id,
          project_id: other_project.id,
          step_name: "Other Step",
          status: "failed"
        })

      # Get rows for first project only
      rows = get_rows(project.id)

      # Should only have task from project 1
      task_ids = Enum.map(rows, & &1.task_id)
      assert task1.id in task_ids
      refute task2.id in task_ids
    end

    test "returns empty list when no attention rows exist", %{project: project} do
      rows = get_rows(project.id)

      assert rows == []
    end
  end

  describe "dead_orchestrator_runs" do
    test "returns empty list (not yet implemented)" do
      rows = dead_orchestrator_runs()

      assert rows == []
    end
  end
end
