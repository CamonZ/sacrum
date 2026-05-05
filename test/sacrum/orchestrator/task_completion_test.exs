defmodule Sacrum.Orchestrator.TaskCompletionTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.TaskCompletion
  alias Sacrum.Repo

  # ===== Setup helpers =====

  defp create_user do
    {:ok, user} =
      Repo.Users.insert(%{
        email: "task_completion_test@example.com",
        username: "task_completion_test",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "TC Test Project"})
    project
  end

  defp create_workflow(user, project, opts \\ []) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Test Workflow",
        auto_advance: Keyword.get(opts, :auto_advance, false)
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
      "is_final" => false,
      "agents" => ["test"],
      "skills" => ["test_skill"],
      "agent_config" => %{"model" => "test-model"},
      "workflow_id" => workflow.id,
      "project_id" => workflow.project_id,
      "prompt" => "default prompt"
    }

    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, Map.merge(default_attrs, attrs))
    step
  end

  defp create_task(user, project, workflow) do
    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Test Task",
        description: "A test task description",
        level: "ticket",
        tags: ["test"]
      })

    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  defp create_task_run(user, project, task, attrs \\ %{status: :executing}) do
    {:ok, task_run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, attrs)
    task_run
  end

  # ===== Tests =====

  describe "handle_completion/1" do
    test "sets completed_at and returns updated task in data" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      assert task.completed_at == nil

      data = %{task: task}

      {:ok, :completed, new_data} = TaskCompletion.handle_completion(data)

      assert new_data.task.completed_at != nil
      assert new_data.task.id == task.id
    end

    test "does not complete task when task run completion cannot be prepared" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      data = %{task: task, task_run_id: Ecto.UUID.generate()}

      assert {:error, :task_run_not_found} = TaskCompletion.handle_completion(data)
      assert Repo.get!(Sacrum.Repo.Schemas.Task, task.id).completed_at == nil
    end
  end

  describe "determine_next_state/2" do
    test "returns failed state when next_step_id is nil" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      data = %{
        task: task,
        steps: %{step.id => step},
        workflow: workflow
      }

      result = TaskCompletion.determine_next_state(nil, data)

      assert result == {:next_state, :failed, data}
    end

    test "returns failed state when next step not found in cache" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      data = %{
        task: task,
        steps: %{},
        workflow: workflow
      }

      result = TaskCompletion.determine_next_state("nonexistent", data)

      assert result == {:next_state, :failed, data}
    end

    test "transitions to completing when next step is final" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      final_step = create_step(user, workflow, %{"is_final" => true})
      task = create_task(user, project, workflow)

      data = %{
        task: task,
        steps: %{final_step.id => final_step},
        workflow: workflow
      }

      result = TaskCompletion.determine_next_state(final_step.id, data)

      assert result == {:next_state, :completing, data}
    end

    test "transitions to awaiting_execution when auto_advance is enabled" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, auto_advance: true)
      next_step = create_step(user, workflow, %{"is_final" => false})
      task = create_task(user, project, workflow)

      data = %{
        task: task,
        steps: %{next_step.id => next_step},
        workflow: workflow
      }

      result = TaskCompletion.determine_next_state(next_step.id, data)

      assert result == {:next_state, :awaiting_execution, data}
    end

    test "stops when next step is not final and auto_advance is disabled" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, auto_advance: false)
      next_step = create_step(user, workflow, %{"is_final" => false})
      task = create_task(user, project, workflow)
      task_run = create_task_run(user, project, task)

      data = %{
        task: task,
        task_run_id: task_run.id,
        steps: %{next_step.id => next_step},
        workflow: workflow
      }

      result = TaskCompletion.determine_next_state(next_step.id, data)

      assert result == {:stop, :normal, data}

      unchanged_run = Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id)
      assert unchanged_run.status == :executing

      assert {:stop, :normal, attrs} = TaskCompletion.next_state_decision(next_step.id, data)
      assert attrs.outcome_kind == "step_completed"
      assert attrs.outcome_context["reason"] == "auto_advance_disabled"
      assert attrs.outcome_context["current_step_id"] == next_step.id
    end
  end
end
