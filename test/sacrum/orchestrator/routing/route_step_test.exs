defmodule Sacrum.Orchestrator.Routing.RouteStepTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.ExecutionPool
  alias Sacrum.Orchestrator.TaskRegistry
  alias Sacrum.Orchestrator.Routing.RouteStep
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, TaskRun}
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.TaskRuns.RunControls

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

  defp create_task_run(user, task, attrs \\ %{}) do
    {:ok, task_run} =
      Accounts.TaskRuns.insert(
        user.id,
        task.project_id,
        task.id,
        Map.merge(%{status: :executing}, attrs)
      )

    task_run
  end

  defp subscribe_project(project) do
    Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")
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

    test "commits route decision, task movement, and task run outcome",
         %{pool: pool} do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{auto_advance: false})

      current_step =
        create_step(user, workflow, %{
          "name" => "route_step",
          "step_order" => 1,
          "output_schema" => route_schema_with_handoff(["review"])
        })

      next_step =
        create_step(user, workflow, %{
          "name" => "manual_review",
          "step_order" => 2,
          "is_final" => false
        })

      create_transition(user, current_step, next_step)

      task = create_task(user, project, workflow)

      {:ok, task} =
        Repo.update(Ecto.Changeset.change(task, %{current_step_id: current_step.id}))

      task_run = create_task_run(user, task)

      route_output =
        Jason.encode!(%{
          "transition_to" => next_step.id,
          "transition_type" => "intra_workflow",
          "handoff" => %{"review" => "needed"}
        })

      execution =
        create_step_execution(user, task, workflow, current_step.name, %{
          "status" => "completed",
          "output" => route_output,
          "task_run_id" => task_run.id
        })

      {:ok, slot} = ExecutionPool.request_slot(pool, self(), :infinity)
      subscribe_project(project)

      data = %{
        task: task,
        task_run_id: task_run.id,
        project_id: project.id,
        user_id: user.id,
        steps: %{current_step.id => current_step, next_step.id => next_step},
        workflow: workflow,
        transitions: %{current_step.id => [next_step.id]},
        slot_id: slot,
        pending_handoff: nil
      }

      assert {:stop, :normal, returned_data} =
               RouteStep.handle_route_step_transition(data, current_step)

      assert returned_data.pending_handoff == %{"review" => "needed"}

      updated_task = Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
      assert updated_task.current_step_id == next_step.id

      updated_execution = Repo.get!(Sacrum.Repo.Schemas.StepExecution, execution.id)
      assert updated_execution.transition_result != nil

      assert Jason.decode!(updated_execution.transition_result) == %{
               "dest_id" => next_step.id,
               "transition_type" => "intra_workflow"
             }

      completed_run = Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id)
      assert completed_run.status == :completed
      assert completed_run.outcome_kind == "step_completed"

      assert completed_run.outcome_context == %{
               "reason" => "auto_advance_disabled",
               "current_step_id" => next_step.id
             }

      assert updated_task.current_step_id == next_step.id
    end

    test "intra-workflow route to terminal step completes task and wakes dependents", %{
      pool: pool
    } do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, %{auto_advance: false, is_final: true})
      dependent_workflow = create_workflow(user, project, %{name: "Dependent Workflow"})

      current_step = create_step(user, workflow, %{"name" => "route_step", "step_order" => 1})

      final_step =
        create_step(user, workflow, %{
          "name" => "done",
          "step_order" => 2,
          "is_final" => true
        })

      dependent_step = create_step(user, dependent_workflow, %{"name" => "execute"})

      {:ok, _} =
        Accounts.Workflows.update(dependent_workflow, %{initial_step_id: dependent_step.id})

      create_transition(user, current_step, final_step)

      blocker = create_task(user, project, workflow)

      {:ok, blocker} =
        Repo.update(Ecto.Changeset.change(blocker, %{current_step_id: current_step.id}))

      dependent = create_task(user, project, dependent_workflow)
      {:ok, _dependency} = TaskDependencies.add_dependency(dependent, blocker)

      assert {:ok, controls} = RunControls.for_task(user.id, dependent.id)
      assert controls.runnable == false
      assert controls.disabled_reason_code == "blocked"

      task_run = create_task_run(user, blocker)

      route_output =
        Jason.encode!(%{
          "transition_to" => final_step.id,
          "transition_type" => "intra_workflow"
        })

      _execution =
        create_step_execution(user, blocker, workflow, current_step.name, %{
          "status" => "completed",
          "output" => route_output,
          "task_run_id" => task_run.id
        })

      {:ok, slot} = ExecutionPool.request_slot(pool, self(), :infinity)

      data = %{
        task: blocker,
        task_run_id: task_run.id,
        project_id: project.id,
        user_id: user.id,
        steps: %{current_step.id => current_step, final_step.id => final_step},
        workflow: workflow,
        transitions: %{current_step.id => [final_step.id], final_step.id => []},
        slot_id: slot,
        pending_handoff: nil
      }

      assert {:stop, :normal, _returned_data} =
               RouteStep.handle_route_step_transition(data, current_step)

      completed_task = Repo.get!(Task, blocker.id)
      assert completed_task.current_step_id == final_step.id
      assert completed_task.status == "done"
      assert completed_task.completed_at

      completed_run = Repo.get!(TaskRun, task_run.id)
      assert completed_run.status == :completed
      assert completed_run.outcome_kind == "completed"

      assert completed_run.outcome_context == %{
               "reason" => "terminal_route",
               "current_step_id" => final_step.id
             }

      assert {:ok, controls} = RunControls.for_task(user.id, dependent.id)
      refute controls.disabled_reason_code == "blocked"

      assert [{pid, _}] = Registry.lookup(TaskRegistry, dependent.id)
      GenServer.stop(pid)
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

    test "inter-workflow route to terminal workflow and step completes task and run", %{
      pool: pool
    } do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{name: "From Workflow"})
      done_workflow = create_workflow(user, project, %{name: "Done", is_final: true})

      from_step = create_step(user, from_workflow, %{"name" => "route_step"})

      done_step =
        create_step(user, done_workflow, %{
          "name" => "done",
          "is_final" => true
        })

      create_workflow_transition(user, from_workflow, done_workflow, done_step)

      task = create_task(user, project, from_workflow)
      {:ok, task} = Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))
      task_run = create_task_run(user, task)

      route_output =
        Jason.encode!(%{
          "transition_to" => done_workflow.id,
          "transition_type" => "inter_workflow"
        })

      _execution =
        create_step_execution(user, task, from_workflow, from_step.name, %{
          "status" => "completed",
          "output" => route_output,
          "task_run_id" => task_run.id
        })

      {:ok, slot} = ExecutionPool.request_slot(pool, self(), :infinity)

      data = %{
        task: task,
        task_run_id: task_run.id,
        project_id: project.id,
        user_id: user.id,
        steps: %{from_step.id => from_step},
        workflow: from_workflow,
        transitions: %{from_step.id => []},
        slot_id: slot,
        pending_handoff: nil
      }

      assert {:stop, :normal, returned_data} =
               RouteStep.handle_route_step_transition(data, from_step)

      completed_task = Repo.get!(Task, task.id)
      assert returned_data.task.id == completed_task.id
      assert completed_task.workflow_id == done_workflow.id
      assert completed_task.current_step_id == done_step.id
      assert completed_task.status == "done"
      assert completed_task.completed_at

      completed_run = Repo.get!(TaskRun, task_run.id)
      assert completed_run.status == :completed
      assert completed_run.outcome_kind == "completed"

      assert completed_run.outcome_context == %{
               "reason" => "terminal_route",
               "current_step_id" => done_step.id
             }
    end

    test "terminal inter-workflow completion clears blocker state and wakes dependents", %{
      pool: pool
    } do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{name: "From Workflow"})
      done_workflow = create_workflow(user, project, %{name: "Done", is_final: true})
      dependent_workflow = create_workflow(user, project, %{name: "Dependent Workflow"})

      from_step = create_step(user, from_workflow, %{"name" => "route_step"})
      done_step = create_step(user, done_workflow, %{"name" => "done", "is_final" => true})
      dependent_step = create_step(user, dependent_workflow, %{"name" => "execute"})

      {:ok, _} =
        Accounts.Workflows.update(dependent_workflow, %{initial_step_id: dependent_step.id})

      create_workflow_transition(user, from_workflow, done_workflow, done_step)

      blocker = create_task(user, project, from_workflow)

      {:ok, blocker} =
        Repo.update(Ecto.Changeset.change(blocker, %{current_step_id: from_step.id}))

      dependent = create_task(user, project, dependent_workflow)
      {:ok, _dependency} = TaskDependencies.add_dependency(dependent, blocker)

      assert {:ok, controls} = RunControls.for_task(user.id, dependent.id)
      assert controls.runnable == false
      assert controls.disabled_reason_code == "blocked"

      task_run = create_task_run(user, blocker)

      route_output =
        Jason.encode!(%{
          "transition_to" => done_workflow.id,
          "transition_type" => "inter_workflow"
        })

      _execution =
        create_step_execution(user, blocker, from_workflow, from_step.name, %{
          "status" => "completed",
          "output" => route_output,
          "task_run_id" => task_run.id
        })

      {:ok, slot} = ExecutionPool.request_slot(pool, self(), :infinity)

      data = %{
        task: blocker,
        task_run_id: task_run.id,
        project_id: project.id,
        user_id: user.id,
        steps: %{from_step.id => from_step},
        workflow: from_workflow,
        transitions: %{from_step.id => []},
        slot_id: slot,
        pending_handoff: nil
      }

      assert {:stop, :normal, _returned_data} =
               RouteStep.handle_route_step_transition(data, from_step)

      assert Repo.get!(Task, blocker.id).completed_at

      assert {:ok, controls} = RunControls.for_task(user.id, dependent.id)
      refute controls.disabled_reason_code == "blocked"

      assert [{pid, _}] = Registry.lookup(TaskRegistry, dependent.id)
      GenServer.stop(pid)
    end

    test "inter-workflow route to non-terminal target keeps step-completed stop", %{pool: pool} do
      user = create_user()
      project = create_project(user)
      from_workflow = create_workflow(user, project, %{name: "From Workflow"})
      to_workflow = create_workflow(user, project, %{name: "To Workflow", is_final: true})

      from_step = create_step(user, from_workflow, %{"name" => "route_step"})
      to_step = create_step(user, to_workflow, %{"name" => "review", "is_final" => false})
      create_workflow_transition(user, from_workflow, to_workflow, to_step)

      task = create_task(user, project, from_workflow)
      {:ok, task} = Repo.update(Ecto.Changeset.change(task, %{current_step_id: from_step.id}))
      task_run = create_task_run(user, task)

      route_output =
        Jason.encode!(%{
          "transition_to" => to_workflow.id,
          "transition_type" => "inter_workflow"
        })

      _execution =
        create_step_execution(user, task, from_workflow, from_step.name, %{
          "status" => "completed",
          "output" => route_output,
          "task_run_id" => task_run.id
        })

      {:ok, slot} = ExecutionPool.request_slot(pool, self(), :infinity)

      data = %{
        task: task,
        task_run_id: task_run.id,
        project_id: project.id,
        user_id: user.id,
        steps: %{from_step.id => from_step},
        workflow: from_workflow,
        transitions: %{from_step.id => []},
        slot_id: slot,
        pending_handoff: nil
      }

      assert {:stop, :normal, _returned_data} =
               RouteStep.handle_route_step_transition(data, from_step)

      updated_task = Repo.get!(Task, task.id)
      assert updated_task.completed_at == nil
      assert updated_task.status == "ready"

      completed_run = Repo.get!(TaskRun, task_run.id)
      assert completed_run.status == :completed
      assert completed_run.outcome_kind == "step_completed"
      assert completed_run.outcome_context["reason"] == "auto_advance_disabled"
      assert completed_run.outcome_context["current_step_id"] == to_step.id
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

  defp create_workflow_transition(user, from_workflow, to_workflow, target_step) do
    {:ok, transition} =
      Accounts.WorkflowTransitions.insert(user.id, %{
        "from_workflow_id" => from_workflow.id,
        "to_workflow_id" => to_workflow.id,
        "project_id" => from_workflow.project_id,
        "label" => "transition",
        "target_step_id" => target_step.id
      })

    transition
  end
end
