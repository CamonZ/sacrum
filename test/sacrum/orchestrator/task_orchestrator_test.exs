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
      Accounts.StepExecutions.update(execution, %{status: "completed", output: output})

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
      Accounts.StepExecutions.update(execution, %{status: "failed", output: "daemon error"})

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

      # Task should not be marked completed
      assert reload_task(task).completed_at == nil
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
end
