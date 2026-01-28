defmodule Sacrum.Repo.TaskWorkflowsTest do
  use Sacrum.DataCase, async: true

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
      StepTransitions.insert(%{from_step_id: from_step.id, to_step_id: to_step.id})

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

      executions = StepExecutions.list_for_task(task.id)
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

  describe "advance_step/1" do
    test "moves task to next step via valid transition" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, advanced} = TaskWorkflows.advance_step(assigned)

      assert advanced.current_step_id == steps.in_progress.id
    end

    test "creates StepExecution record for new step" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, _advanced} = TaskWorkflows.advance_step(assigned)

      executions = StepExecutions.list_for_task(task.id)
      assert length(executions) == 2
      assert List.last(executions).step_name == "in_progress"
    end

    test "returns error when no transition exists from current step" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      # Advance to in_progress, then to done (final step, no outgoing transitions)
      {:ok, at_in_progress} = TaskWorkflows.advance_step(assigned)
      {:ok, at_done} = TaskWorkflows.advance_step(at_in_progress)

      assert at_done.current_step_id == steps.done.id
      assert {:error, :no_transition} = TaskWorkflows.advance_step(at_done)
    end

    test "returns error when task has no current step" do
      user = create_user()
      project = create_project(user)
      task = create_task(project)

      assert {:error, :no_current_step} = TaskWorkflows.advance_step(task)
    end
  end

  describe "retreat_step/1" do
    test "moves task to previous step via reverse transition" do
      %{workflow: workflow, steps: steps, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, advanced} = TaskWorkflows.advance_step(assigned)

      assert advanced.current_step_id == steps.in_progress.id

      {:ok, retreated} = TaskWorkflows.retreat_step(advanced)

      assert retreated.current_step_id == steps.backlog.id
    end

    test "creates StepExecution record for retreat" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)
      {:ok, advanced} = TaskWorkflows.advance_step(assigned)

      {:ok, _retreated} = TaskWorkflows.retreat_step(advanced)

      executions = StepExecutions.list_for_task(task.id)
      # assign + advance + retreat = 3
      assert length(executions) == 3
      assert List.last(executions).step_name == "backlog"
    end

    test "returns error when no retreat transition exists" do
      %{workflow: workflow, task: task} = setup_workflow_with_steps()
      {:ok, assigned} = TaskWorkflows.assign_workflow(task, workflow)

      # At backlog (first step), no incoming transitions
      assert {:error, :no_retreat_transition} = TaskWorkflows.retreat_step(assigned)
    end

    test "returns error when task has no current step" do
      user = create_user()
      project = create_project(user)
      task = create_task(project)

      assert {:error, :no_current_step} = TaskWorkflows.retreat_step(task)
    end
  end
end
