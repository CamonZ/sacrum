defmodule Sacrum.Orchestrator.TaskOrchestratorTest do
  use Sacrum.DataCase, async: false

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.TaskOrchestrator
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

  # ===== Setup helpers =====

  defp create_user(attrs \\ %{}) do
    default_attrs = %{
      email: "test@example.com",
      username: "testuser",
      password: "password123"
    }

    {:ok, user} = Sacrum.Repo.Users.insert(Map.merge(default_attrs, attrs))
    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
    project
  end

  defp create_workflow(user, project, opts) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: Keyword.get(opts, :name, "Test Workflow"),
        auto_advance: Keyword.get(opts, :auto_advance, false)
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
      "prompt" => "Run step for task {task_id}"
    }

    merged_attrs = Map.merge(default_attrs, stringify_attrs(attrs))
    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, merged_attrs)
    step
  end

  defp stringify_attrs(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp create_transition(user, from_step, to_step, label \\ "next") do
    {:ok, transition} =
      Accounts.StepTransitions.insert(user.id, %{
        "from_step_id" => from_step.id,
        "to_step_id" => to_step.id,
        "project_id" => from_step.project_id,
        "label" => label
      })

    transition
  end

  defp create_task(user, project, attrs \\ %{}) do
    default_attrs = %{
      title: "Test Task",
      description: "Test description",
      level: "medium",
      priority: "normal",
      tags: ["test"]
    }

    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, Map.merge(default_attrs, attrs))
    task
  end

  defp assign_workflow_to_task(task, workflow) do
    {:ok, updated_task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)
    updated_task
  end

  defp setup_linear_workflow(opts) do
    auto_advance = Keyword.get(opts, :auto_advance, true)
    step_count = Keyword.get(opts, :step_count, 3)

    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project, auto_advance: auto_advance)

    steps =
      for i <- 1..step_count do
        create_step(user, workflow, %{
          name: "step_#{i}",
          step_order: i,
          is_final: i == step_count
        })
      end

    # Create linear transitions
    steps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [from, to] -> create_transition(user, from, to) end)

    first_step = hd(steps)
    {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: first_step.id})

    task = create_task(user, project)
    task = assign_workflow_to_task(task, workflow)

    %{user: user, project: project, workflow: workflow, steps: steps, task: task}
  end

  # ===== FSM interaction helpers =====

  defp start_orchestrator(task, user) do
    {:ok, pid} = TaskOrchestrator.start_link(task_id: task.id, user_id: user.id)
    pid
  end

  defp wait_for_state(pid, expected_state, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_state(pid, expected_state, deadline)
  end

  defp do_wait_for_state(pid, expected_state, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      if Process.alive?(pid) do
        {state, _data} = :sys.get_state(pid)
        flunk("Timed out waiting for #{inspect(expected_state)}, FSM is in #{inspect(state)}")
      else
        flunk("Timed out waiting for #{inspect(expected_state)}, process has exited")
      end
    end

    if Process.alive?(pid) do
      case :sys.get_state(pid) do
        {^expected_state, _data} ->
          :ok

        _ ->
          Process.sleep(10)
          do_wait_for_state(pid, expected_state, deadline)
      end
    else
      if expected_state in [:completed, :failed] do
        # These terminal states stop the process, so exiting is expected
        :ok
      else
        flunk("Process exited while waiting for #{inspect(expected_state)}")
      end
    end
  end

  defp wait_for_exit(pid, timeout \\ 2000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      timeout -> flunk("Timed out waiting for process to exit")
    end
  end

  defp simulate_daemon_completion(task_id, project_id, output \\ "step completed") do
    execution = get_latest_entered_execution(task_id)

    # Simulate what the daemon does: update status to "completed" with output
    {:ok, updated} =
      execution
      |> StepExecution.update_changeset(%{status: "completed", output: output})
      |> Repo.update()

    # The update broadcasts via Broadcaster -> ProjectChannel, but the orchestrator
    # subscribes via Phoenix.PubSub. Broadcast directly to ensure delivery.
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_execution_status_changed",
      %{id: updated.id, status: "completed", output: output}
    )

    updated
  end

  defp simulate_daemon_failure(task_id, project_id) do
    execution = get_latest_entered_execution(task_id)

    {:ok, updated} =
      execution
      |> StepExecution.update_changeset(%{status: "failed", output: "daemon error"})
      |> Repo.update()

    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_execution_status_changed",
      %{id: updated.id, status: "failed", output: "daemon error"}
    )

    updated
  end

  defp get_latest_entered_execution(task_id) do
    from(e in StepExecution,
      where: e.task_id == ^task_id and e.status == "entered",
      order_by: [desc: e.inserted_at],
      limit: 1
    )
    |> Repo.one!()
  end

  defp get_all_executions(task_id) do
    from(e in StepExecution,
      where: e.task_id == ^task_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  defp reload_task(task) do
    Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
  end

  # ===== Tests =====

  describe "single-step workflow" do
    test "completes a single final step" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_completion(task.id, project.id)
      wait_for_exit(pid)

      task = reload_task(task)
      assert task.completed_at != nil

      executions = get_all_executions(task.id)
      assert length(executions) == 1
      assert hd(executions).status == "completed"
      assert hd(executions).step_name == "step_1"
    end
  end

  describe "multi-step auto-advance workflow" do
    test "advances through all steps to completion" do
      %{user: user, project: project, steps: [s1, s2, _s3], task: task} =
        setup_linear_workflow(auto_advance: true, step_count: 3)

      pid = start_orchestrator(task, user)

      # Step 1: executing
      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s1.id
      simulate_daemon_completion(task.id, project.id, "step 1 done")

      # Step 2: auto-advances to awaiting_execution -> executing
      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s2.id
      simulate_daemon_completion(task.id, project.id, "step 2 done")

      # Step 3 is final -> completing -> completed -> process exits
      wait_for_exit(pid)

      task = reload_task(task)
      assert task.completed_at != nil
    end

    test "creates step executions for each step" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(auto_advance: true, step_count: 3)

      pid = start_orchestrator(task, user)

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)

      wait_for_exit(pid)

      executions = get_all_executions(task.id)
      step_names = Enum.map(executions, & &1.step_name)

      # assign_workflow creates "entered" for step_1,
      # advance_to_step creates "entered" for step_2 and step_3
      assert "step_1" in step_names
      assert "step_2" in step_names
      assert "step_3" in step_names
    end

    test "updates task current_step_id at each transition" do
      %{user: user, project: project, steps: [s1, s2, _s3], task: task} =
        setup_linear_workflow(auto_advance: true, step_count: 3)

      pid = start_orchestrator(task, user)

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s1.id

      simulate_daemon_completion(task.id, project.id)
      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s2.id

      simulate_daemon_completion(task.id, project.id)
      wait_for_exit(pid)
    end
  end

  describe "non-auto-advance workflow" do
    test "stops after completing and transitioning to next step" do
      %{user: user, project: project, steps: [_s1, s2, _s3], task: task} =
        setup_linear_workflow(auto_advance: false, step_count: 3)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_completion(task.id, project.id)
      wait_for_exit(pid)

      # Task should have advanced to step 2 but orchestrator stopped
      assert reload_task(task).current_step_id == s2.id
      # Task should NOT be completed
      assert reload_task(task).completed_at == nil
    end
  end

  describe "execution failure" do
    test "transitions to failed when daemon reports failure" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_failure(task.id, project.id)
      wait_for_exit(pid)

      task = reload_task(task)
      assert task.completed_at == nil

      executions = get_all_executions(task.id)
      latest = List.last(executions)
      assert latest.status == "failed"
      assert latest.step_name == "step_1"
    end
  end

  describe "PubSub filtering" do
    test "ignores status changes for other execution IDs" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Send a completion for a different execution ID
      SacrumWeb.Endpoint.broadcast(
        "project:#{project.id}",
        "step_execution_status_changed",
        %{id: Ecto.UUID.generate(), status: "completed", output: "wrong exec"}
      )

      # FSM should still be in :executing (it ignored the message)
      Process.sleep(50)
      assert {:executing, _} = :sys.get_state(pid)

      # Now send the real completion
      simulate_daemon_completion(task.id, project.id)
      wait_for_exit(pid)
    end
  end

  describe "route step with intra-workflow transition" do
    test "routes task to destination step within same workflow" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, auto_advance: false)

      # Create steps: route_step -> dest_step (no connection), plus other_step for structure
      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: false,
          step_type: "execute"
        })

      other_step =
        create_step(user, workflow, %{
          name: "other_step",
          step_order: 3,
          is_final: true,
          step_type: "execute"
        })

      # Create transitions: route -> dest, route -> other (but we'll route to dest)
      create_transition(user, route_step, dest_step, "to_dest")
      create_transition(user, route_step, other_step, "to_other")

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Step should be the route_step
      assert reload_task(task).current_step_id == route_step.id

      # Simulate route step output routing to dest_step
      route_output =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow"
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      # Orchestrator should stop (no auto_advance)
      wait_for_exit(pid)

      # Task should now be at dest_step
      task = reload_task(task)
      assert task.current_step_id == dest_step.id
      assert task.completed_at == nil
    end

    test "fails when route step output has invalid destination in same workflow" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      # Create transition route -> dest
      create_transition(user, route_step, dest_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Simulate route step output routing to nonexistent step (no transition)
      bad_step_id = Ecto.UUID.generate()

      route_output =
        Jason.encode!(%{
          "transition_to" => bad_step_id,
          "transition_type" => "intra_workflow"
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      wait_for_exit(pid)

      # Task should still be at route_step (not transitioned)
      task = reload_task(task)
      assert task.current_step_id == route_step.id
    end
  end

  describe "route step with inter-workflow transition" do
    test "routes task to destination workflow with default initial step" do
      user = create_user()
      project = create_project(user)

      # Workflow 1: has route step
      workflow1 = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: has multiple steps
      workflow2 = create_workflow(user, project, auto_advance: false)

      step2_1 =
        create_step(user, workflow2, %{
          name: "step2_1",
          step_order: 1,
          is_final: false,
          step_type: "execute"
        })

      _step2_2 =
        create_step(user, workflow2, %{
          name: "step2_2",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      {:ok, _} = Accounts.Workflows.update(workflow2, %{initial_step_id: step2_1.id})

      # Create inter-workflow transition
      {:ok, _transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "project_id" => project.id
        })

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      assert reload_task(task).current_step_id == route_step.id
      assert reload_task(task).workflow_id == workflow1.id

      # Simulate route step output routing inter-workflow
      route_output =
        Jason.encode!(%{
          "transition_to" => workflow2.id,
          "transition_type" => "inter_workflow"
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      wait_for_exit(pid)

      # Task should now be in workflow2, at its initial step
      task = reload_task(task)
      assert task.workflow_id == workflow2.id
      assert task.current_step_id == step2_1.id
      assert task.completed_at == nil
    end

    test "routes task to destination workflow with target step override" do
      user = create_user()
      project = create_project(user)

      # Workflow 1: has route step
      workflow1 = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: has multiple steps
      workflow2 = create_workflow(user, project, auto_advance: false)

      step2_1 =
        create_step(user, workflow2, %{
          name: "step2_1",
          step_order: 1,
          is_final: false,
          step_type: "execute"
        })

      step2_2 =
        create_step(user, workflow2, %{
          name: "step2_2",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      {:ok, _} = Accounts.Workflows.update(workflow2, %{initial_step_id: step2_1.id})

      # Create inter-workflow transition with target_step override
      {:ok, _transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "target_step_id" => step2_2.id,
          "project_id" => project.id
        })

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Simulate route step output routing inter-workflow
      route_output =
        Jason.encode!(%{
          "transition_to" => workflow2.id,
          "transition_type" => "inter_workflow"
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      wait_for_exit(pid)

      # Task should now be in workflow2, at the target step
      task = reload_task(task)
      assert task.workflow_id == workflow2.id
      assert task.current_step_id == step2_2.id
      assert task.completed_at != nil
    end

    test "fails when route output references workflow in different project" do
      user1 = create_user(%{email: "user1@example.com", username: "user1"})
      user2 = create_user(%{email: "user2@example.com", username: "user2"})
      project1 = create_project(user1)
      project2 = create_project(user2)

      # Workflow 1 in project1
      workflow1 = create_workflow(user1, project1, auto_advance: false)

      route_step =
        create_step(user1, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2 in project2 (different project!)
      workflow2 = create_workflow(user2, project2, auto_advance: false)

      step2 =
        create_step(user2, workflow2, %{
          name: "step2",
          step_order: 1,
          is_final: true,
          step_type: "execute"
        })

      {:ok, _} = Accounts.Workflows.update(workflow2, %{initial_step_id: step2.id})

      task = create_task(user1, project1)
      task = assign_workflow_to_task(task, workflow1)

      pid = start_orchestrator(task, user1)
      wait_for_state(pid, :executing)

      # Simulate route step output routing to workflow in different project
      route_output =
        Jason.encode!(%{
          "transition_to" => workflow2.id,
          "transition_type" => "inter_workflow"
        })

      simulate_daemon_completion(task.id, project1.id, route_output)

      wait_for_exit(pid)

      # Task should still be in original workflow (routing failed)
      task = reload_task(task)
      assert task.workflow_id == workflow1.id
      assert task.current_step_id == route_step.id
    end

    test "fails when no workflow transition edge exists" do
      user = create_user()
      project = create_project(user)

      workflow1 = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      workflow2 = create_workflow(user, project, auto_advance: false)

      step2 =
        create_step(user, workflow2, %{
          name: "step2",
          step_order: 1,
          is_final: true,
          step_type: "execute"
        })

      {:ok, _} = Accounts.Workflows.update(workflow2, %{initial_step_id: step2.id})

      # Note: NO transition created between workflow1 and workflow2

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Simulate route step output
      route_output =
        Jason.encode!(%{
          "transition_to" => workflow2.id,
          "transition_type" => "inter_workflow"
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      wait_for_exit(pid)

      # Task should still be in original workflow (no transition exists)
      task = reload_task(task)
      assert task.workflow_id == workflow1.id
      assert task.current_step_id == route_step.id
    end
  end

  describe "route step output validation" do
    test "fails when route step output is not valid JSON" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Invalid JSON output
      simulate_daemon_completion(task.id, project.id, "not valid json{")

      wait_for_exit(pid)

      # Task should remain at route step
      task = reload_task(task)
      assert task.current_step_id == route_step.id
    end

    test "fails when route step output missing required fields" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Missing transition_type field
      incomplete_output = Jason.encode!(%{"transition_to" => dest_step.id})
      simulate_daemon_completion(task.id, project.id, incomplete_output)

      wait_for_exit(pid)

      # Task should remain at route step
      task = reload_task(task)
      assert task.current_step_id == route_step.id
    end

    test "route output with valid handoff map passes validation" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Valid output with handoff
      output_with_handoff =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow",
          "handoff" => %{"data" => "context for destination"}
        })

      simulate_daemon_completion(task.id, project.id, output_with_handoff)

      wait_for_exit(pid)

      # Task should advance to destination step
      task = reload_task(task)
      assert task.current_step_id == dest_step.id
    end

    test "route output without handoff passes validation" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Output without handoff - backwards compatible
      output_without_handoff =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow"
        })

      simulate_daemon_completion(task.id, project.id, output_without_handoff)

      wait_for_exit(pid)

      # Task should advance to destination step
      task = reload_task(task)
      assert task.current_step_id == dest_step.id
    end
  end

  describe "prior output exposure in orchestrator (eval → route)" do
    test "completed eval step output is available to destination steps" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, auto_advance: false)

      eval_step =
        create_step(user, workflow, %{
          name: "eval_step",
          step_order: 1,
          is_final: false,
          step_type: "evaluate",
          prompt: "Evaluate the task"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, eval_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: eval_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Simulate eval completion with specific output
      eval_output = "Task is complex and needs review"
      simulate_daemon_completion(task.id, project.id, eval_output)

      wait_for_exit(pid)

      # Task should advance to destination step
      task = reload_task(task)
      assert task.current_step_id == dest_step.id

      # Verify the eval step has the output persisted
      executions = get_all_executions(task.id)
      assert length(executions) >= 2
      eval_exec = Enum.find(executions, &(&1.step_name == "eval_step"))
      assert eval_exec.status == "completed"
      assert eval_exec.output == eval_output
    end
  end

  describe "handoff propagation in intra-workflow routing" do
    test "route step handoff appears in destination step prompt" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route",
          prompt: "Route the task"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute",
          prompt: "Handoff context: {{ execution.handoff | json_encode }}"
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Route with handoff
      route_output =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow",
          "handoff" => %{"approved_by" => "admin", "priority" => "high"}
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      wait_for_exit(pid)

      # Task advanced to destination
      task = reload_task(task)
      assert task.current_step_id == dest_step.id

      # Verify the destination step execution has handoff persisted
      executions = get_all_executions(task.id)
      dest_exec = Enum.find(executions, &(&1.step_name == "dest_step"))
      assert dest_exec != nil
      assert dest_exec.handoff == %{"approved_by" => "admin", "priority" => "high"}
    end

    test "route step without handoff still allows destination execution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, auto_advance: false)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Route without handoff (backwards compatibility)
      route_output =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow"
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      wait_for_exit(pid)

      # Task advanced normally
      task = reload_task(task)
      assert task.current_step_id == dest_step.id

      # Destination execution should have nil or no handoff
      executions = get_all_executions(task.id)
      dest_exec = Enum.find(executions, &(&1.step_name == "dest_step"))
      assert dest_exec != nil
      assert dest_exec.handoff == nil
    end
  end

  describe "handoff propagation in inter-workflow routing" do
    test "route step handoff survives inter-workflow transition" do
      user = create_user()
      project = create_project(user)

      # Workflow 1: has route step
      workflow1 = create_workflow(user, project, auto_advance: false, name: "Workflow 1")

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: true,
          step_type: "route",
          prompt: "Route to workflow 2"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: destination workflow with initial step
      workflow2 = create_workflow(user, project, auto_advance: false, name: "Workflow 2")

      dest_step =
        create_step(user, workflow2, %{
          name: "dest_step",
          step_order: 1,
          is_final: true,
          step_type: "execute",
          prompt: "Received handoff: {{ execution.handoff | json_encode }}"
        })

      {:ok, _} = Accounts.Workflows.update(workflow2, %{initial_step_id: dest_step.id})

      # Create inter-workflow transition
      {:ok, _transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "project_id" => project.id
        })

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Route to different workflow with handoff
      route_output =
        Jason.encode!(%{
          "transition_to" => workflow2.id,
          "transition_type" => "inter_workflow",
          "handoff" => %{"transferred_from" => "workflow1", "data" => "context"}
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      wait_for_exit(pid)

      # Task should now be in workflow2 at dest_step
      task = reload_task(task)
      assert task.workflow_id == workflow2.id
      assert task.current_step_id == dest_step.id

      # Verify handoff persisted across workflow boundary
      executions = get_all_executions(task.id)
      dest_exec = Enum.find(executions, &(&1.step_name == "dest_step"))
      assert dest_exec != nil
      assert dest_exec.handoff == %{"transferred_from" => "workflow1", "data" => "context"}
    end

    test "inter-workflow handoff with transition target_step override" do
      user = create_user()
      project = create_project(user)

      # Workflow 1: route step
      workflow1 = create_workflow(user, project, auto_advance: false, name: "Workflow 1")

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: true,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: has multiple steps
      workflow2 = create_workflow(user, project, auto_advance: false, name: "Workflow 2")

      step2_1 =
        create_step(user, workflow2, %{
          name: "dest_step_1",
          step_order: 1,
          is_final: false,
          step_type: "execute"
        })

      step2_2 =
        create_step(user, workflow2, %{
          name: "dest_step_2",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      {:ok, _} = Accounts.Workflows.update(workflow2, %{initial_step_id: step2_1.id})

      # Create inter-workflow transition with target_step override
      {:ok, _transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          "from_workflow_id" => workflow1.id,
          "to_workflow_id" => workflow2.id,
          "target_step_id" => step2_2.id,
          "project_id" => project.id
        })

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      route_output =
        Jason.encode!(%{
          "transition_to" => workflow2.id,
          "transition_type" => "inter_workflow",
          "handoff" => %{"cross_workflow" => "data"}
        })

      simulate_daemon_completion(task.id, project.id, route_output)

      wait_for_exit(pid)

      task = reload_task(task)
      assert task.workflow_id == workflow2.id
      # Should go to target_step (step2_2) not initial step
      assert task.current_step_id == step2_2.id

      executions = get_all_executions(task.id)
      dest_exec = Enum.find(executions, &(&1.step_name == "dest_step_2"))
      assert dest_exec.handoff == %{"cross_workflow" => "data"}
    end
  end
end
