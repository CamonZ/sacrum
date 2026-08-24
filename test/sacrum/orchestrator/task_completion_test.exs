defmodule Sacrum.Orchestrator.TaskCompletionTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{FSMData, TaskCompletion}
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

  defp create_workflow(user, project, attrs \\ %{}) do
    {:ok, workflow} =
      Accounts.Workflows.insert(
        user.id,
        project.id,
        Map.merge(%{name: "Test Workflow"}, attrs)
      )

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
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

      data = %FSMData{user_id: user.id, project_id: project.id, task: task}

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

      data = %FSMData{
        user_id: user.id,
        project_id: project.id,
        task: task,
        task_run_id: Ecto.UUID.generate()
      }

      assert {:error, :task_run_not_found} = TaskCompletion.handle_completion(data)
      assert Repo.get!(Sacrum.Repo.Schemas.Task, task.id).completed_at == nil
    end
  end

  describe "determine_next_state/2" do
    test "dispatches execute steps regardless of prompt presence" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      next_step = create_step(user, workflow, %{"prompt" => nil})
      task = create_task(user, project, workflow)

      data = %{
        task: task,
        steps: %{next_step.id => next_step},
        workflow: workflow
      }

      assert TaskCompletion.determine_next_state(next_step.id, data) ==
               {:next_state, :awaiting_execution, data}
    end

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

    test "dispatches final prompted step instead of skipping to completing" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      final_step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      data = %{
        task: task,
        steps: %{final_step.id => final_step},
        workflow: workflow
      }

      assert TaskCompletion.determine_next_state(final_step.id, data) ==
               {:next_state, :awaiting_execution, data}
    end

    test "stops normally for a promptless finish step" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{})

      final_step =
        create_step(user, workflow, %{
          "step_type" => "finish",
          "prompt" => nil
        })

      task = create_task(user, project, workflow)
      task_run = create_task_run(user, project, task)

      data = %{
        task: task,
        task_run_id: task_run.id,
        steps: %{final_step.id => final_step},
        workflow: workflow
      }

      assert {:stop, :normal, _attrs} = TaskCompletion.determine_next_state(final_step.id, data)

      assert {:stop, :normal, attrs} = TaskCompletion.next_state_decision(final_step.id, data)
      assert attrs.outcome_kind == "completed"
      assert attrs.outcome_context["reason"] == "finish_step"
    end

    test "stops at a stop step with a run-boundary outcome" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      stop_step =
        create_step(user, workflow, %{
          "step_type" => "stop",
          "prompt" => nil
        })

      task = create_task(user, project, workflow)
      task_run = create_task_run(user, project, task)

      data = %{
        task: task,
        task_run_id: task_run.id,
        steps: %{stop_step.id => stop_step},
        workflow: workflow
      }

      assert {:stop, :normal, attrs} = TaskCompletion.next_state_decision(stop_step.id, data)
      assert attrs.outcome_kind == "run_boundary"
      assert attrs.outcome_context["reason"] == "stop_step"
      assert attrs.outcome_context["step_id"] == stop_step.id
    end

    test "transitions to awaiting_execution when destination step has a prompt" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      next_step = create_step(user, workflow, %{})
      task = create_task(user, project, workflow)

      data = %{
        task: task,
        steps: %{next_step.id => next_step},
        workflow: workflow
      }

      result = TaskCompletion.determine_next_state(next_step.id, data)

      assert result == {:next_state, :awaiting_execution, data}
    end

    test "transitions to awaiting_execution for promptless orchestrator control steps" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      for step_type <- ~w(wait_children human_input) do
        next_step =
          create_step(user, workflow, %{
            "name" => "#{step_type} destination",
            "step_type" => step_type,
            "prompt" => nil
          })

        task = create_task(user, project, workflow)

        data = %{
          task: task,
          steps: %{next_step.id => next_step},
          workflow: workflow
        }

        assert TaskCompletion.next_state_decision(next_step.id, data) ==
                 {:next_state, :awaiting_execution}

        assert TaskCompletion.determine_next_state(next_step.id, data) ==
                 {:next_state, :awaiting_execution, data}
      end
    end

    test "dispatches a blank-prompt execute destination instead of completing the run" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      next_step = create_step(user, workflow, %{"prompt" => " \n\t "})
      task = create_task(user, project, workflow)
      task_run = create_task_run(user, project, task)

      data = %{
        task: task,
        task_run_id: task_run.id,
        steps: %{next_step.id => next_step},
        workflow: workflow
      }

      assert TaskCompletion.determine_next_state(next_step.id, data) ==
               {:next_state, :awaiting_execution, data}

      unchanged_run = Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id)
      assert unchanged_run.status == :executing

      assert TaskCompletion.next_state_decision(next_step.id, data) ==
               {:next_state, :awaiting_execution}
    end
  end
end
