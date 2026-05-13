defmodule SacrumWeb.BroadcastsTest do
  use Sacrum.DataCase, async: true

  import Phoenix.ChannelTest
  import Sacrum.CdcAssertions

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
    test "creating a task projects task_created through CDC" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})

      assert {:ok, [%{event: "task_created"}]} = project_insert("tasks", task)

      assert_broadcast "task_created", payload
      assert payload.id == task.id
      assert payload.title == "New Task"
      assert payload.project_id == project.id
    end

    test "updating a task projects one task_updated through CDC" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "Original"})

      {:ok, updated} = Tasks.update(task, %{title: "Updated"})
      refute_broadcast "task_updated", _, 50

      assert {:ok, [%{event: "task_updated"}]} = project_update("tasks", task, updated)

      assert_broadcast "task_updated", payload
      assert payload.id == updated.id
      assert payload.title == "Updated"

      refute_broadcast "task_updated", _, 50
    end

    test "deleting a task projects task_deleted through CDC" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "To Delete"})

      {:ok, _} = Tasks.delete(task)

      assert {:ok, [%{event: "task_deleted"}]} = project_delete("tasks", task)

      assert_broadcast "task_deleted", payload
      assert payload.schema_version == 1
      assert payload.id == task.id
      assert payload.current_step_id == task.current_step_id
      assert payload.workflow_id == task.workflow_id
      assert payload.level == task.level
      assert payload.archived == task.archived
    end
  end

  describe "step execution broadcasts on TaskWorkflows" do
    test "assign_workflow projects task_updated only for execution events" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})

      {workflow, step1, _step2, _step3} = create_workflow_with_steps(project)

      {:ok, updated_task} = TaskWorkflows.assign_workflow(task, workflow)

      assert {:ok, projections} = project_update("tasks", task, updated_task)
      assert Enum.map(projections, & &1.event) == ["task_updated", "task_step_changed"]

      assert_broadcast "task_updated", task_payload
      assert task_payload.id == task.id
      assert task_payload.workflow_id == workflow.id
      assert task_payload.current_step_id == step1.id

      refute_broadcast "step_execution_created", _, 100
    end

    test "advance_to_step projects task_updated only for execution events" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})

      {workflow, _step1, step2, _step3} = create_workflow_with_steps(project)

      {:ok, assigned_task} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, advanced_task} = TaskWorkflows.advance_to_step(assigned_task, step2.id)

      assert {:ok, projections} = project_update("tasks", assigned_task, advanced_task)
      assert Enum.map(projections, & &1.event) == ["task_updated", "task_step_changed"]

      # Execution creation is delegated to ExecutionDispatcher.create_and_dispatch.
      assert_broadcast "task_updated", task_payload
      assert task_payload.current_step_id == step2.id
    end

    test "move_to_step projects task_updated only for execution events" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})

      {workflow, _step1, step2, _step3} = create_workflow_with_steps(project)

      {:ok, assigned_task} = TaskWorkflows.assign_workflow(task, workflow)

      {:ok, moved_task} = TaskWorkflows.move_to_step(assigned_task, step2.id)

      assert {:ok, projections} = project_update("tasks", assigned_task, moved_task)
      assert Enum.map(projections, & &1.event) == ["task_updated", "task_step_changed"]

      # Execution creation is delegated to ExecutionDispatcher.create_and_dispatch.
      assert_broadcast "task_updated", task_payload
      assert task_payload.current_step_id == step2.id
    end

    test "assign_workflow does not broadcast on error" do
      {_user, project} = setup_channel()

      {:ok, task} = Tasks.insert(project, %{title: "New Task"})

      {:ok, empty_workflow} = Workflows.insert(project, %{name: "Empty Workflow"})

      {:error, :workflow_has_no_steps} = TaskWorkflows.assign_workflow(task, empty_workflow)

      refute_broadcast "task_updated", _, 100
      refute_broadcast "step_execution_created", _, 100
    end
  end

  describe "workflow transition broadcasts" do
    test "creating a workflow transition projects one workflow_transition_created through CDC" do
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

      refute_broadcast "workflow_transition_created", _, 50

      assert {:ok, [%{event: "workflow_transition_created"}]} =
               project_insert("workflow_transitions", transition)

      assert_broadcast "workflow_transition_created", payload
      assert payload.id == transition.id
      assert payload.from_workflow_id == workflow1.id
      assert payload.to_workflow_id == workflow2.id
      assert payload.label == "promote"

      refute_broadcast "workflow_transition_created", _, 50
    end

    test "deleting a workflow transition projects workflow_transition_deleted through CDC" do
      {user, project} = setup_channel()

      {:ok, workflow1} = Workflows.insert(project, %{name: "Implementation"})
      {:ok, workflow2} = Workflows.insert(project, %{name: "Review"})

      {:ok, transition} =
        WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "project_id" => project.id
        })

      {:ok, _} = WorkflowTransitions.delete(transition)

      assert {:ok, [%{event: "workflow_transition_deleted"}]} =
               project_delete("workflow_transitions", transition)

      assert_broadcast "workflow_transition_deleted", payload
      assert payload.id == transition.id
      assert payload.from_workflow_id == workflow1.id
      assert payload.to_workflow_id == workflow2.id
    end
  end
end
