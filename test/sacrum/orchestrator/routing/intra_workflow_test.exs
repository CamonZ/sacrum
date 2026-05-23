defmodule Sacrum.Orchestrator.Routing.IntraWorkflowTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.Routing.IntraWorkflow
  alias Sacrum.Repo

  # ===== Setup helpers =====

  defp create_user do
    unique_suffix = :erlang.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "intra_workflow_test_#{unique_suffix}@example.com",
        username: "intra_workflow_test_#{unique_suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    unique_suffix = :erlang.unique_integer([:positive])

    {:ok, project} =
      Accounts.Projects.insert(user.id, %{name: "IW Test Project #{unique_suffix}"})

    project
  end

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Test Workflow"
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

  defp create_transition(user, from_step, to_step) do
    {:ok, _transition} =
      Accounts.StepTransitions.insert(user.id, %{
        "from_step_id" => from_step.id,
        "to_step_id" => to_step.id,
        "project_id" => from_step.project_id,
        "label" => "next"
      })
  end

  # ===== Tests =====

  describe "validate_destination_step/2" do
    test "returns ok with step when destination is valid and in same project/user" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      dest_step = create_step(user, workflow, %{"name" => "dest_step"})

      data = %{project_id: project.id, user_id: user.id}

      result = IntraWorkflow.validate_destination_step(data, dest_step.id)

      assert {:ok, step} = result
      assert step.id == dest_step.id
    end

    test "returns error when destination step not found" do
      user = create_user()
      project = create_project(user)

      data = %{project_id: project.id, user_id: user.id}

      # Use a valid UUID that doesn't exist
      fake_id = Ecto.UUID.generate()

      result = IntraWorkflow.validate_destination_step(data, fake_id)

      assert result == {:error, :destination_step_not_found}
    end

    test "returns error when destination step belongs to different project" do
      user = create_user()
      project1 = create_project(user)
      project2 = create_project(user)
      _workflow1 = create_workflow(user, project1)
      workflow2 = create_workflow(user, project2)
      step_in_project2 = create_step(user, workflow2, %{})

      data = %{project_id: project1.id, user_id: user.id}

      result = IntraWorkflow.validate_destination_step(data, step_in_project2.id)

      assert result == {:error, :destination_step_cross_project_or_user}
    end

    test "returns error when destination step belongs to different user" do
      user1 = create_user()
      user2 = create_user()
      project1 = create_project(user1)
      project2 = create_project(user2)
      _workflow1 = create_workflow(user1, project1)
      workflow2 = create_workflow(user2, project2)
      step_in_user2 = create_step(user2, workflow2, %{})

      data = %{project_id: project1.id, user_id: user1.id}

      result = IntraWorkflow.validate_destination_step(data, step_in_user2.id)

      assert result == {:error, :destination_step_cross_project_or_user}
    end
  end

  describe "validate_step_transition_exists/2" do
    test "returns ok when transition exists" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      from_step = create_step(user, workflow, %{"name" => "from", "step_order" => 1})
      to_step = create_step(user, workflow, %{"name" => "to", "step_order" => 2})
      create_transition(user, from_step, to_step)

      result = IntraWorkflow.validate_step_transition_exists(from_step.id, to_step.id)

      assert result == :ok
    end

    test "returns error when transition does not exist" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      from_step = create_step(user, workflow, %{"name" => "from", "step_order" => 1})
      to_step = create_step(user, workflow, %{"name" => "to", "step_order" => 2})

      result = IntraWorkflow.validate_step_transition_exists(from_step.id, to_step.id)

      assert result == {:error, :no_step_transition}
    end
  end

  describe "handle_intra_workflow_routing/3" do
    test "routes task to destination step when all validations pass" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      from_step = create_step(user, workflow, %{"name" => "from", "step_order" => 1})
      to_step = create_step(user, workflow, %{"name" => "to", "step_order" => 2})
      create_transition(user, from_step, to_step)

      task = create_task(user, project, workflow)
      # Manually set current step
      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))

      data = %{
        task: task,
        project_id: project.id,
        user_id: user.id,
        steps: %{from_step.id => from_step, to_step.id => to_step}
      }

      handoff = %{"key" => "value"}

      result = IntraWorkflow.handle_intra_workflow_routing(data, to_step.id, handoff)

      assert {:ok, updated_task} = result
      assert updated_task.current_step_id == to_step.id
    end

    test "returns error when destination step validation fails" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      from_step = create_step(user, workflow, %{"name" => "from", "step_order" => 1})

      task = create_task(user, project, workflow)

      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))

      data = %{
        task: task,
        project_id: project.id,
        user_id: user.id,
        steps: %{from_step.id => from_step}
      }

      # Use a valid UUID that doesn't exist
      fake_id = Ecto.UUID.generate()

      result = IntraWorkflow.handle_intra_workflow_routing(data, fake_id, nil)

      assert {:error, :destination_step_not_found} = result
    end

    test "returns error when transition does not exist" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      from_step = create_step(user, workflow, %{"name" => "from", "step_order" => 1})
      to_step = create_step(user, workflow, %{"name" => "to", "step_order" => 2})

      task = create_task(user, project, workflow)

      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))

      data = %{
        task: task,
        project_id: project.id,
        user_id: user.id,
        steps: %{from_step.id => from_step, to_step.id => to_step}
      }

      result = IntraWorkflow.handle_intra_workflow_routing(data, to_step.id, nil)

      assert {:error, :no_step_transition} = result
    end
  end

  describe "handle_intra_route_continuation/2" do
    test "determines next state for intra-workflow routing" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      from_step = create_step(user, workflow, %{"name" => "from", "step_order" => 1})

      to_step =
        create_step(user, workflow, %{"name" => "to", "step_order" => 2, "is_final" => false})

      task = create_task(user, project, workflow)

      {:ok, updated_task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: to_step.id}))

      data = %{
        task: task,
        steps: %{from_step.id => from_step, to_step.id => to_step},
        workflow: workflow,
        project_id: project.id,
        user_id: user.id,
        slot_id: nil
      }

      result = IntraWorkflow.handle_intra_route_continuation(data, updated_task)

      # The result is a state transition tuple from TaskCompletion.determine_next_state
      assert is_tuple(result)
      assert tuple_size(result) >= 2
    end
  end
end
