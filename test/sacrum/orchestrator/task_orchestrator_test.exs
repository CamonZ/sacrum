defmodule Sacrum.Orchestrator.TaskOrchestratorTest do
  use Sacrum.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.FSMData
  alias Sacrum.Orchestrator.TaskOrchestrator
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}

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

  defp create_workflow(user, project, opts \\ []) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: Keyword.get(opts, :name, "Test Workflow"),
        is_final: Keyword.get(opts, :is_final, false)
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
      level: "task",
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
    step_count = Keyword.get(opts, :step_count, 3)

    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project)

    steps =
      for i <- 1..step_count do
        prompt =
          if Keyword.get(opts, :promptless_after_first, false) and i > 1 do
            nil
          else
            "Run step for task {task_id}"
          end

        create_step(user, workflow, %{
          name: "step_#{i}",
          step_order: i,
          is_final: i == step_count,
          prompt: prompt
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

  defp cleanup_spawned_orchestrators(task_ids) do
    Enum.each(task_ids, fn task_id ->
      case Registry.lookup(Sacrum.Orchestrator.TaskRegistry, task_id) do
        [] ->
          :ok

        [{pid, _}] ->
          # Try to exit gracefully first, then kill if needed
          Process.exit(pid, :shutdown)
          Process.sleep(50)
          if Process.alive?(pid), do: Process.exit(pid, :kill)
      end
    end)
  end

  defp simulate_daemon_completion(task_id, _project_id, output \\ "step completed") do
    execution = get_latest_started_execution(task_id)

    # Simulate what the daemon does: update status to "completed" with output
    {:ok, updated} =
      execution
      |> StepExecution.update_changeset(%{status: "completed", output: output})
      |> Repo.update()

    Sacrum.Orchestrator.ExecutionEvents.broadcast_status_changed(updated)

    updated
  end

  defp simulate_daemon_failure(task_id, _project_id) do
    execution = get_latest_started_execution(task_id)

    {:ok, updated} =
      execution
      |> StepExecution.update_changeset(%{status: "failed", output: "daemon error"})
      |> Repo.update()

    Sacrum.Orchestrator.ExecutionEvents.broadcast_status_changed(updated)

    updated
  end

  defp get_latest_started_execution(task_id) do
    from(e in StepExecution,
      where: e.task_id == ^task_id and e.status == "started",
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

  defp wait_for_execution_count(task_id, expected, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_execution_count(task_id, expected, deadline)
  end

  defp do_wait_for_execution_count(task_id, expected, deadline) do
    actual = length(get_all_executions(task_id))

    cond do
      actual >= expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Timed out waiting for #{expected} executions, have #{actual}")

      true ->
        Process.sleep(10)
        do_wait_for_execution_count(task_id, expected, deadline)
    end
  end

  defp reload_task(task) do
    Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
  end

  defp latest_task_run(task_id) do
    Repo.one!(
      from(tr in TaskRun,
        where: tr.task_id == ^task_id,
        order_by: [desc: tr.inserted_at, desc: tr.id],
        limit: 1
      )
    )
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
      execution = hd(executions)
      assert execution.status == "completed"
      assert execution.step_name == "step_1"
      assert execution.task_run_id != nil

      task_run = Repo.get!(Sacrum.Repo.Schemas.TaskRun, execution.task_run_id)
      assert task_run.status == :completed
      assert task_run.latest_step_execution_id == execution.id
      assert %DateTime{} = task_run.ended_at
      assert {:error, :not_found} = Accounts.TaskRuns.get_active_for_task(user.id, task.id)
    end
  end

  describe "multi-step prompted continuation workflow" do
    test "advances through all steps to completion" do
      %{user: user, project: project, steps: [s1, s2, s3], task: task} =
        setup_linear_workflow(step_count: 3)

      pid = start_orchestrator(task, user)

      # Step 1: executing
      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s1.id
      simulate_daemon_completion(task.id, project.id, "step 1 done")

      # Step 2: continues to awaiting_execution -> executing
      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s2.id
      simulate_daemon_completion(task.id, project.id, "step 2 done")

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s3.id
      simulate_daemon_completion(task.id, project.id, "step 3 done")

      wait_for_exit(pid)

      task = reload_task(task)
      assert task.completed_at != nil
    end

    test "creates step executions for each step including the final one" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 3)

      pid = start_orchestrator(task, user)

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)

      wait_for_exit(pid)

      executions = get_all_executions(task.id)
      step_names = Enum.map(executions, & &1.step_name)

      assert "step_1" in step_names
      assert "step_2" in step_names
      assert "step_3" in step_names
      assert Enum.all?(executions, &(&1.status == "completed"))
    end

    test "updates task current_step_id at each transition" do
      %{user: user, project: project, steps: [s1, s2, s3], task: task} =
        setup_linear_workflow(step_count: 3)

      pid = start_orchestrator(task, user)

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s1.id

      simulate_daemon_completion(task.id, project.id)
      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s2.id

      simulate_daemon_completion(task.id, project.id)
      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s3.id

      simulate_daemon_completion(task.id, project.id)
      wait_for_exit(pid)
    end
  end

  describe "final step dispatch" do
    test "prompted workflow dispatches the final step and only completes after its StepExecution finishes" do
      %{user: user, project: project, steps: [s1, _s2, s3], task: task} =
        setup_linear_workflow(step_count: 3)

      pid = start_orchestrator(task, user)

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s1.id
      simulate_daemon_completion(task.id, project.id, "s1 done")

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id, "s2 done")

      wait_for_state(pid, :executing)
      reloaded = reload_task(task)
      assert reloaded.current_step_id == s3.id
      assert reloaded.completed_at == nil

      final_started = get_latest_started_execution(task.id)
      assert final_started.step_id == s3.id
      assert final_started.step_name == "step_3"

      simulate_daemon_completion(task.id, project.id, "s3 done")
      wait_for_exit(pid)

      completed = reload_task(task)
      assert completed.completed_at != nil

      executions = get_all_executions(task.id)
      assert Enum.map(executions, & &1.step_name) == ["step_1", "step_2", "step_3"]
      assert Enum.all?(executions, &(&1.status == "completed"))
    end

    test "wait_children with no children advances and dispatches the final step when prompted" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step =
        create_step(user, workflow, %{
          name: "wait_step",
          step_order: 1,
          is_final: false,
          step_type: "wait_children"
        })

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, wait_step, final_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent w/ wait_children"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      pid = start_orchestrator(parent_task, user)

      wait_for_state(pid, :executing)
      reloaded = reload_task(parent_task)
      assert reloaded.current_step_id == final_step.id
      assert reloaded.completed_at == nil

      final_started = get_latest_started_execution(parent_task.id)
      assert final_started.step_id == final_step.id
      assert final_started.step_name == "final_step"

      simulate_daemon_completion(parent_task.id, project.id, "final done")
      wait_for_exit(pid)

      completed = reload_task(parent_task)
      assert completed.completed_at != nil

      final_exec = Repo.get!(StepExecution, final_started.id)
      assert final_exec.status == "completed"
    end
  end

  describe "non-prompted continuation workflow" do
    test "stops after completing and transitioning to next step" do
      %{user: user, project: project, steps: [_s1, s2, _s3], task: task} =
        setup_linear_workflow(step_count: 3, promptless_after_first: true)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_completion(task.id, project.id)
      wait_for_exit(pid)

      # Task should have advanced to step 2 but orchestrator stopped
      assert reload_task(task).current_step_id == s2.id
      # Task should NOT be completed
      assert reload_task(task).completed_at == nil
    end

    test "completes at a promptless final sink step in a final workflow without executing it" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, is_final: true)

      active_step =
        create_step(user, workflow, %{
          name: "active_step",
          step_order: 1,
          is_final: false,
          prompt: "Run active step"
        })

      sink_step =
        create_step(user, workflow, %{
          name: "done_sink",
          step_order: 2,
          is_final: true,
          prompt: nil
        })

      create_transition(user, active_step, sink_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: active_step.id})

      task = create_task(user, project) |> assign_workflow_to_task(workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)
      wait_for_exit(pid)

      task = reload_task(task)
      assert task.current_step_id == sink_step.id
      assert task.completed_at != nil

      executions = get_all_executions(task.id)
      assert Enum.any?(executions, &(&1.step_id == active_step.id))
      refute Enum.any?(executions, &(&1.step_id == sink_step.id))
    end
  end

  describe "PubSub filtering" do
    test "ignores status changes for other execution IDs" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Send a completion for a different execution ID
      Sacrum.Orchestrator.ExecutionEvents.broadcast_status_changed(
        Ecto.UUID.generate(),
        "completed"
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
      workflow = create_workflow(user, project)

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
          step_type: "execute",
          prompt: nil
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

      # Orchestrator should stop (promptless destination)
      wait_for_exit(pid)

      # Task should now be at dest_step
      task = reload_task(task)
      assert task.current_step_id == dest_step.id
      assert task.completed_at == nil
    end

    test "fails when route step output has invalid destination in same workflow" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

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
      workflow1 = create_workflow(user, project)

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: has multiple steps
      workflow2 = create_workflow(user, project)

      step2_1 =
        create_step(user, workflow2, %{
          name: "step2_1",
          step_order: 1,
          is_final: false,
          step_type: "execute",
          prompt: nil
        })

      _step2_2 =
        create_step(user, workflow2, %{
          name: "step2_2",
          step_order: 2,
          is_final: true,
          step_type: "execute",
          prompt: nil
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
      workflow1 = create_workflow(user, project)

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: has multiple steps
      workflow2 = create_workflow(user, project)

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
          step_type: "execute",
          prompt: nil
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

      # workflow2 has promptless, so the orchestrator stops at the
      # final step instead of dispatching it; completed_at stays nil.
      task = reload_task(task)
      assert task.workflow_id == workflow2.id
      assert task.current_step_id == step2_2.id
      assert task.completed_at == nil
    end

    test "fails when route output references workflow in different project" do
      user1 = create_user(%{email: "user1@example.com", username: "user1"})
      user2 = create_user(%{email: "user2@example.com", username: "user2"})
      project1 = create_project(user1)
      project2 = create_project(user2)

      # Workflow 1 in project1
      workflow1 = create_workflow(user1, project1)

      route_step =
        create_step(user1, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2 in project2 (different project!)
      workflow2 = create_workflow(user2, project2)

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

      workflow1 = create_workflow(user, project)

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      workflow2 = create_workflow(user, project)

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
    test "does not create extra execution when output is valid JSON" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project)

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
          step_type: "execute",
          prompt: nil
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # First (and only) attempt: valid JSON output
      valid_output =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow"
        })

      simulate_daemon_completion(task.id, project.id, valid_output)

      wait_for_exit(pid)

      # Task should have routed to destination step
      task = reload_task(task)
      assert task.current_step_id == dest_step.id

      # Per new architecture: routing helpers do not create StepExecution rows.
      # Only the route_step execution should exist. Destination step is final, so
      # it is not executed (no entry rule for final steps after routing).
      executions = get_all_executions(task.id)
      assert length(executions) == 1
      route_exec = Enum.find(executions, &(&1.step_name == "route_step"))
      assert route_exec.status == "completed"
    end

    test "fails when route step output missing required fields" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project)

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
          step_type: "execute",
          prompt: nil
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

    test "route output with handoff matching custom schema passes validation" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route",
          output_schema: route_schema_with_handoff(["data"])
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute",
          prompt: nil
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

      workflow = create_workflow(user, project)

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
          step_type: "execute",
          prompt: nil
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

    test "fenced JSON route output is properly decoded and routed" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route",
          output_schema: route_schema_with_handoff(["data"])
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute",
          prompt: nil
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Simulate CLI wrapping output in markdown code fences
      json_output = %{
        "transition_to" => dest_step.id,
        "transition_type" => "intra_workflow",
        "handoff" => %{"data" => "context"}
      }

      fenced_output = "```json\n#{Jason.encode!(json_output)}\n```"

      simulate_daemon_completion(task.id, project.id, fenced_output)

      wait_for_exit(pid)

      # Task should advance to destination step even with fenced output
      task = reload_task(task)
      assert task.current_step_id == dest_step.id
    end
  end

  describe "prior output exposure in orchestrator (eval → route)" do
    test "completed eval step output is available to destination steps" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

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
          is_final: false,
          step_type: "execute",
          prompt: "Consider eval output: {{ execution.previous_output }}"
        })

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 3,
          is_final: true,
          step_type: "execute",
          prompt: nil
        })

      create_transition(user, eval_step, dest_step)
      create_transition(user, dest_step, final_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: eval_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # Simulate eval completion with specific output
      eval_output = "Task is complex and needs review"
      simulate_daemon_completion(task.id, project.id, eval_output)

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == dest_step.id

      simulate_daemon_completion(task.id, project.id, "destination done")
      wait_for_exit(pid)

      task = reload_task(task)
      assert task.current_step_id == final_step.id

      executions = get_all_executions(task.id)
      eval_exec = Enum.find(executions, &(&1.step_name == "eval_step"))
      assert eval_exec.status == "completed"
      assert eval_exec.output == eval_output

      dest_exec = Enum.find(executions, &(&1.step_name == "dest_step"))
      assert dest_exec.status == "completed"
      assert dest_exec.prompt =~ eval_output
    end
  end

  describe "handoff propagation in intra-workflow routing" do
    test "route step handoff appears in destination step prompt" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route",
          output_schema: route_schema_with_handoff(["approved_by", "priority"]),
          prompt: "Route the task"
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: false,
          step_type: "execute",
          prompt: "Handoff context: {{ execution.handoff | json_encode }}"
        })

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 3,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, route_step, dest_step)
      create_transition(user, dest_step, final_step)
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

      wait_for_state(pid, :executing)

      # Task advanced to destination
      task = reload_task(task)
      assert task.current_step_id == dest_step.id

      # Verify the destination step execution has handoff persisted
      executions = get_all_executions(task.id)
      dest_exec = Enum.find(executions, &(&1.step_name == "dest_step"))
      assert dest_exec != nil
      assert dest_exec.handoff == %{"approved_by" => "admin", "priority" => "high"}

      # Verify the handoff appears in the rendered prompt
      assert String.contains?(dest_exec.prompt, "approved_by")

      simulate_daemon_completion(task.id, project.id, "dest step done")

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == final_step.id

      simulate_daemon_completion(task.id, project.id, "final step done")
      wait_for_exit(pid)

      # Task completed
      task = reload_task(task)
      assert task.completed_at != nil
    end

    test "route step without handoff still allows destination execution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

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

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 3,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, route_step, dest_step)
      create_transition(user, dest_step, final_step)
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

      wait_for_state(pid, :executing)

      # Destination execution now exists
      executions = get_all_executions(task.id)
      dest_exec = Enum.find(executions, &(&1.step_name == "dest_step"))
      assert dest_exec != nil
      assert dest_exec.handoff == nil

      simulate_daemon_completion(task.id, project.id, "dest step done")

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == final_step.id

      simulate_daemon_completion(task.id, project.id, "final step done")
      wait_for_exit(pid)

      # Task completed
      task = reload_task(task)
      assert task.completed_at != nil
    end
  end

  describe "handoff propagation in inter-workflow routing" do
    test "route step handoff survives inter-workflow transition" do
      user = create_user()
      project = create_project(user)

      # Workflow 1: has route step
      workflow1 = create_workflow(user, project, name: "Workflow 1")

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: true,
          step_type: "route",
          output_schema: route_schema_with_handoff(["transferred_from", "data"]),
          prompt: "Route to workflow 2"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: destination workflow with initial step (non-final)
      workflow2 = create_workflow(user, project, name: "Workflow 2")

      dest_step =
        create_step(user, workflow2, %{
          name: "dest_step",
          step_order: 1,
          is_final: false,
          step_type: "execute",
          prompt: "Received handoff: {{ execution.handoff | json_encode }}"
        })

      final_step =
        create_step(user, workflow2, %{
          name: "final_step",
          step_order: 2,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, dest_step, final_step)

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

      # After routing, task should be at dest_step in workflow2
      wait_for_state(pid, :executing)
      task = reload_task(task)
      assert task.workflow_id == workflow2.id
      assert task.current_step_id == dest_step.id

      simulate_daemon_completion(task.id, project.id, "dest_step done")

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == final_step.id

      simulate_daemon_completion(task.id, project.id, "final step done")
      wait_for_exit(pid)

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
      workflow1 = create_workflow(user, project, name: "Workflow 1")

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: true,
          step_type: "route",
          output_schema: route_schema_with_handoff(["cross_workflow"])
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: has multiple steps with prompted continuation
      workflow2 = create_workflow(user, project, name: "Workflow 2")

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
          is_final: false,
          step_type: "execute",
          prompt: "Handoff context: {{ execution.handoff | json_encode }}"
        })

      step2_3 =
        create_step(user, workflow2, %{
          name: "final_step",
          step_order: 3,
          is_final: true,
          step_type: "execute"
        })

      create_transition(user, step2_1, step2_2)
      create_transition(user, step2_2, step2_3)

      {:ok, _} = Accounts.Workflows.update(workflow2, %{initial_step_id: step2_1.id})

      # Create inter-workflow transition with target_step override to step2_2
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

      # After routing, task should be at step2_2 in workflow2
      wait_for_state(pid, :executing)
      task = reload_task(task)
      assert task.workflow_id == workflow2.id
      # Should go to target_step (step2_2) not initial step
      assert task.current_step_id == step2_2.id

      simulate_daemon_completion(task.id, project.id, "step2_2 done")

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == step2_3.id

      simulate_daemon_completion(task.id, project.id, "final step done")
      wait_for_exit(pid)

      executions = get_all_executions(task.id)
      dest_exec = Enum.find(executions, &(&1.step_name == "dest_step_2"))
      assert dest_exec.handoff == %{"cross_workflow" => "data"}
    end
  end

  describe "route decision persistence (Fix 3)" do
    test "persists route decision to transition_result on successful intra-workflow routing" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route",
          output_schema: route_schema_with_handoff(["data"])
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute",
          prompt: nil
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      route_output =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow",
          "handoff" => %{"data" => "value"}
        })

      simulate_daemon_completion(task.id, project.id, route_output)
      wait_for_exit(pid)

      # Verify route step execution has transition_result populated
      executions =
        from(e in StepExecution,
          where: e.task_id == ^task.id and e.step_name == "route_step",
          order_by: [desc: :inserted_at],
          limit: 1
        )
        |> Repo.all()

      assert length(executions) == 1
      route_exec = List.first(executions)
      assert route_exec.transition_result != nil

      # Decode and verify the stored routing decision
      {:ok, decoded} = Jason.decode(route_exec.transition_result)
      assert decoded["dest_id"] == dest_step.id
      assert decoded["transition_type"] == "intra_workflow"
    end

    test "persists route decision for inter-workflow routing" do
      user = create_user()
      project = create_project(user)

      # Workflow 1: has route step
      workflow1 = create_workflow(user, project)

      route_step =
        create_step(user, workflow1, %{
          name: "route_step",
          step_order: 1,
          is_final: true,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow1, %{initial_step_id: route_step.id})

      # Workflow 2: has a step
      workflow2 = create_workflow(user, project)

      dest_step =
        create_step(user, workflow2, %{
          name: "dest_step",
          step_order: 1,
          is_final: true,
          step_type: "execute",
          prompt: nil
        })

      {:ok, _} = Accounts.Workflows.update(workflow2, %{initial_step_id: dest_step.id})

      # Create workflow transition
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

      route_output =
        Jason.encode!(%{
          "transition_to" => workflow2.id,
          "transition_type" => "inter_workflow"
        })

      simulate_daemon_completion(task.id, project.id, route_output)
      wait_for_exit(pid)

      # Verify route step execution has transition_result populated
      executions =
        from(e in StepExecution,
          where: e.task_id == ^task.id and e.step_name == "route_step",
          order_by: [desc: :inserted_at],
          limit: 1
        )
        |> Repo.all()

      assert length(executions) == 1
      route_exec = List.first(executions)
      assert route_exec.transition_result != nil

      # Decode and verify the stored routing decision
      {:ok, decoded} = Jason.decode(route_exec.transition_result)
      assert decoded["dest_id"] == workflow2.id
      assert decoded["transition_type"] == "inter_workflow"
    end
  end

  describe "routing error handling and failure surfacing (Fix 2)" do
    test "transitions to :failed and logs when routing validation fails" do
      import ExUnit.CaptureLog

      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

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
          step_type: "execute",
          prompt: nil
        })

      # Intentionally omit the StepTransition so validate_step_transition_exists fails
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      route_output =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow"
        })

      logs =
        capture_log(fn ->
          simulate_daemon_completion(task.id, project.id, route_output)
          wait_for_exit(pid)
        end)

      assert logs =~ "[TaskOrchestrator:#{task.id}]"
      assert logs =~ "Error in route transition"
      assert logs =~ "-> :failed"

      task_reloaded = reload_task(task)
      assert task_reloaded.current_step_id == route_step.id
    end

    test "transitions to :failed on malformed route output" do
      import ExUnit.CaptureLog

      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: true,
          step_type: "route"
        })

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      route_output = Jason.encode!(%{"transition_to" => Ecto.UUID.generate()})

      logs =
        capture_log(fn ->
          simulate_daemon_completion(task.id, project.id, route_output)
          wait_for_exit(pid)
        end)

      assert logs =~ "[TaskOrchestrator:#{task.id}]"
      assert logs =~ "-> :failed"

      task_reloaded = reload_task(task)
      assert task_reloaded.current_step_id == route_step.id
    end
  end

  describe "terminate/3 trace logging" do
    setup do
      prev_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_level) end)
      :ok
    end

    test "emits terminate log on normal shutdown so exit path is traceable" do
      import ExUnit.CaptureLog

      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1)

      logs =
        capture_log(fn ->
          pid = start_orchestrator(task, user)
          wait_for_state(pid, :executing)
          simulate_daemon_completion(task.id, project.id)
          wait_for_exit(pid)
        end)

      assert logs =~ "[TaskOrchestrator:#{task.id}] terminate reason=:normal"
    end

    test "logs route decision before persisting so forensics survive downstream crashes" do
      import ExUnit.CaptureLog

      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      route_step =
        create_step(user, workflow, %{
          name: "route_step",
          step_order: 1,
          is_final: false,
          step_type: "route",
          output_schema: route_schema_with_handoff(["feedback"])
        })

      dest_step =
        create_step(user, workflow, %{
          name: "dest_step",
          step_order: 2,
          is_final: true,
          step_type: "execute",
          prompt: nil
        })

      create_transition(user, route_step, dest_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: route_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      route_output =
        Jason.encode!(%{
          "transition_to" => dest_step.id,
          "transition_type" => "intra_workflow",
          "handoff" => %{"feedback" => "needs_changes"}
        })

      logs =
        capture_log(fn ->
          simulate_daemon_completion(task.id, project.id, route_output)
          wait_for_exit(pid)
        end)

      assert logs =~ "route decision"
      assert logs =~ "dest_id=#{dest_step.id}"
      assert logs =~ "transition_type=intra_workflow"
      assert logs =~ ~s|handoff_keys=["feedback"]|
    end
  end

  describe "execution failure retry" do
    test "semantic error in route step transition goes to :failed without retrying" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

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

      task =
        user
        |> create_task(project)
        |> assign_workflow_to_task(workflow)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      route_output =
        Jason.encode!(%{
          "transition_to" => Ecto.UUID.generate(),
          "transition_type" => "intra_workflow"
        })

      simulate_daemon_completion(task.id, project.id, route_output)
      wait_for_exit(pid)

      assert reload_task(task).current_step_id == route_step.id

      executions = get_all_executions(task.id)
      assert length(executions) == 1
      assert List.last(executions).status == "completed"
    end

    test "failure log line includes the attempt counter" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      logs =
        capture_log([level: :error], fn ->
          simulate_daemon_failure(task.id, project.id)
          wait_for_execution_count(task.id, 2)
        end)

      assert logs =~ "attempt=1/5"
    end

    test "completion log line includes the resolved step_type" do
      prev_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      logs =
        capture_log(fn ->
          simulate_daemon_completion(task.id, project.id, "done")
          wait_for_exit(pid)
        end)

      assert logs =~ "step_type=execute"
    end
  end

  describe "wait_children step type" do
    defp create_wait_children_step(user, workflow) do
      create_step(user, workflow, %{
        name: "wait_children",
        step_order: 1,
        step_type: "wait_children",
        is_final: false
      })
    end

    defp create_child_task(user, project, parent_task) do
      task = create_task(user, project, %{title: "Child Task"})

      Sacrum.Repo.TaskHierarchy.set_parent(task, parent_task)
      |> elem(1)
    end

    defp setup_wait_children_parent do
      build_wait_children_parent()
    end

    defp build_wait_children_parent(_opts \\ []) do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true,
          prompt: nil
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      %{
        user: user,
        project: project,
        workflow: workflow,
        wait_step: wait_step,
        final_step: final_step,
        parent_task: parent_task
      }
    end

    test "on entry to wait_children, schedules all children and creates waiting execution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      # Create wait_children step
      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true,
          prompt: nil
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      # Create parent task with children
      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      # Create children with workflows
      child_workflow_1 = create_workflow(user, project)

      child_step_1 =
        create_step(user, child_workflow_1, %{
          name: "child_step_1",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow_1, %{initial_step_id: child_step_1.id})

      child_task_1 = create_child_task(user, project, parent_task)
      child_task_1 = assign_workflow_to_task(child_task_1, child_workflow_1)

      child_workflow_2 = create_workflow(user, project)

      child_step_2 =
        create_step(user, child_workflow_2, %{
          name: "child_step_2",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow_2, %{initial_step_id: child_step_2.id})

      child_task_2 = create_child_task(user, project, parent_task)
      child_task_2 = assign_workflow_to_task(child_task_2, child_workflow_2)

      # Start parent orchestrator
      pid = start_orchestrator(parent_task, user)

      # Parent should enter wait_children and then exit
      wait_for_exit(pid)

      # Verify waiting execution was created with child IDs
      waiting_executions =
        Repo.all(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "waiting"
          )
        )

      assert length(waiting_executions) == 1
      waiting_exec = hd(waiting_executions)
      assert waiting_exec.handoff != nil
      assert waiting_exec.handoff["child_ids"] != nil
      child_ids = waiting_exec.handoff["child_ids"]
      assert Enum.member?(child_ids, child_task_1.id)
      assert Enum.member?(child_ids, child_task_2.id)
      assert waiting_exec.task_run_id != nil

      {:ok, parent_run} = Accounts.TaskRuns.get_active_for_task(user.id, parent_task.id)
      assert parent_run.id == waiting_exec.task_run_id
      assert parent_run.status == :waiting
      assert parent_run.latest_step_execution_id == waiting_exec.id

      # Clean up spawned child orchestrators
      cleanup_spawned_orchestrators([child_task_1.id, child_task_2.id])
    end

    test "parent orchestrator exits after entering wait_children (no process in TaskRegistry)" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true,
          prompt: nil
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1,
          step_type: "human_input",
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow, %{initial_step_id: child_step.id})

      child_task = create_child_task(user, project, parent_task)
      child_task = assign_workflow_to_task(child_task, child_workflow)

      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      # Give time for cleanup/deregistration
      Process.sleep(100)

      # Verify no orchestrator is registered for parent
      assert Registry.lookup(Sacrum.Orchestrator.TaskRegistry, parent_task.id) == []

      # Clean up spawned child orchestrator
      cleanup_spawned_orchestrators([child_task.id])
    end

    test "when non-last child reaches done, no parent orchestrator starts" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true,
          prompt: nil
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      # Create two children
      child_workflow_1 = create_workflow(user, project)

      child_step_1 =
        create_step(user, child_workflow_1, %{
          name: "child_step_1",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow_1, %{initial_step_id: child_step_1.id})

      child_task_1 = create_child_task(user, project, parent_task)
      child_task_1 = assign_workflow_to_task(child_task_1, child_workflow_1)

      child_workflow_2 = create_workflow(user, project)

      child_step_2 =
        create_step(user, child_workflow_2, %{
          name: "child_step_2",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow_2, %{initial_step_id: child_step_2.id})

      child_task_2 = create_child_task(user, project, parent_task)
      child_task_2 = assign_workflow_to_task(child_task_2, child_workflow_2)

      # Start parent and let it enter wait_children
      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      # Complete first child (via marking it as done)
      {:ok, _} =
        Repo.update(Ecto.Changeset.change(child_task_1, %{completed_at: DateTime.utc_now()}))

      # Notify scheduler of first child completion
      Sacrum.Orchestrator.Scheduler.notify_task_completed(child_task_1.id, %{status: "completed"})

      # Give time for any background processing
      Process.sleep(200)

      # Parent should NOT have an orchestrator running
      assert Registry.lookup(Sacrum.Orchestrator.TaskRegistry, parent_task.id) == []

      # Clean up spawned child orchestrators
      cleanup_spawned_orchestrators([child_task_1.id, child_task_2.id])
    end

    test "when last child reaches done, parent orchestrator resumes and advances" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      # Create single child
      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow, %{initial_step_id: child_step.id})

      child_task = create_child_task(user, project, parent_task)
      child_task = assign_workflow_to_task(child_task, child_workflow)

      # Start parent
      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      # Verify waiting execution exists
      waiting_execs =
        Repo.all(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "waiting"
          )
        )

      assert length(waiting_execs) == 1

      # Complete the child
      {:ok, _} =
        Repo.update(Ecto.Changeset.change(child_task, %{completed_at: DateTime.utc_now()}))

      # Notify scheduler
      Sacrum.Orchestrator.Scheduler.notify_task_completed(child_task.id, %{status: "completed"})

      # Give time for orchestrator to start
      Process.sleep(500)

      # Parent should transition to final_step
      parent_task = Repo.get(Sacrum.Repo.Schemas.Task, parent_task.id)
      assert parent_task.current_step_id == final_step.id

      # Clean up any remaining orchestrators
      cleanup_spawned_orchestrators([child_task.id, parent_task.id])
    end

    test "when child parks in Human Review, parent stays parked" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      # Create child with waiting execution (parked in Human Review)
      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow, %{initial_step_id: child_step.id})

      child_task = create_child_task(user, project, parent_task)
      child_task = assign_workflow_to_task(child_task, child_workflow)

      Repo.insert(%StepExecution{
        task_id: child_task.id,
        workflow_id: child_workflow.id,
        step_id: child_step.id,
        step_name: child_step.name,
        status: "waiting",
        user_id: user.id,
        project_id: project.id
      })

      # Start parent
      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      # Complete the child (but it still has waiting execution)
      {:ok, _} =
        Repo.update(Ecto.Changeset.change(child_task, %{completed_at: DateTime.utc_now()}))

      # Notify scheduler
      Sacrum.Orchestrator.Scheduler.notify_task_completed(child_task.id, %{status: "completed"})

      # Give time for any processing
      Process.sleep(200)

      # Parent should NOT have started orchestrator (still parked)
      assert Registry.lookup(Sacrum.Orchestrator.TaskRegistry, parent_task.id) == []

      # Parent should still be at wait_children step
      parent_task = Repo.get(Sacrum.Repo.Schemas.Task, parent_task.id)
      assert parent_task.current_step_id == wait_step.id

      # Clean up spawned child orchestrator
      cleanup_spawned_orchestrators([child_task.id])
    end

    test "supervisor is running" do
      # Verify the supervisor is running in tests
      sup_pid = GenServer.whereis(Sacrum.Orchestrator.TaskFSMSupervisor)
      assert sup_pid != nil, "TaskFSMSupervisor should be running"
      assert Process.alive?(sup_pid), "TaskFSMSupervisor process should be alive"
    end

    test "supervisor can start children directly" do
      user = create_user()
      project = create_project(user)

      workflow = create_workflow(user, project)

      step =
        create_step(user, workflow, %{
          name: "step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: step.id})

      task = create_task(user, project, %{title: "Task"})
      task = assign_workflow_to_task(task, workflow)

      # Try to start child via supervisor directly
      result =
        Sacrum.Orchestrator.TaskFSMSupervisor.start_child(
          {Sacrum.Orchestrator.TaskOrchestrator, [task_id: task.id, user_id: user.id]}
        )

      case result do
        {:ok, pid} ->
          # Give time for registry to update
          Process.sleep(50)
          # Verify it's registered in TaskRegistry
          registered = Registry.lookup(Sacrum.Orchestrator.TaskRegistry, task.id)
          assert length(registered) > 0, "Child should be registered in TaskRegistry after start"
          # Check if it's still alive
          if Process.alive?(pid) do
            cleanup_spawned_orchestrators([task.id])
          else
            # Process crashed, which might be expected if it completed quickly
            :ok
          end

        {:error, reason} ->
          flunk("Failed to start orchestrator via supervisor: #{inspect(reason)}")
      end
    end

    test "works recursively with two levels: parent > child" do
      user = create_user()
      project = create_project(user)

      # Create parent workflow with wait_children
      parent_workflow = create_workflow(user, project)
      parent_wait_step = create_wait_children_step(user, parent_workflow)

      parent_final_step =
        create_step(user, parent_workflow, %{
          name: "parent_final",
          step_order: 2,
          is_final: true
        })

      create_transition(user, parent_wait_step, parent_final_step)

      {:ok, _} =
        Accounts.Workflows.update(parent_workflow, %{initial_step_id: parent_wait_step.id})

      # Create parent
      parent_task = create_task(user, project, %{title: "Parent"})
      parent_task = assign_workflow_to_task(parent_task, parent_workflow)

      # Create child workflow with wait_children
      child_workflow = create_workflow(user, project)
      child_wait_step = create_wait_children_step(user, child_workflow)

      child_final_step =
        create_step(user, child_workflow, %{
          name: "child_final",
          step_order: 2,
          is_final: true
        })

      create_transition(user, child_wait_step, child_final_step)

      {:ok, _} =
        Accounts.Workflows.update(child_workflow, %{initial_step_id: child_wait_step.id})

      # Create child as child of parent
      child_task = create_child_task(user, project, parent_task)
      child_task = assign_workflow_to_task(child_task, child_workflow)

      # Create grandchild workflow (leaf)
      leaf_workflow = create_workflow(user, project)

      leaf_step =
        create_step(user, leaf_workflow, %{
          name: "leaf_step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(leaf_workflow, %{initial_step_id: leaf_step.id})

      # Create leaf as child of child
      leaf_task = create_child_task(user, project, child_task)
      leaf_task = assign_workflow_to_task(leaf_task, leaf_workflow)

      parent_pid = start_orchestrator(parent_task, user)
      wait_for_exit(parent_pid)

      # Both the parent and the middle child should have persisted waiting
      # StepExecutions and exited their orchestrator processes. The leaf's
      # prompted workflow has no wait_children step, so it runs to completion.
      parent_waiting =
        Repo.all(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "waiting"
          )
        )

      assert length(parent_waiting) == 1, "Parent should have a single waiting execution"
      parent_waiting_exec = hd(parent_waiting)

      assert Enum.any?(1..50, fn _ ->
               child_waiting =
                 Repo.all(
                   from(e in StepExecution,
                     where: e.task_id == ^child_task.id and e.status == "waiting"
                   )
                 )

               if length(child_waiting) == 1 do
                 true
               else
                 Process.sleep(50)
                 false
               end
             end),
             "Middle child should have parked with its own waiting execution"

      child_waiting_exec =
        Repo.one!(
          from(e in StepExecution,
            where: e.task_id == ^child_task.id and e.status == "waiting",
            order_by: [desc: e.inserted_at],
            limit: 1
          )
        )

      parent_run = latest_task_run(parent_task.id)
      child_run = latest_task_run(child_task.id)
      leaf_run = latest_task_run(leaf_task.id)

      assert parent_run.parent_task_run_id == nil
      assert parent_run.root_task_run_id == nil
      assert parent_run.triggered_by_step_execution_id == nil

      assert child_run.parent_task_run_id == parent_run.id
      assert child_run.root_task_run_id == parent_run.id
      assert child_run.triggered_by_step_execution_id == parent_waiting_exec.id

      assert leaf_run.parent_task_run_id == child_run.id
      assert leaf_run.root_task_run_id == parent_run.id
      assert leaf_run.triggered_by_step_execution_id == child_waiting_exec.id

      trace_ids =
        parent_run.id
        |> then(&Accounts.TaskRuns.list_for_trace(user.id, &1))
        |> Enum.map(& &1.id)

      descendant_ids =
        parent_run.id
        |> then(&Accounts.TaskRuns.list_descendants_for_trace(user.id, &1))
        |> Enum.map(& &1.id)

      assert trace_ids == [parent_run.id, child_run.id, leaf_run.id]
      assert descendant_ids == [child_run.id, leaf_run.id]

      assert Registry.lookup(Sacrum.Orchestrator.TaskRegistry, parent_task.id) == [],
             "Parent orchestrator must exit (pause lives in DB)"

      assert Registry.lookup(Sacrum.Orchestrator.TaskRegistry, child_task.id) == [],
             "Middle child orchestrator must exit (pause lives in DB)"

      # Completing the leaf wakes the middle child; completing the middle child
      # wakes the parent. Each wake reuses the existing waiting StepExecution.
      {:ok, _} =
        Repo.update(Ecto.Changeset.change(leaf_task, %{completed_at: DateTime.utc_now()}))

      Sacrum.Orchestrator.Scheduler.notify_task_completed(leaf_task.id, %{status: "completed"})
      Process.sleep(1500)

      child_task = Repo.get(Sacrum.Repo.Schemas.Task, child_task.id)
      assert child_task.current_step_id == child_final_step.id

      {:ok, _} =
        Repo.update(Ecto.Changeset.change(child_task, %{completed_at: DateTime.utc_now()}))

      Sacrum.Orchestrator.Scheduler.notify_task_completed(child_task.id, %{status: "completed"})
      Process.sleep(1500)

      parent_task = Repo.get(Sacrum.Repo.Schemas.Task, parent_task.id)
      assert parent_task.current_step_id == parent_final_step.id

      cleanup_spawned_orchestrators([leaf_task.id, child_task.id, parent_task.id])
    end

    test "crash safety: killing parent before child completion wake preserves pause state" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow, %{initial_step_id: child_step.id})

      child_task = create_child_task(user, project, parent_task)
      child_task = assign_workflow_to_task(child_task, child_workflow)

      # Start parent and kill it
      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      # Verify waiting execution still exists
      waiting_execs =
        Repo.all(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "waiting"
          )
        )

      assert length(waiting_execs) == 1

      # Now complete child - parent should wake up
      {:ok, _} =
        Repo.update(Ecto.Changeset.change(child_task, %{completed_at: DateTime.utc_now()}))

      Sacrum.Orchestrator.Scheduler.notify_task_completed(child_task.id, %{status: "completed"})
      Process.sleep(500)

      # Parent should have transitioned
      parent_task = Repo.get(Sacrum.Repo.Schemas.Task, parent_task.id)
      assert parent_task.current_step_id == final_step.id

      # Clean up spawned child orchestrator
      cleanup_spawned_orchestrators([child_task.id])
    end

    test "no duplicate parent orchestrator when one already registered" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow, %{initial_step_id: child_step.id})

      child_task = create_child_task(user, project, parent_task)
      child_task = assign_workflow_to_task(child_task, child_workflow)

      # Start parent
      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      # Try to wake parent while trying to start another one simultaneously
      {:ok, _} =
        Repo.update(Ecto.Changeset.change(child_task, %{completed_at: DateTime.utc_now()}))

      # Start a new orchestrator for parent (simulating race condition)
      previous_trap_exit = Process.flag(:trap_exit, true)
      on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

      {:ok, _pid1} = TaskOrchestrator.start_link(task_id: parent_task.id, user_id: user.id)
      Process.sleep(100)

      # Now notify about child completion
      Sacrum.Orchestrator.Scheduler.notify_task_completed(child_task.id, %{status: "completed"})
      Process.sleep(500)

      # Only one orchestrator should exist for parent
      pids = Registry.lookup(Sacrum.Orchestrator.TaskRegistry, parent_task.id)
      assert length(pids) <= 1

      # Clean up spawned child orchestrator and any parent processes
      cleanup_spawned_orchestrators([child_task.id, parent_task.id])
    end

    test "satisfied wait_children transition marks waiting execution as completed" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true,
          prompt: nil
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      child_workflow_1 = create_workflow(user, project)

      child_step_1 =
        create_step(user, child_workflow_1, %{
          name: "child_step_1",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow_1, %{initial_step_id: child_step_1.id})

      child_task_1 = create_child_task(user, project, parent_task)
      child_task_1 = assign_workflow_to_task(child_task_1, child_workflow_1)

      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      waiting_executions =
        Repo.all(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "waiting"
          )
        )

      assert length(waiting_executions) == 1
      waiting_exec_id = hd(waiting_executions).id

      {:ok, _} =
        Repo.update(Ecto.Changeset.change(child_task_1, %{completed_at: DateTime.utc_now()}))

      Sacrum.Orchestrator.Scheduler.notify_task_completed(child_task_1.id, %{status: "completed"})
      Process.sleep(500)

      waiting_exec = Repo.get!(StepExecution, waiting_exec_id)
      assert waiting_exec.status == "completed"

      snapshot = Jason.decode!(waiting_exec.output)
      assert snapshot["snapshot_type"] == "wait_children_status"
      assert snapshot["counts"]["total_direct_children"] == 1
      assert snapshot["counts"]["direct_done"] == 1
      assert [%{"id" => child_id, "state" => "done"}] = snapshot["direct_children"]
      assert child_id == child_task_1.id

      parent_task = Repo.get!(Sacrum.Repo.Schemas.Task, parent_task.id)
      assert parent_task.current_step_id == final_step.id

      # Per new architecture: final steps are not executed, so no execution is created
      # The task simply advances to the final step as the terminal state
      final_executions =
        Repo.all(
          from(e in StepExecution,
            where:
              e.task_id == ^parent_task.id and
                e.step_id == ^final_step.id
          )
        )

      assert length(final_executions) == 0

      cleanup_spawned_orchestrators([child_task_1.id])
    end

    test "wait_children still advances parent even if child completed_at is set (all_done_and_not_parked check)" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      wait_step = create_wait_children_step(user, workflow)

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          is_final: true
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      child_workflow_1 = create_workflow(user, project)

      child_step_1 =
        create_step(user, child_workflow_1, %{
          name: "child_step_1",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow_1, %{initial_step_id: child_step_1.id})

      child_task_1 = create_child_task(user, project, parent_task)
      child_task_1 = assign_workflow_to_task(child_task_1, child_workflow_1)

      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      {:ok, _} =
        Repo.update(
          Ecto.Changeset.change(child_task_1, %{
            completed_at: DateTime.utc_now()
          })
        )

      Sacrum.Orchestrator.Scheduler.notify_task_completed(child_task_1.id, %{status: "completed"})
      Process.sleep(500)

      waiting_executions =
        Repo.all(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "completed"
          )
        )

      assert length(waiting_executions) == 1

      parent_task = Repo.get!(Sacrum.Repo.Schemas.Task, parent_task.id)
      assert parent_task.current_step_id == final_step.id

      cleanup_spawned_orchestrators([child_task_1.id])
    end

    test "inter-workflow routing updates task position without invalidating prior executions" do
      user = create_user()
      project = create_project(user)

      source_workflow = create_workflow(user, project)

      source_step =
        create_step(user, source_workflow, %{
          name: "source_step",
          step_order: 1,
          is_final: false
        })

      {:ok, _} = Accounts.Workflows.update(source_workflow, %{initial_step_id: source_step.id})

      dest_workflow = create_workflow(user, project)

      dest_step =
        create_step(user, dest_workflow, %{
          name: "dest_step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(dest_workflow, %{initial_step_id: dest_step.id})

      {:ok, _} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          from_workflow_id: source_workflow.id,
          to_workflow_id: dest_workflow.id,
          project_id: project.id
        })

      route_step =
        create_step(user, source_workflow, %{
          name: "route_step",
          step_order: 2,
          step_type: "route",
          is_final: false
        })

      create_transition(user, source_step, route_step)

      task = create_task(user, project, %{title: "Test Task"})
      task = assign_workflow_to_task(task, source_workflow)

      {:ok, _prior_exec} =
        %StepExecution{user_id: user.id, project_id: project.id}
        |> StepExecution.create_changeset(%{
          task_id: task.id,
          workflow_id: dest_workflow.id,
          step_id: dest_step.id,
          step_name: dest_step.name,
          status: "invalidated"
        })
        |> Repo.insert()

      {:ok, updated_task} =
        Sacrum.Orchestrator.Routing.InterWorkflow.handle_inter_workflow_routing(
          %FSMData{
            task: task,
            user_id: user.id,
            project_id: project.id
          },
          dest_workflow.id,
          nil
        )

      # Verify that inter-workflow routing updates the task's workflow and step
      assert updated_task.workflow_id == dest_workflow.id
      assert updated_task.current_step_id == dest_step.id

      # Verify that prior executions are not modified
      prior_executions =
        Repo.all(
          from(e in StepExecution,
            where:
              e.task_id == ^task.id and
                e.workflow_id == ^dest_workflow.id and
                e.step_id == ^dest_step.id
          )
        )

      assert length(prior_executions) >= 1
      assert Enum.all?(prior_executions, &(&1.status == "invalidated"))
    end

    test "wait_children entry with no children advances through outgoing transition without failing the run" do
      %{user: user, parent_task: parent_task, final_step: final_step} =
        setup_wait_children_parent()

      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      reloaded_task = reload_task(parent_task)
      assert reloaded_task.current_step_id == final_step.id

      task_run = latest_task_run(parent_task.id)
      refute task_run.status == :failed
      assert is_nil(task_run.outcome_kind) or task_run.outcome_kind != :orchestrator_failed
    end

    test "wait_children entry with no children does not insert a waiting StepExecution" do
      %{user: user, parent_task: parent_task} = setup_wait_children_parent()

      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      waiting_executions =
        Repo.all(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "waiting"
          )
        )

      assert waiting_executions == []

      completed_execution =
        Repo.one!(
          from(e in StepExecution,
            where:
              e.task_id == ^parent_task.id and
                e.step_type == "wait_children" and
                e.status == "completed",
            limit: 1
          )
        )

      snapshot = Jason.decode!(completed_execution.output)
      assert snapshot["snapshot_type"] == "wait_children_status"
      assert snapshot["counts"]["total_direct_children"] == 0
      assert snapshot["direct_children"] == []
    end

    test "wait_children entry with one or more children still parks in waiting state" do
      %{user: user, project: project, parent_task: parent_task, wait_step: wait_step} =
        setup_wait_children_parent()

      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow, %{initial_step_id: child_step.id})

      child_task = create_child_task(user, project, parent_task)
      child_task = assign_workflow_to_task(child_task, child_workflow)

      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      waiting_executions =
        Repo.all(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "waiting"
          )
        )

      assert length(waiting_executions) == 1
      waiting_exec = hd(waiting_executions)
      assert waiting_exec.step_type == "wait_children"
      assert waiting_exec.handoff["child_ids"] == [child_task.id]

      {:ok, parent_run} = Accounts.TaskRuns.get_active_for_task(user.id, parent_task.id)
      assert parent_run.status == :waiting
      assert parent_run.latest_step_execution_id == waiting_exec.id

      reloaded_parent = reload_task(parent_task)
      assert reloaded_parent.current_step_id == wait_step.id

      cleanup_spawned_orchestrators([child_task.id])
    end
  end

  describe "task run step persistence" do
    test "run start persists queued and executing run state" do
      %{user: user, project: project, steps: [first_step], task: task} =
        setup_linear_workflow(step_count: 1)

      {:ok, queued_run} =
        Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      {:ok, executing_run} = Accounts.TaskRuns.update(queued_run, %{status: :executing})

      assert queued_run.task_id == task.id
      assert queued_run.status == :queued
      assert executing_run.id == queued_run.id
      assert executing_run.status == :executing
      assert task.current_step_id == first_step.id
    end

    test "task step movement during an active run persists the task step" do
      %{user: user, project: project, steps: [s1, s2, _s3], task: task} =
        setup_linear_workflow(step_count: 3)

      {:ok, task_run} =
        Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})

      {:ok, moved_task} = Repo.update(Ecto.Changeset.change(task, %{current_step_id: s2.id}))

      assert task_run.status == :executing
      assert task.current_step_id == s1.id
      assert moved_task.current_step_id == s2.id
    end

    test "terminal TaskRun updates persist terminal run state" do
      %{user: user, project: project, steps: [s1, _s2, _s3], task: task} =
        setup_linear_workflow(step_count: 3)

      for status <- [:completed, :stopped, :failed] do
        {:ok, running_run} =
          Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})

        {:ok, terminal_run} =
          Accounts.TaskRuns.update(running_run, %{
            status: status,
            ended_at: DateTime.utc_now(),
            outcome_kind: Atom.to_string(status)
          })

        assert running_run.status == :executing
        assert terminal_run.status == status
        assert terminal_run.outcome_kind == Atom.to_string(status)
        assert task.current_step_id == s1.id
      end
    end

    test "wait_children waiting StepExecution is persisted" do
      %{user: user, project: project, parent_task: parent_task} = setup_wait_children_parent()

      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1,
          is_final: true
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow, %{initial_step_id: child_step.id})

      child_task = create_child_task(user, project, parent_task)
      child_task = assign_workflow_to_task(child_task, child_workflow)

      pid = start_orchestrator(parent_task, user)
      wait_for_exit(pid)

      waiting_execution =
        Repo.one!(
          from(e in StepExecution,
            where: e.task_id == ^parent_task.id and e.status == "waiting",
            limit: 1
          )
        )

      assert waiting_execution.task_id == parent_task.id
      assert waiting_execution.task_run_id
      assert waiting_execution.status == "waiting"
      assert Jason.decode!(waiting_execution.output)["snapshot_type"] == "wait_children_status"

      cleanup_spawned_orchestrators([child_task.id])
    end
  end
end
