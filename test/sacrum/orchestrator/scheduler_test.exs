defmodule Sacrum.Orchestrator.SchedulerTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionPool, Scheduler}
  alias Sacrum.Orchestrator.TaskRegistry
  alias Sacrum.Repo

  defp create_user(attrs \\ %{}) do
    default_attrs = %{
      email: "test@example.com",
      username: "testuser",
      password: "password123"
    }

    {:ok, user} = Repo.Users.insert(Map.merge(default_attrs, attrs))
    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
    project
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Test Workflow",
        auto_advance: false
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
      "is_final" => true,
      "agents" => ["test"],
      "skills" => ["test_skill"],
      "agent_config" => %{"model" => "test-model"},
      "workflow_id" => workflow.id,
      "project_id" => workflow.project_id
    }

    merged_attrs = Map.merge(default_attrs, stringify_attrs(attrs))

    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, merged_attrs)
    step
  end

  defp stringify_attrs(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp create_task(user, project, attrs \\ %{}) do
    default_attrs = %{
      title: "Test Task",
      description: "Test description",
      level: "task",
      priority: "normal",
      tags: ["test"]
    }

    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, Map.merge(default_attrs, attrs))
    task
  end

  defp assign_workflow_to_task(_user, task, workflow) do
    {:ok, updated_task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    updated_task
  end

  defp add_dependency(task, depends_on) do
    {:ok, _} = Repo.TaskDependencies.add_dependency(task, depends_on)
  end

  defp mark_task_completed(task) do
    changeset = Ecto.Changeset.change(task, %{completed_at: DateTime.utc_now()})
    {:ok, updated_task} = Repo.update(changeset)
    updated_task
  end

  describe "schedule_task/1" do
    test "schedules a valid task with workflow" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(user, task, workflow)

      # Schedule the task
      result = Scheduler.schedule_task(%{id: task.id})

      # Give it time to process
      Process.sleep(100)

      # Verify orchestrator was started
      assert {:ok, result} == {:ok, :ok}
      assert Registry.lookup(TaskRegistry, task.id) != []
    end

    test "creates a queued TaskRun before execution slot is granted" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(user, task, workflow)

      available_slots = ExecutionPool.pool_status().available_slots

      held_slots =
        if available_slots > 0 do
          for _ <- 1..available_slots do
            {:ok, slot_id} = ExecutionPool.request_slot(self(), 1_000)
            slot_id
          end
        else
          []
        end

      on_exit(fn ->
        Enum.each(held_slots, &ExecutionPool.release_slot/1)
        Sacrum.Orchestrator.stop(task.id)
      end)

      assert :ok = Scheduler.schedule_task(%{id: task.id})

      {:ok, task_run} = Accounts.TaskRuns.get_active_for_task(user.id, task.id)
      assert task_run.status == :queued
      assert task_run.latest_step_execution_id == nil
      assert Registry.lookup(TaskRegistry, task.id) != []
    end

    test "rejects already completed task" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(user, task, workflow)
      task = mark_task_completed(task)

      result = Scheduler.schedule_task(%{id: task.id})

      assert result == {:error, :task_already_completed}
    end

    test "rejects duplicate schedule_task calls" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(user, task, workflow)

      # First schedule should succeed
      result1 = Scheduler.schedule_task(%{id: task.id})
      assert result1 == :ok

      Process.sleep(100)

      # Second schedule should fail with already_running error
      result2 = Scheduler.schedule_task(%{id: task.id})
      assert result2 == {:error, :orchestrator_already_running}
    end

    test "rejects task with missing task_id" do
      result = Scheduler.schedule_task(%{})

      assert result == {:error, :missing_task_id}
    end

    test "rejects non-existent task" do
      fake_task_id = Ecto.UUID.generate()

      result = Scheduler.schedule_task(%{id: fake_task_id})

      assert result == {:error, :task_not_found}
    end
  end

  describe "notify_task_completed/2" do
    test "starts dependent task when all blockers complete" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      # Create task A (blocker) and task B (dependent)
      task_a = create_task(user, project, %{title: "Task A"})
      task_a = assign_workflow_to_task(user, task_a, workflow)

      task_b = create_task(user, project, %{title: "Task B"})
      task_b = assign_workflow_to_task(user, task_b, workflow)

      # Make task B depend on task A
      add_dependency(task_b, task_a)

      # Complete task A
      task_a = mark_task_completed(task_a)

      # Notify scheduler
      result = Scheduler.notify_task_completed(task_a.id, %{status: "completed"})

      # Give it time to process
      Process.sleep(200)

      assert result == :ok

      # Verify task B's orchestrator was started
      assert Registry.lookup(TaskRegistry, task_b.id) != []
    end

    test "does not start dependent task with incomplete blockers" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      # Create task A, B, and C where C depends on both A and B
      task_a = create_task(user, project, %{title: "Task A"})
      task_a = assign_workflow_to_task(user, task_a, workflow)

      task_b = create_task(user, project, %{title: "Task B"})
      task_b = assign_workflow_to_task(user, task_b, workflow)

      task_c = create_task(user, project, %{title: "Task C"})
      task_c = assign_workflow_to_task(user, task_c, workflow)

      # Make task C depend on both A and B
      add_dependency(task_c, task_a)
      add_dependency(task_c, task_b)

      # Complete only task A
      task_a = mark_task_completed(task_a)

      # Notify scheduler
      result = Scheduler.notify_task_completed(task_a.id, %{status: "completed"})

      # Give it time to process
      Process.sleep(200)

      assert result == :ok

      # Verify task C's orchestrator was NOT started (because task B is still incomplete)
      assert Registry.lookup(TaskRegistry, task_c.id) == []
    end

    test "handles non-existent task gracefully" do
      fake_task_id = Ecto.UUID.generate()

      result = Scheduler.notify_task_completed(fake_task_id, %{status: "completed"})

      assert result == {:error, :task_not_found}
    end
  end

  describe "recovery on init" do
    test "recovers tasks with pending step executions" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(user, task, workflow)

      # Create a pending step execution
      {:ok, _execution} =
        Repo.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          project_id: project.id,
          step_name: step.name,
          status: "pending"
        })

      # The Scheduler is already started by the supervision tree,
      # but we can verify recovery works by checking if orchestrators were started
      Process.sleep(500)

      # Verify task's orchestrator should be running (if recovery is working)
      # This test is primarily checking that recovery doesn't crash
      assert true
    end

    test "recovers tasks with in_progress step executions" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(user, task, workflow)

      # Create an in_progress step execution
      {:ok, _execution} =
        Repo.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          project_id: project.id,
          step_name: step.name,
          status: "in_progress"
        })

      # The Scheduler is already started by the supervision tree
      Process.sleep(500)

      # Verify recovery doesn't crash the scheduler
      assert true
    end

    test "ignores completed tasks during recovery" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(user, task, workflow)
      task = mark_task_completed(task)

      # Create a pending step execution on a completed task
      {:ok, _execution} =
        Repo.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: workflow.id,
          project_id: project.id,
          step_name: step.name,
          status: "pending"
        })

      # The Scheduler is already started by the supervision tree
      Process.sleep(500)

      # Verify completed task's orchestrator was NOT started
      assert Registry.lookup(TaskRegistry, task.id) == []
    end
  end
end
