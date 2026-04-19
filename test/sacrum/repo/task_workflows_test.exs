defmodule Sacrum.Repo.TaskWorkflowsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.StepTransitions
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.TaskWorkflows

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user do
    {:ok, user} = Users.insert(@valid_user_attrs)
    user
  end

  defp create_user_with_email(email) do
    {:ok, user} = Users.insert(%{@valid_user_attrs | email: email, username: "other_user"})
    user
  end

  defp create_project(user) do
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    project
  end

  defp create_workflow(project) do
    {:ok, workflow} = Workflows.insert(project, %{name: "Dev Workflow"})
    workflow
  end

  defp create_step(workflow, attrs) do
    {:ok, step} = WorkflowSteps.insert(workflow, attrs)
    step
  end

  defp create_transition(from_step, to_step) do
    {:ok, transition} =
      StepTransitions.insert(from_step.user_id, %{
        project_id: from_step.project_id,
        from_step_id: from_step.id,
        to_step_id: to_step.id
      })

    transition
  end

  defp create_task(project) do
    {:ok, task} = Tasks.insert(project, %{title: "Test Task"})
    task
  end

  defp setup_workflow_with_steps do
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(project)
    step1 = create_step(workflow, %{name: "backlog", step_order: 1})
    step2 = create_step(workflow, %{name: "in_progress", step_order: 2})
    step3 = create_step(workflow, %{name: "done", step_order: 3, is_final: true})

    # Set initial step
    {:ok, workflow} = Workflows.update(workflow, %{initial_step_id: step1.id})

    create_transition(step1, step2)
    create_transition(step2, step3)

    task = create_task(project)

    %{
      project: project,
      workflow: workflow,
      steps: %{backlog: step1, in_progress: step2, done: step3},
      task: task
    }
  end

  describe "assign_workflow/2" do
    test "sets workflow_id and current_step_id to initial step" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, updated} = TaskWorkflows.assign_workflow(task, workflow)

      assert updated.workflow_id == workflow.id
      assert updated.current_step_id == steps.backlog.id
    end

    test "creates a StepExecution record" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()

      {:ok, _updated} = TaskWorkflows.assign_workflow(task, workflow)

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert length(executions) == 1
      assert hd(executions).step_name == "backlog"
      assert hd(executions).status == "entered"
    end

    test "falls back to first step by step_order when no initial_step_id" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(project)
      _step2 = create_step(workflow, %{name: "second", step_order: 2})
      step1 = create_step(workflow, %{name: "first", step_order: 1})
      task = create_task(project)

      {:ok, updated} = TaskWorkflows.assign_workflow(task, workflow)

      assert updated.current_step_id == step1.id
    end

    test "returns error when workflow has no steps" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(project)
      task = create_task(project)

      assert {:error, :workflow_has_no_steps} = TaskWorkflows.assign_workflow(task, workflow)
    end
  end

  describe "unassign_workflow/1" do
    test "clears workflow_id and current_step_id" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, unassigned} = TaskWorkflows.unassign_workflow(assigned)

      assert is_nil(unassigned.workflow_id)
      assert is_nil(unassigned.current_step_id)
    end
  end

  describe "get_current_step/1" do
    test "returns the current WorkflowStep" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, step} = TaskWorkflows.get_current_step(assigned)

      assert step.id == steps.backlog.id
      assert step.name == "backlog"
    end

    test "returns error when task has no current step" do
      user = create_user()
      project = create_project(user)
      task = create_task(project)

      assert {:error, :no_current_step} = TaskWorkflows.get_current_step(task)
    end
  end

  describe "move_to_step/2" do
    test "moves to a valid forward transition target" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, moved} = TaskWorkflows.move_to_step(assigned, steps.in_progress.id)

      assert moved.current_step_id == steps.in_progress.id
    end

    test "moves to a valid backward transition target" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, at_in_progress} = TaskWorkflows.move_to_step(assigned, steps.in_progress.id)

      {:ok, moved_back} = TaskWorkflows.move_to_step(at_in_progress, steps.backlog.id)

      assert moved_back.current_step_id == steps.backlog.id
    end

    test "creates StepExecution record for the move" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, _moved} = TaskWorkflows.move_to_step(assigned, steps.in_progress.id)

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert length(executions) == 2
      assert List.last(executions).step_name == "in_progress"
      assert List.last(executions).status == "entered"
    end

    test "returns error when no transition exists between steps" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      # backlog -> done has no direct transition
      assert {:error, :no_transition} = TaskWorkflows.move_to_step(assigned, steps.done.id)
    end

    test "returns error when step does not belong to workflow" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      # Create a step in a different workflow
      user = create_user_with_email("other@example.com")
      project = create_project(user)
      other_workflow = create_workflow(project)
      other_step = create_step(other_workflow, %{name: "other", step_order: 1})

      assert {:error, :step_not_in_workflow} =
               TaskWorkflows.move_to_step(assigned, other_step.id)
    end

    test "returns error when step_id does not exist" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      assert {:error, :step_not_found} =
               TaskWorkflows.move_to_step(assigned, Ecto.UUID.generate())
    end

    test "returns error when task has no workflow" do
      user = create_user()
      project = create_project(user)
      task = create_task(project)

      assert {:error, :no_workflow} =
               TaskWorkflows.move_to_step(task, Ecto.UUID.generate())
    end

    test "returns error when task has no current step" do
      user = create_user()
      project = create_project(user)
      task = create_task(project)
      # Manually set workflow_id but no current_step_id (edge case)
      workflow = create_workflow(project)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{workflow_id: workflow.id})
        |> Sacrum.Repo.update()

      assert {:error, :no_current_step} =
               TaskWorkflows.move_to_step(task, Ecto.UUID.generate())
    end
  end

  describe "start_current_step/1" do
    test "updates execution to started status" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, updated} = TaskWorkflows.start_current_step(assigned)

      assert updated.id == task.id

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      latest = List.last(executions)
      assert latest.status == "started"
    end

    test "sets started_at on task if nil" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      assert is_nil(assigned.started_at)
      {:ok, updated} = TaskWorkflows.start_current_step(assigned)

      assert not is_nil(updated.started_at)
    end

    test "does not overwrite existing started_at" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      original_time = ~U[2025-01-01 12:00:00.000000Z]

      {:ok, with_started} =
        assigned
        |> Ecto.Changeset.change(%{started_at: original_time})
        |> Sacrum.Repo.update()

      {:ok, updated} = TaskWorkflows.start_current_step(with_started)

      assert updated.started_at == original_time
    end

    test "returns error when execution is not in entered status" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, started} = TaskWorkflows.start_current_step(assigned)

      assert {:error, :not_in_entered_status} = TaskWorkflows.start_current_step(started)
    end

    test "returns error when task has no current step" do
      user = create_user()
      project = create_project(user)
      task = create_task(project)

      assert {:error, :no_current_step} = TaskWorkflows.start_current_step(task)
    end
  end

  describe "complete_current_step/1" do
    test "completes a non-final step" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, started} = TaskWorkflows.start_current_step(assigned)

      {:ok, completed} = TaskWorkflows.complete_current_step(started)

      assert is_nil(completed.completed_at)

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      latest = List.last(executions)
      assert latest.status == "completed"
      assert latest.step_name == "backlog"
    end

    test "completes a final step and sets completed_at" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      # Move to in_progress then done
      {:ok, started} = TaskWorkflows.start_current_step(assigned)
      {:ok, completed_step1} = TaskWorkflows.complete_current_step(started)
      {:ok, at_progress} = TaskWorkflows.move_to_step(completed_step1, steps.in_progress.id)
      {:ok, started2} = TaskWorkflows.start_current_step(at_progress)
      {:ok, completed_step2} = TaskWorkflows.complete_current_step(started2)
      {:ok, at_done} = TaskWorkflows.move_to_step(completed_step2, steps.done.id)
      {:ok, started3} = TaskWorkflows.start_current_step(at_done)

      {:ok, final} = TaskWorkflows.complete_current_step(started3)

      assert not is_nil(final.completed_at)

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      latest = List.last(executions)
      assert latest.status == "completed"
      assert latest.step_name == "done"
    end

    test "returns error when execution is not in started status" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      assert {:error, :not_in_started_status} = TaskWorkflows.complete_current_step(assigned)
    end
  end

  describe "reject_current_step/3" do
    test "rejects and moves to target step" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, started} = TaskWorkflows.start_current_step(assigned)
      {:ok, completed} = TaskWorkflows.complete_current_step(started)
      {:ok, at_progress} = TaskWorkflows.move_to_step(completed, steps.in_progress.id)
      {:ok, started2} = TaskWorkflows.start_current_step(at_progress)

      {:ok, rejected} = TaskWorkflows.reject_current_step(started2, steps.backlog.id)

      assert rejected.current_step_id == steps.backlog.id
    end

    test "stores feedback in transition_result" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, started} = TaskWorkflows.start_current_step(assigned)
      {:ok, completed} = TaskWorkflows.complete_current_step(started)
      {:ok, at_progress} = TaskWorkflows.move_to_step(completed, steps.in_progress.id)
      {:ok, started2} = TaskWorkflows.start_current_step(at_progress)

      {:ok, _rejected} =
        TaskWorkflows.reject_current_step(started2, steps.backlog.id, "needs rework")

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      # Find the rejected execution (should have status "rejected")
      rejected_exec = Enum.find(executions, &(&1.status == "rejected"))
      assert rejected_exec != nil
      assert rejected_exec.transition_result == "needs rework"
    end

    test "returns error when no transition exists to target" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, started} = TaskWorkflows.start_current_step(assigned)

      # backlog -> done has no direct transition
      assert {:error, :no_transition} =
               TaskWorkflows.reject_current_step(started, steps.done.id)
    end

    test "returns error when execution is not in started status" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      assert {:error, :not_in_started_status} =
               TaskWorkflows.reject_current_step(assigned, steps.in_progress.id)
    end
  end

  describe "advance_to_step/2" do
    test "updates current_step_id to target step" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, advanced} = TaskWorkflows.advance_to_step(assigned, steps.in_progress.id)

      assert advanced.current_step_id == steps.in_progress.id
    end

    test "creates an entered StepExecution for the target step" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, _advanced} = TaskWorkflows.advance_to_step(assigned, steps.in_progress.id)

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert length(executions) == 2
      assert List.last(executions).step_name == "in_progress"
      assert List.last(executions).status == "entered"
    end

    test "does not validate transition existence" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      # backlog -> done has no direct transition, but advance_to_step skips that check
      {:ok, advanced} = TaskWorkflows.advance_to_step(assigned, steps.done.id)

      assert advanced.current_step_id == steps.done.id
    end

    test "returns error when task has no workflow" do
      user = create_user()
      project = create_project(user)
      task = create_task(project)

      assert {:error, :no_workflow} =
               TaskWorkflows.advance_to_step(task, Ecto.UUID.generate())
    end

    test "returns error when task has no current step" do
      user = create_user()
      project = create_project(user)
      task = create_task(project)
      workflow = create_workflow(project)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{workflow_id: workflow.id})
        |> Sacrum.Repo.update()

      assert {:error, :no_current_step} =
               TaskWorkflows.advance_to_step(task, Ecto.UUID.generate())
    end

    test "returns error when step does not belong to workflow" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      user = create_user_with_email("other@example.com")
      project = create_project(user)
      other_workflow = create_workflow(project)
      other_step = create_step(other_workflow, %{name: "other", step_order: 1})

      assert {:error, :step_not_in_workflow} =
               TaskWorkflows.advance_to_step(assigned, other_step.id)
    end

    test "returns error when step_id does not exist" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      assert {:error, :step_not_found} =
               TaskWorkflows.advance_to_step(assigned, Ecto.UUID.generate())
    end
  end

  describe "advance_to_step/3 with handoff" do
    test "persists handoff on new execution atomically" do
      %{workflow: workflow, task: task, steps: steps} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      handoff_data = %{"feedback" => "needs_review", "reviewer" => "john@example.com"}

      {:ok, updated} = TaskWorkflows.advance_to_step(assigned, steps.in_progress.id, handoff_data)

      assert updated.current_step_id == steps.in_progress.id

      # Verify the new execution has handoff persisted
      executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_name: "in_progress"],
          order_by: [desc: :inserted_at]
        )

      latest = List.first(executions)
      assert latest.status == "entered"
      assert latest.handoff == handoff_data
    end

    test "handles nil handoff gracefully" do
      %{workflow: workflow, task: task, steps: steps} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, updated} = TaskWorkflows.advance_to_step(assigned, steps.in_progress.id, nil)

      assert updated.current_step_id == steps.in_progress.id

      executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_name: "in_progress"],
          order_by: [desc: :inserted_at]
        )

      latest = List.first(executions)
      assert latest.status == "entered"
      assert is_nil(latest.handoff)
    end

    test "uses default nil when handoff is not provided" do
      %{workflow: workflow, task: task, steps: steps} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, updated} = TaskWorkflows.advance_to_step(assigned, steps.in_progress.id)

      assert updated.current_step_id == steps.in_progress.id

      executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_name: "in_progress"],
          order_by: [desc: :inserted_at]
        )

      latest = List.first(executions)
      assert is_nil(latest.handoff)
    end
  end

  describe "move_to_step/3 with handoff" do
    test "persists handoff on new execution atomically" do
      %{workflow: workflow, task: task, steps: steps} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, in_progress} = TaskWorkflows.move_to_step(assigned, steps.in_progress.id)

      handoff_data = %{"status" => "approved", "timestamp" => "2025-04-18T10:00:00Z"}

      {:ok, updated} = TaskWorkflows.move_to_step(in_progress, steps.done.id, handoff_data)

      assert updated.current_step_id == steps.done.id

      # Verify the new execution has handoff persisted
      executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_name: "done"],
          order_by: [desc: :inserted_at]
        )

      latest = List.first(executions)
      assert latest.status == "entered"
      assert latest.handoff == handoff_data
    end

    test "handles nil handoff on move_to_step" do
      %{workflow: workflow, task: task, steps: steps} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, in_progress} = TaskWorkflows.move_to_step(assigned, steps.in_progress.id)

      {:ok, updated} = TaskWorkflows.move_to_step(in_progress, steps.done.id, nil)

      assert updated.current_step_id == steps.done.id

      executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_name: "done"],
          order_by: [desc: :inserted_at]
        )

      latest = List.first(executions)
      assert is_nil(latest.handoff)
    end
  end

  describe "orchestrator-priority gate" do
    test "assign_workflow rejects when orchestrator is registered for task" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()

      # Register the task in the orchestrator registry
      Registry.register(Sacrum.Orchestrator.TaskRegistry, task.id, nil)

      assert {:error, :orchestrator_active} = TaskWorkflows.assign_workflow(task, workflow)
    end

    test "assign_workflow succeeds when no orchestrator is registered" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()

      # Ensure no registration
      Registry.unregister(Sacrum.Orchestrator.TaskRegistry, task.id)

      {:ok, updated} = TaskWorkflows.assign_workflow(task, workflow)
      assert updated.workflow_id == workflow.id
    end

    test "advance_to_step rejects when orchestrator is registered for task" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      # Register the task in the orchestrator registry
      Registry.register(Sacrum.Orchestrator.TaskRegistry, task.id, nil)

      assert {:error, :orchestrator_active} =
               TaskWorkflows.advance_to_step(task, steps.in_progress.id)
    end

    test "advance_to_step succeeds when no orchestrator is registered" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      # Ensure no registration
      Registry.unregister(Sacrum.Orchestrator.TaskRegistry, task.id)

      {:ok, updated} = TaskWorkflows.advance_to_step(task, steps.in_progress.id)
      assert updated.current_step_id == steps.in_progress.id
    end

    test "move_to_step rejects when orchestrator is registered for task" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      # Register the task in the orchestrator registry
      Registry.register(Sacrum.Orchestrator.TaskRegistry, task.id, nil)

      assert {:error, :orchestrator_active} =
               TaskWorkflows.move_to_step(task, steps.in_progress.id)
    end

    test "move_to_step succeeds when no orchestrator is registered" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      # Ensure no registration
      Registry.unregister(Sacrum.Orchestrator.TaskRegistry, task.id)

      {:ok, updated} = TaskWorkflows.move_to_step(task, steps.in_progress.id)
      assert updated.current_step_id == steps.in_progress.id
    end
  end

  describe "invalidate-on-leave" do
    test "advance_to_step invalidates prior entered row for target step" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      # Create a pre-existing "entered" row for the target step (simulating CLI handoff)
      {:ok, _pre_existing} =
        Accounts.StepExecutions.insert(task.user_id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => workflow.id,
          "step_id" => steps.in_progress.id,
          "step_name" => steps.in_progress.name,
          "status" => "entered"
        })

      # Advance to the same step via skip_orchestrator_check (simulating orchestrator call)
      {:ok, _updated_task} =
        TaskWorkflows.advance_to_step(task, steps.in_progress.id, nil,
          skip_orchestrator_check: true
        )

      # Verify the pre-existing row is invalidated
      all_executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_id: steps.in_progress.id],
          order_by: [asc: :inserted_at]
        )

      assert length(all_executions) == 2
      invalidated = List.first(all_executions)
      assert invalidated.status == "invalidated"

      entered = List.last(all_executions)
      assert entered.status == "entered"
    end

    test "move_to_step invalidates prior entered row for target step" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      # Create a pre-existing "entered" row for the target step
      {:ok, _pre_existing} =
        Accounts.StepExecutions.insert(task.user_id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => workflow.id,
          "step_id" => steps.in_progress.id,
          "step_name" => steps.in_progress.name,
          "status" => "entered"
        })

      # Move to the same step via skip_orchestrator_check (simulating orchestrator call)
      {:ok, _updated_task} =
        TaskWorkflows.move_to_step(task, steps.in_progress.id, nil, skip_orchestrator_check: true)

      # Verify the pre-existing row is invalidated
      all_executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_id: steps.in_progress.id],
          order_by: [asc: :inserted_at]
        )

      assert length(all_executions) == 2
      invalidated = List.first(all_executions)
      assert invalidated.status == "invalidated"

      entered = List.last(all_executions)
      assert entered.status == "entered"
    end
  end
end
