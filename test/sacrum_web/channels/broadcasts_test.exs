defmodule SacrumWeb.BroadcastsTest do
  use Sacrum.DataCase, async: true

  import Phoenix.ChannelTest

  alias SacrumWeb.UserSocket
  alias Sacrum.Auth
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.StepTransitions
  alias Sacrum.Repo.TaskWorkflows
  alias Sacrum.Accounts.WorkflowTransitions

  @endpoint SacrumWeb.Endpoint

  @valid_user_attrs %{
    email: "broadcast@example.com",
    username: "broadcastuser",
    password: "password123"
  }

  defp setup_channel do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "test token"})
    {:ok, project} = Projects.insert(user, %{name: "Broadcast Project"})

    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _reply, _socket} = subscribe_and_join(socket, "project:#{project.id}")

    {user, project}
  end

  defp create_workflow_with_steps(project) do
    {:ok, workflow} = Workflows.insert(project, %{name: "Test Workflow"})
    {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "step1", step_order: 1})
    {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "step2", step_order: 2})
    {:ok, step3} = WorkflowSteps.insert(workflow, %{name: "step3", step_order: 3, is_final: true})

    {:ok, workflow} = Workflows.update(workflow, %{initial_step_id: step1.id})

    {:ok, _} =
      StepTransitions.insert(step1.user_id, %{
        project_id: project.id,
        from_step_id: step1.id,
        to_step_id: step2.id
      })

    {:ok, _} =
      StepTransitions.insert(step2.user_id, %{
        project_id: project.id,
        from_step_id: step2.id,
        to_step_id: step3.id
      })

    {workflow, step1, step2, step3}
  end

  describe "task broadcasts from context" do
    test "creating a task broadcasts task_created" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})

      assert_broadcast "task_created", payload
      assert payload.id == task.id
      assert payload.title == "New Task"
      assert payload.project_id == project.id
    end

    test "updating a task broadcasts task_updated" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "Original"})
      assert_broadcast "task_created", _

      {:ok, updated} = Tasks.update(task, %{title: "Updated"})

      assert_broadcast "task_updated", payload
      assert payload.id == updated.id
      assert payload.title == "Updated"
    end

    test "deleting a task broadcasts task_deleted" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "To Delete"})
      assert_broadcast "task_created", _

      {:ok, _} = Tasks.delete(task)

      assert_broadcast "task_deleted", %{id: id}
      assert id == task.id
    end
  end

  describe "step execution broadcasts on TaskWorkflows" do
    test "assign_workflow broadcasts task_updated only (execution created at dispatch time)" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})
      assert_broadcast "task_created", _

      {workflow, step1, _step2, _step3} = create_workflow_with_steps(project)

      {:ok, _updated_task} = TaskWorkflows.assign_workflow(task, workflow)

      assert_broadcast "task_updated", task_payload
      assert task_payload.id == task.id
      assert task_payload.workflow_id == workflow.id
      assert task_payload.current_step_id == step1.id

      refute_broadcast "step_execution_created", _, 100
    end

    test "advance_to_step broadcasts task_updated only (execution created at dispatch time)" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})
      assert_broadcast "task_created", _

      {workflow, _step1, step2, _step3} = create_workflow_with_steps(project)

      {:ok, assigned_task} = TaskWorkflows.assign_workflow(task, workflow)
      assert_broadcast "task_updated", _

      {:ok, _advanced_task} = TaskWorkflows.advance_to_step(assigned_task, step2.id)

      # advance_to_step now only broadcasts task_updated, not step_execution_created
      # Execution creation is delegated to ExecutionDispatcher.create_and_dispatch
      assert_broadcast "task_updated", task_payload
      assert task_payload.current_step_id == step2.id
    end

    test "move_to_step broadcasts task_updated only (execution created at dispatch time)" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})
      assert_broadcast "task_created", _

      {workflow, _step1, step2, _step3} = create_workflow_with_steps(project)

      {:ok, assigned_task} = TaskWorkflows.assign_workflow(task, workflow)
      assert_broadcast "task_updated", _

      {:ok, _moved_task} = TaskWorkflows.move_to_step(assigned_task, step2.id)

      # move_to_step now only broadcasts task_updated, not step_execution_created
      # Execution creation is delegated to ExecutionDispatcher.create_and_dispatch
      assert_broadcast "task_updated", task_payload
      assert task_payload.current_step_id == step2.id
    end

    test "assign_workflow does not broadcast on error" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})
      assert_broadcast "task_created", _

      {:ok, empty_workflow} = Workflows.insert(project, %{name: "Empty Workflow"})

      {:error, :workflow_has_no_steps} = TaskWorkflows.assign_workflow(task, empty_workflow)

      refute_broadcast "task_updated", _, 100
      refute_broadcast "step_execution_created", _, 100
    end
  end

  describe "workflow transition broadcasts" do
    test "creating a workflow transition broadcasts workflow_transition_created" do
      {user, project} = setup_channel()

      {:ok, workflow1} = Workflows.insert(project, %{name: "Implementation"})
      {:ok, workflow2} = Workflows.insert(project, %{name: "Review"})

      {:ok, transition} =
        WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "project_id" => project.id,
          "label" => "promote"
        })

      assert_broadcast "workflow_transition_created", payload
      assert payload.id == transition.id
      assert payload.from_workflow_id == workflow1.id
      assert payload.to_workflow_id == workflow2.id
      assert payload.label == "promote"
    end

    test "deleting a workflow transition broadcasts workflow_transition_deleted" do
      {user, project} = setup_channel()

      {:ok, workflow1} = Workflows.insert(project, %{name: "Implementation"})
      {:ok, workflow2} = Workflows.insert(project, %{name: "Review"})

      {:ok, transition} =
        WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "project_id" => project.id
        })

      assert_broadcast "workflow_transition_created", _

      {:ok, _} = WorkflowTransitions.delete(transition)

      assert_broadcast "workflow_transition_deleted", payload
      assert payload.id == transition.id
      assert payload.from_workflow_id == workflow1.id
      assert payload.to_workflow_id == workflow2.id
    end
  end
end
