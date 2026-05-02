defmodule Sacrum.Orchestrator.Routing.RouteStepTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.ExecutionPool
  alias Sacrum.Orchestrator.Routing.RouteStep
  alias Sacrum.Repo

  # ===== Setup helpers =====

  defp create_user do
    {:ok, user} =
      Repo.Users.insert(%{
        email: "route_step_test@example.com",
        username: "route_step_test",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "RS Test Project"})
    project
  end

  defp create_workflow(user, project, attrs \\ %{}) do
    default_attrs = %{
      name: "Test Workflow",
      auto_advance: false
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

  defp create_transition(user, from_step, to_step) do
    {:ok, _transition} =
      Accounts.StepTransitions.insert(user.id, %{
        "from_step_id" => from_step.id,
        "to_step_id" => to_step.id,
        "project_id" => from_step.project_id,
        "label" => "next"
      })
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

  defp create_step_execution(user, task, workflow, step_name, attrs) do
    default_attrs = %{
      "task_id" => task.id,
      "project_id" => task.project_id,
      "workflow_id" => workflow.id,
      "step_name" => step_name,
      "status" => "completed"
    }

    {:ok, execution} =
      Accounts.StepExecutions.insert(user.id, Map.merge(default_attrs, attrs))

    execution
  end

  # ===== Tests =====

  describe "handle_route_step_transition/2" do
    setup do
      # Start an isolated pool instance so tests don't conflict with the global pool
      pool = :"route_step_pool_#{System.unique_integer([:positive])}"
      {:ok, pid} = ExecutionPool.start_link(name: pool)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pool: pool}
    end

    test "intra-workflow happy path: routes to non-final step and auto-advances", %{pool: pool} do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{auto_advance: true})
      current_step = create_step(user, workflow, %{"name" => "step_1", "step_order" => 1})

      next_step =
        create_step(user, workflow, %{"name" => "step_2", "step_order" => 2, "is_final" => false})

      create_transition(user, current_step, next_step)

      task = create_task(user, project, workflow)

      # Set current step
      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: current_step.id}))

      # Create a completed execution with intra-workflow route output
      route_output =
        Jason.encode!(%{
          "transition_to" => next_step.id,
          "transition_type" => "intra_workflow"
        })

      _execution =
        create_step_execution(user, task, workflow, current_step.name, %{
          "status" => "completed",
          "output" => route_output
        })

      # Request a slot to simulate FSM context
      {:ok, slot} = ExecutionPool.request_slot(pool, self(), :infinity)

      # Build FSM data
      data = %{
        task: task,
        project_id: project.id,
        user_id: user.id,
        steps: %{current_step.id => current_step, next_step.id => next_step},
        workflow: workflow,
        transitions: %{current_step.id => [next_step.id]},
        slot_id: slot,
        pending_handoff: nil
      }

      result = RouteStep.handle_route_step_transition(data, current_step)

      updated_task = Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
      assert updated_task.current_step_id == next_step.id
      assert is_tuple(result)

      case result do
        {:next_state, new_state, _returned_data} ->
          assert new_state in [:awaiting_execution, :completing]

        {:stop, :normal, _returned_data} ->
          :ok

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "inter-workflow happy path: routes task to destination workflow", %{pool: pool} do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{name: "From Workflow"})
      to_workflow = create_workflow(user, project, %{name: "To Workflow"})

      from_step = create_step(user, from_workflow, %{"name" => "from_step"})
      to_step = create_step(user, to_workflow, %{"name" => "to_step"})

      # Create workflow transition
      {:ok, _transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => from_workflow.id,
          "to_workflow_id" => to_workflow.id,
          "project_id" => from_workflow.project_id,
          "label" => "transition",
          "target_step_id" => to_step.id
        })

      task = create_task(user, project, from_workflow)

      # Set current step
      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))

      # Create a completed execution with inter-workflow route output
      route_output =
        Jason.encode!(%{
          "transition_to" => to_workflow.id,
          "transition_type" => "inter_workflow"
        })

      _execution =
        create_step_execution(user, task, from_workflow, from_step.name, %{
          "status" => "completed",
          "output" => route_output
        })

      # Request a slot to simulate FSM context
      {:ok, slot} = ExecutionPool.request_slot(pool, self(), :infinity)

      # Build FSM data
      data = %{
        task: task,
        project_id: project.id,
        user_id: user.id,
        steps: %{from_step.id => from_step, to_step.id => to_step},
        workflow: from_workflow,
        transitions: %{from_step.id => []},
        slot_id: slot,
        pending_handoff: nil
      }

      result = RouteStep.handle_route_step_transition(data, from_step)

      updated_task = Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
      assert updated_task.workflow_id == to_workflow.id
      assert updated_task.current_step_id == to_step.id
      assert is_tuple(result)

      case result do
        {:next_state, new_state, _returned_data} ->
          assert new_state in [:awaiting_execution, :completing]

        {:stop, :normal, _returned_data} ->
          :ok

        other ->
          flunk("Unexpected result: #{inspect(other)}")
      end
    end

    test "invalid output format: missing transition_type leads to failed state", %{pool: pool} do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      current_step = create_step(user, workflow, %{"name" => "step_1"})
      task = create_task(user, project, workflow)

      # Set current step
      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: current_step.id}))

      # Create a completed execution with invalid route output (missing transition_type)
      route_output =
        Jason.encode!(%{
          "transition_to" => "some_step"
        })

      _execution =
        create_step_execution(user, task, workflow, current_step.name, %{
          "status" => "completed",
          "output" => route_output
        })

      # Request a slot to simulate FSM context
      {:ok, slot} = ExecutionPool.request_slot(pool, self(), :infinity)

      # Build FSM data
      data = %{
        task: task,
        project_id: project.id,
        user_id: user.id,
        steps: %{current_step.id => current_step},
        workflow: workflow,
        slot_id: slot,
        pending_handoff: nil
      }

      # Call the handler
      result = RouteStep.handle_route_step_transition(data, current_step)

      # Verify the result is a failed state transition
      assert result == {:next_state, :failed, %{data | slot_id: nil}}
    end
  end
end
