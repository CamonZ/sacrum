defmodule Sacrum.Orchestrator.Routing.InterWorkflowTest do
  use Sacrum.DataCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.Routing.InterWorkflow
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Workflow, WorkflowStep, WorkflowTransition}

  # ===== Setup helpers =====

  defp create_user do
    unique_suffix = :erlang.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "inter_workflow_test_#{unique_suffix}@example.com",
        username: "inter_workflow_test_#{unique_suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    unique_suffix = :erlang.unique_integer([:positive])

    {:ok, project} =
      Accounts.Projects.insert(user.id, %{name: "EW Test Project #{unique_suffix}"})

    project
  end

  defp create_workflow(user, project, attrs \\ %{}) do
    default_attrs = %{
      "name" => "Test Workflow",
      "auto_advance" => false
    }

    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, Map.merge(default_attrs, attrs))

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

  defp create_workflow_transition(user, from_workflow, to_workflow, attrs \\ %{}) do
    default_attrs = %{
      "from_workflow_id" => from_workflow.id,
      "to_workflow_id" => to_workflow.id,
      "project_id" => from_workflow.project_id,
      "label" => "transition"
    }

    {:ok, transition} =
      Accounts.WorkflowTransitions.insert(user.id, Map.merge(default_attrs, attrs))

    transition
  end

  # ===== Tests =====

  describe "validate_destination_workflow/2" do
    test "returns ok with workflow when destination is valid and in same project/user" do
      user = create_user()
      project = create_project(user)
      dest_workflow = create_workflow(user, project)

      data = %{project_id: project.id, user_id: user.id}

      result = InterWorkflow.validate_destination_workflow(data, dest_workflow.id)

      assert {:ok, workflow} = result
      assert workflow.id == dest_workflow.id
    end

    test "returns error when destination workflow not found" do
      user = create_user()
      project = create_project(user)

      data = %{project_id: project.id, user_id: user.id}

      # Use a valid UUID that doesn't exist
      fake_id = Ecto.UUID.generate()

      result = InterWorkflow.validate_destination_workflow(data, fake_id)

      assert result == {:error, :destination_workflow_not_found}
    end

    test "returns error when destination workflow belongs to different project" do
      user = create_user()
      project1 = create_project(user)
      project2 = create_project(user)
      workflow_in_project2 = create_workflow(user, project2)

      data = %{project_id: project1.id, user_id: user.id}

      result = InterWorkflow.validate_destination_workflow(data, workflow_in_project2.id)

      assert result == {:error, :destination_workflow_cross_project_or_user}
    end

    test "returns error when destination workflow belongs to different user" do
      user1 = create_user()
      user2 = create_user()
      project1 = create_project(user1)
      project2 = create_project(user2)
      workflow_in_user2 = create_workflow(user2, project2)

      data = %{project_id: project1.id, user_id: user1.id}

      result = InterWorkflow.validate_destination_workflow(data, workflow_in_user2.id)

      assert result == {:error, :destination_workflow_cross_project_or_user}
    end
  end

  describe "validate_workflow_transition_exists/2" do
    test "returns ok when transition exists" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From Workflow"})
      to_workflow = create_workflow(user, project, %{"name" => "To Workflow"})
      create_workflow_transition(user, from_workflow, to_workflow)

      result = InterWorkflow.validate_workflow_transition_exists(from_workflow.id, to_workflow.id)

      assert result == :ok
    end

    test "returns error when transition does not exist" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From Workflow"})
      to_workflow = create_workflow(user, project, %{"name" => "To Workflow"})

      result = InterWorkflow.validate_workflow_transition_exists(from_workflow.id, to_workflow.id)

      assert result == {:error, :no_workflow_transition}
    end
  end

  describe "get_target_step_for_workflow_transition/2" do
    test "returns target_step_id when transition has explicit target" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From"})
      to_workflow = create_workflow(user, project, %{"name" => "To"})
      target_step = create_step(user, to_workflow, %{"name" => "target_step"})

      _transition =
        create_workflow_transition(user, from_workflow, to_workflow, %{
          "target_step_id" => target_step.id
        })

      data = %{task: %{workflow_id: from_workflow.id}}

      result = InterWorkflow.get_target_step_for_workflow_transition(data, to_workflow.id)

      assert result == target_step.id
    end

    test "returns nil when transition has no explicit target" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From"})
      to_workflow = create_workflow(user, project, %{"name" => "To"})

      create_workflow_transition(user, from_workflow, to_workflow)

      data = %{task: %{workflow_id: from_workflow.id}}

      result = InterWorkflow.get_target_step_for_workflow_transition(data, to_workflow.id)

      assert result == nil
    end
  end

  describe "resolve_target_step/2" do
    test "returns ok with explicit target step when target_step_id is provided" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      target_step = create_step(user, workflow, %{"name" => "target"})

      result = InterWorkflow.resolve_target_step(workflow, target_step.id)

      assert {:ok, step} = result
      assert step.id == target_step.id
    end

    test "returns error when explicit target_step_id is not found" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      # Use a valid UUID that doesn't exist
      fake_id = Ecto.UUID.generate()

      result = InterWorkflow.resolve_target_step(workflow, fake_id)

      assert result == {:error, :target_step_not_found}
    end

    test "returns initial step when target_step_id is nil and initial_step_id is set" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      initial_step = create_step(user, workflow, %{"name" => "initial", "step_order" => 1})

      {:ok, workflow_updated} =
        Accounts.Workflows.update(workflow, %{initial_step_id: initial_step.id})

      workflow_with_steps = Repo.preload(workflow_updated, :workflow_steps)

      result = InterWorkflow.resolve_target_step(workflow_with_steps, nil)

      assert {:ok, step} = result
      assert step.id == initial_step.id
    end

    test "returns first step by step_order when target_step_id is nil and no initial_step_id" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      step1 = create_step(user, workflow, %{"name" => "step1", "step_order" => 1})
      step2 = create_step(user, workflow, %{"name" => "step2", "step_order" => 2})

      workflow_with_steps = Repo.preload(workflow, :workflow_steps)

      result = InterWorkflow.resolve_target_step(workflow_with_steps, nil)

      assert {:ok, step} = result
      assert step.id == step1.id
    end

    test "returns error when workflow has no steps" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      workflow_with_steps = Repo.preload(workflow, :workflow_steps)

      result = InterWorkflow.resolve_target_step(workflow_with_steps, nil)

      assert result == {:error, :destination_workflow_has_no_steps}
    end

    test "returns error when initial_step_id is not found" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      # Set initial_step_id to a non-existent step (use a valid UUID format)
      fake_id = "00000000-0000-0000-0000-000000000000"

      {:ok, workflow_with_initial} =
        Repo.update(Ecto.Changeset.change(workflow, %{initial_step_id: fake_id}))

      workflow_with_steps = Repo.preload(workflow_with_initial, :workflow_steps)

      result = InterWorkflow.resolve_target_step(workflow_with_steps, nil)

      assert result == {:error, :initial_step_not_found}
    end
  end

  describe "assign_destination_workflow/4" do
    test "updates task and creates entered execution for inter-workflow routing" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From"})
      to_workflow = create_workflow(user, project, %{"name" => "To"})

      from_step = create_step(user, from_workflow, %{"name" => "from_step"})
      to_step = create_step(user, to_workflow, %{"name" => "to_step"})

      task = create_task(user, project, from_workflow)

      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))

      handoff = %{"key" => "value"}

      result = InterWorkflow.assign_destination_workflow(task, to_workflow, to_step.id, handoff)

      assert {:ok, updated_task} = result
      assert updated_task.workflow_id == to_workflow.id
      assert updated_task.current_step_id == to_step.id
    end

    test "creates entered execution with handoff" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From"})
      to_workflow = create_workflow(user, project, %{"name" => "To"})

      from_step = create_step(user, from_workflow, %{"name" => "from_step"})
      to_step = create_step(user, to_workflow, %{"name" => "to_step"})

      task = create_task(user, project, from_workflow)

      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))

      handoff = %{"key" => "value"}

      {:ok, _updated_task} =
        InterWorkflow.assign_destination_workflow(task, to_workflow, to_step.id, handoff)

      # Verify entered execution was created
      executions =
        from(e in Sacrum.Repo.Schemas.StepExecution,
          where: e.task_id == ^task.id and e.status == "entered"
        )
        |> Repo.all()

      assert length(executions) >= 1
      execution = List.last(executions)
      assert execution.handoff == handoff
    end

    test "resolves to initial step when target_step_id is nil" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From"})
      to_workflow = create_workflow(user, project, %{"name" => "To"})

      from_step = create_step(user, from_workflow, %{"name" => "from_step"})
      initial_step = create_step(user, to_workflow, %{"name" => "initial", "step_order" => 1})

      {:ok, to_workflow} =
        Accounts.Workflows.update(to_workflow, %{initial_step_id: initial_step.id})

      task = create_task(user, project, from_workflow)

      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))

      result = InterWorkflow.assign_destination_workflow(task, to_workflow, nil, nil)

      assert {:ok, updated_task} = result
      assert updated_task.current_step_id == initial_step.id
    end
  end

  describe "handle_inter_workflow_routing/3" do
    test "routes task to destination workflow when all validations pass" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From"})
      to_workflow = create_workflow(user, project, %{"name" => "To"})

      from_step = create_step(user, from_workflow, %{"name" => "from_step"})
      to_step = create_step(user, to_workflow, %{"name" => "to_step"})

      create_workflow_transition(user, from_workflow, to_workflow, %{
        "target_step_id" => to_step.id
      })

      task = create_task(user, project, from_workflow)

      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))

      data = %{
        task: task,
        project_id: project.id,
        user_id: user.id
      }

      result = InterWorkflow.handle_inter_workflow_routing(data, to_workflow.id, nil)

      assert {:ok, updated_task} = result
      assert updated_task.workflow_id == to_workflow.id
      assert updated_task.current_step_id == to_step.id
    end

    test "returns error when destination workflow validation fails" do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{"name" => "From"})
      _step = create_step(user, from_workflow, %{"name" => "step1"})

      task = create_task(user, project, from_workflow)

      data = %{
        task: task,
        project_id: project.id,
        user_id: user.id
      }

      # Use a valid UUID that doesn't exist
      fake_id = Ecto.UUID.generate()

      result = InterWorkflow.handle_inter_workflow_routing(data, fake_id, nil)

      assert {:error, :destination_workflow_not_found} = result
    end
  end
end
