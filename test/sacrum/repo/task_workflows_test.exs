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

    test "does not create a StepExecution record (dispatcher owns creation)" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()

      {:ok, _updated} = TaskWorkflows.assign_workflow(task, workflow)

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert executions == []
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

  describe "get_current_step/1" do
    test "returns the current WorkflowStep" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, step} = TaskWorkflows.get_current_step(assigned)

      assert step.id == steps.backlog.id
      assert step.name == "backlog"
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

    test "updates current_step_id without creating StepExecution (dispatcher owns creation)" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      executions_before =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert executions_before == []

      {:ok, moved} = TaskWorkflows.move_to_step(assigned, steps.in_progress.id)

      executions_after =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert executions_after == []
      assert moved.current_step_id == steps.in_progress.id
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
  end

  describe "advance_to_step/2" do
    test "updates current_step_id to target step" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, advanced} = TaskWorkflows.advance_to_step(assigned, steps.in_progress.id)

      assert advanced.current_step_id == steps.in_progress.id
    end

    test "updates current_step_id without creating StepExecution (dispatcher owns creation)" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      executions_before =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert executions_before == []

      {:ok, advanced} = TaskWorkflows.advance_to_step(assigned, steps.in_progress.id)

      executions_after =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert executions_after == []
      assert advanced.current_step_id == steps.in_progress.id
    end

    test "does not validate transition existence" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      # backlog -> done has no direct transition, but advance_to_step skips that check
      {:ok, advanced} = TaskWorkflows.advance_to_step(assigned, steps.done.id)

      assert advanced.current_step_id == steps.done.id
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

  describe "step-change does not create or modify executions" do
    test "advance_to_step leaves existing executions untouched" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, pre_existing} =
        Accounts.StepExecutions.insert(task.user_id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => workflow.id,
          "step_id" => steps.in_progress.id,
          "step_name" => steps.in_progress.name,
          "status" => "completed"
        })

      {:ok, _updated_task} =
        TaskWorkflows.advance_to_step(task, steps.in_progress.id, skip_orchestrator_check: true)

      all_executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_id: steps.in_progress.id],
          order_by: [asc: :inserted_at]
        )

      assert length(all_executions) == 1
      [reloaded] = all_executions
      assert reloaded.id == pre_existing.id
      assert reloaded.status == "completed"
    end

    test "move_to_step leaves existing executions untouched" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, pre_existing} =
        Accounts.StepExecutions.insert(task.user_id, %{
          "task_id" => task.id,
          "project_id" => task.project_id,
          "workflow_id" => workflow.id,
          "step_id" => steps.in_progress.id,
          "step_name" => steps.in_progress.name,
          "status" => "completed"
        })

      {:ok, _updated_task} =
        TaskWorkflows.move_to_step(task, steps.in_progress.id, skip_orchestrator_check: true)

      all_executions =
        StepExecutions.all(
          conditions: [task_id: task.id, step_id: steps.in_progress.id],
          order_by: [asc: :inserted_at]
        )

      assert length(all_executions) == 1
      [reloaded] = all_executions
      assert reloaded.id == pre_existing.id
      assert reloaded.status == "completed"
    end
  end

  describe "assign_workflow idempotency" do
    test "calling assign_workflow twice is a no-op on the second call" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()

      {:ok, assigned1} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, assigned2} = TaskWorkflows.assign_workflow(assigned1, workflow)

      assert assigned2.workflow_id == workflow.id
      assert assigned2.current_step_id == assigned1.current_step_id

      executions =
        StepExecutions.all(
          conditions: [task_id: task.id, workflow_id: workflow.id],
          order_by: [asc: :inserted_at]
        )

      assert executions == []
    end

    test "simulates full vtb add -w default shape: Accounts.Tasks.insert + explicit assign_workflow" do
      user = create_user()
      project = create_project(user)
      # Get the auto-created default Backlog workflow
      workflows = Workflows.all(conditions: [project_id: project.id])
      default_workflow = Enum.find(workflows, &(&1.is_default == true))

      default_backlog_step =
        Sacrum.Repo.get!(Sacrum.Repo.Schemas.WorkflowStep, default_workflow.initial_step_id)

      # Create additional steps to mimic workflow
      step2 = create_step(default_workflow, %{name: "in_progress", step_order: 2})
      step3 = create_step(default_workflow, %{name: "done", step_order: 3, is_final: true})

      create_transition(default_backlog_step, step2)
      create_transition(step2, step3)

      {:ok, task} = Accounts.Tasks.insert(project, %{title: "Test Task"})

      task = Sacrum.Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
      assert task.workflow_id == default_workflow.id
      assert task.current_step_id == default_backlog_step.id

      {:ok, task_after_explicit} = TaskWorkflows.assign_workflow(task, default_workflow)

      assert task_after_explicit.workflow_id == default_workflow.id
      assert task_after_explicit.current_step_id == default_backlog_step.id

      executions =
        StepExecutions.all(
          conditions: [task_id: task.id, workflow_id: default_workflow.id],
          order_by: [asc: :inserted_at]
        )

      assert executions == []
    end

    test "re-assigning to a different workflow updates workflow and step ids" do
      user = create_user()
      project = create_project(user)

      workflow1 = create_workflow(project)
      step1_w1 = create_step(workflow1, %{name: "step1", step_order: 1})
      {:ok, workflow1} = Workflows.update(workflow1, %{initial_step_id: step1_w1.id})

      workflow2 = create_workflow(project)
      step1_w2 = create_step(workflow2, %{name: "step_a", step_order: 1})
      {:ok, workflow2} = Workflows.update(workflow2, %{initial_step_id: step1_w2.id})

      task = create_task(project)

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow1)
      assert task.workflow_id == workflow1.id
      assert task.current_step_id == step1_w1.id

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow2)
      assert task.workflow_id == workflow2.id
      assert task.current_step_id == step1_w2.id
    end

    test "assign_workflow still rejects when orchestrator is active even if workflow matches" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()

      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, _pid} =
        Registry.register(
          Sacrum.Orchestrator.TaskRegistry,
          task.id,
          "fake_orchestrator_pid"
        )

      assert {:error, :orchestrator_active} = TaskWorkflows.assign_workflow(task, workflow)

      Registry.unregister(Sacrum.Orchestrator.TaskRegistry, task.id)
    end
  end

  describe "task_step_changed broadcasts" do
    test "assign_workflow to a new workflow emits task_step_changed with old and new step ids" do
      %{project: project, workflow: workflow, steps: steps, task: task} =
        setup_workflow_with_steps()

      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      {:ok, _assigned} = TaskWorkflows.assign_workflow(task, workflow)

      events = collect_broadcasts("task_step_changed")
      assert [event] = Enum.filter(events, &(&1.task_id == task.id))
      assert event.from_step_id == task.current_step_id
      assert event.to_step_id == steps.backlog.id
      assert event.workflow_id == workflow.id
      assert event.level == task.level
    end

    test "idempotent re-assign does not emit task_step_changed" do
      %{project: project, workflow: workflow, task: task} = setup_workflow_with_steps()

      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      {:ok, _again} = TaskWorkflows.assign_workflow(assigned, workflow)

      assert collect_broadcasts("task_step_changed") == []
    end

    test "move_to_step emits task_step_changed with old and new step ids" do
      %{project: project, workflow: workflow, steps: steps, task: task} =
        setup_workflow_with_steps()

      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      {:ok, _moved} = TaskWorkflows.move_to_step(assigned, steps.in_progress.id)

      events = collect_broadcasts("task_step_changed")
      assert [event] = Enum.filter(events, &(&1.task_id == task.id))
      assert event.from_step_id == steps.backlog.id
      assert event.to_step_id == steps.in_progress.id
      assert event.workflow_id == workflow.id
    end

    test "advance_to_step emits task_step_changed" do
      %{project: project, workflow: workflow, steps: steps, task: task} =
        setup_workflow_with_steps()

      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      {:ok, _advanced} = TaskWorkflows.advance_to_step(assigned, steps.done.id)

      events = collect_broadcasts("task_step_changed")
      assert [event] = Enum.filter(events, &(&1.task_id == task.id))
      assert event.from_step_id == steps.backlog.id
      assert event.to_step_id == steps.done.id
    end
  end

  defp collect_broadcasts(event) do
    receive do
      %Phoenix.Socket.Broadcast{event: ^event, payload: payload} ->
        [payload | collect_broadcasts(event)]
    after
      50 -> []
    end
  end
end
