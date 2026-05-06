defmodule Sacrum.Orchestrator.IntegrationTest do
  @moduledoc """
  End-to-end integration tests for the orchestrator post-`entered`-removal.

  These tests assert the full dispatch contract: the orchestrator creates a
  `started` StepExecution row and emits a `run_step` broadcast. Daemon completion
  is simulated by broadcasting `step_execution_status_changed`. They also cover
  stop-then-restart, where the in-flight execution must be marked `cancelled`
  and a fresh dispatch happen on the same step on restart.
  """

  use Sacrum.DataCase, async: false

  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator
  alias Sacrum.Orchestrator.TaskFSMSupervisor
  alias Sacrum.Orchestrator.TaskOrchestrator
  alias Sacrum.Orchestrator.TaskRegistry
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}

  # ===== Setup helpers =====

  defp create_user do
    {:ok, user} =
      Repo.Users.insert(%{
        email: "integration_test@example.com",
        username: "integration_test",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Integration Project"})
    project
  end

  defp create_workflow(user, project, opts) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Integration Workflow",
        auto_advance: Keyword.get(opts, :auto_advance, true)
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "step",
      "step_order" => 1,
      "is_final" => false,
      "agents" => ["test"],
      "skills" => ["test_skill"],
      "agent_config" => %{"model" => "test-model"},
      "workflow_id" => workflow.id,
      "project_id" => workflow.project_id,
      "prompt" => "Run step for task {task_id}"
    }

    merged = Map.merge(default_attrs, Map.new(attrs, fn {k, v} -> {to_string(k), v} end))
    {:ok, step} = Accounts.WorkflowSteps.insert(user.id, merged)
    step
  end

  defp create_transition(user, from_step, to_step) do
    {:ok, _} =
      Accounts.StepTransitions.insert(user.id, %{
        "from_step_id" => from_step.id,
        "to_step_id" => to_step.id,
        "project_id" => from_step.project_id,
        "label" => "next"
      })
  end

  defp create_task(user, project) do
    {:ok, task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Integration Task",
        description: "test",
        level: "medium",
        priority: "normal",
        tags: ["test"]
      })

    task
  end

  defp setup_linear_workflow(opts) do
    step_count = Keyword.get(opts, :step_count, 3)
    auto_advance = Keyword.get(opts, :auto_advance, true)

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

    steps
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [from, to] -> create_transition(user, from, to) end)

    [first_step | _] = steps
    {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: first_step.id})

    task = create_task(user, project)
    {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)

    %{user: user, project: project, workflow: workflow, steps: steps, task: task}
  end

  # ===== Orchestration helpers =====

  defp subscribe_project(project_id) do
    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project_id}")
  end

  defp start_orchestrator(task, user) do
    child_spec = {TaskOrchestrator, task_id: task.id, user_id: user.id}
    {:ok, pid} = TaskFSMSupervisor.start_child(child_spec)
    ExUnit.Callbacks.on_exit(fn -> ensure_terminated(pid) end)
    pid
  end

  defp ensure_terminated(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      _ = TaskFSMSupervisor.terminate_child(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        500 -> :ok
      end
    end
  end

  defp wait_for_state(pid, expected, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_state(pid, expected, deadline)
  end

  defp do_wait_for_state(pid, expected, deadline) do
    cond do
      not Process.alive?(pid) ->
        if expected in [:completed, :failed],
          do: :ok,
          else: flunk("Process exited while waiting for #{inspect(expected)}")

      System.monotonic_time(:millisecond) > deadline ->
        {state, _} = :sys.get_state(pid)
        flunk("Timed out waiting for #{inspect(expected)}, FSM is in #{inspect(state)}")

      true ->
        case :sys.get_state(pid) do
          {^expected, _} ->
            :ok

          _ ->
            Process.sleep(10)
            do_wait_for_state(pid, expected, deadline)
        end
    end
  end

  defp wait_for_registry_clear(task_id, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn -> Registry.lookup(TaskRegistry, task_id) end)
    |> Enum.find(fn
      [] ->
        true

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("Timed out waiting for registry to clear for task #{task_id}")
        end

        Process.sleep(10)
        false
    end)

    :ok
  end

  defp wait_for_exit(pid, timeout \\ 2000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      timeout -> flunk("Process did not exit in #{timeout}ms")
    end
  end

  defp simulate_daemon_completion(task_id, project_id, output) do
    execution = latest_started_execution(task_id)

    {:ok, updated} =
      execution
      |> StepExecution.update_changeset(%{status: "completed", output: output})
      |> Repo.update()

    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_execution_status_changed",
      %{id: updated.id, status: "completed", output: output}
    )

    updated
  end

  defp simulate_daemon_failure(task_id, project_id) do
    execution = latest_started_execution(task_id)

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

  defp wait_for_execution_count(task_id, expected, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_execution_count(task_id, expected, deadline)
  end

  defp do_wait_for_execution_count(task_id, expected, deadline) do
    actual = length(executions_for_task(task_id))

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

  defp latest_started_execution(task_id) do
    Repo.one!(
      from(e in StepExecution,
        where: e.task_id == ^task_id and e.status == "started",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
    )
  end

  defp executions_for_task(task_id) do
    Repo.all(
      from(e in StepExecution,
        where: e.task_id == ^task_id,
        order_by: [asc: e.inserted_at]
      )
    )
  end

  defp assert_run_step_for(execution_id, _step_name) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "run_step",
                     payload: %{id: ^execution_id}
                   },
                   1500
  end

  defp drain_run_step_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{event: "run_step"} -> drain_run_step_broadcasts()
    after
      0 -> :ok
    end
  end

  # ===== Tests =====

  describe "fresh orchestration with no prior executions" do
    test "creates the first started execution and broadcasts run_step for the current step" do
      %{user: user, project: project, steps: [s1 | _], task: task} =
        setup_linear_workflow(step_count: 3)

      assert executions_for_task(task.id) == []
      subscribe_project(project.id)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      executions = executions_for_task(task.id)

      assert [%StepExecution{step_id: step_id, step_name: "step_1", status: "started"} = exec] =
               executions

      assert step_id == s1.id

      assert_run_step_for(exec.id, "step_1")
    end
  end

  describe "transition to next step on daemon completion" do
    test "creates a new started execution and broadcasts run_step for step_2" do
      %{user: user, project: project, steps: [_s1, s2, _s3], task: task} =
        setup_linear_workflow(step_count: 3, auto_advance: true)

      subscribe_project(project.id)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      first_exec = latest_started_execution(task.id)
      assert_run_step_for(first_exec.id, "step_1")

      simulate_daemon_completion(task.id, project.id, "step 1 output")

      wait_for_state(pid, :executing)

      task_after = Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
      assert task_after.current_step_id == s2.id

      executions = executions_for_task(task.id)
      assert length(executions) == 2
      [_completed_first, second] = executions
      assert second.step_name == "step_2"
      assert second.status == "started"
      assert second.id != first_exec.id

      assert_run_step_for(second.id, "step_2")
    end
  end

  describe "stop then restart" do
    test "marks in-flight execution cancelled, leaves current_step intact, and re-dispatches the same step on restart" do
      %{user: user, project: project, steps: [s1 | _], task: task} =
        setup_linear_workflow(step_count: 3, auto_advance: true)

      subscribe_project(project.id)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      first_exec = latest_started_execution(task.id)
      assert_run_step_for(first_exec.id, "step_1")

      assert {:ok, :stopped} = Orchestrator.stop(task.id)
      wait_for_exit(pid)
      wait_for_registry_clear(task.id)

      cancelled = Repo.get!(StepExecution, first_exec.id)
      assert cancelled.status == "cancelled"

      task_after_stop = Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
      assert task_after_stop.current_step_id == s1.id

      drain_run_step_broadcasts()

      pid2 = start_orchestrator(task_after_stop, user)
      wait_for_state(pid2, :executing)

      executions = executions_for_task(task.id)
      assert length(executions) == 2

      [first, second] = executions
      assert first.id == first_exec.id
      assert first.status == "cancelled"
      assert second.step_name == "step_1"
      assert second.status == "started"
      assert second.id != first_exec.id

      assert_run_step_for(second.id, "step_1")
    end

    test "stop is idempotent and terminates the FSM" do
      %{user: user, project: _project, task: task} = setup_linear_workflow(step_count: 1)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      # First stop terminates the FSM and cancels the in-flight execution
      assert {:ok, :stopped} = Orchestrator.stop(task.id)
      wait_for_exit(pid)
      wait_for_registry_clear(task.id)

      # Second stop hits the not-running branch
      assert {:ok, :not_running} = Orchestrator.stop(task.id)
    end
  end

  describe "execution failure retry" do
    test "single failure inserts a fresh started execution and re-broadcasts run_step for the same step" do
      %{user: user, project: project, steps: [s1 | _], task: task} =
        setup_linear_workflow(step_count: 1)

      subscribe_project(project.id)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      first_exec = latest_started_execution(task.id)
      assert_run_step_for(first_exec.id, "step_1")

      simulate_daemon_failure(task.id, project.id)
      wait_for_execution_count(task.id, 2)

      assert {:executing, _} = :sys.get_state(pid)

      executions = executions_for_task(task.id)
      assert length(executions) == 2

      [failed, retry] = executions
      assert failed.id == first_exec.id
      assert failed.status == "failed"
      assert retry.status == "started"
      assert retry.step_id == s1.id
      assert retry.id != first_exec.id

      task_run = Repo.one!(from(run in TaskRun, where: run.task_id == ^task.id))
      assert failed.task_run_id == task_run.id
      assert retry.task_run_id == task_run.id
      assert task_run.status == :executing
      assert task_run.latest_step_execution_id == retry.id
      assert task_run.outcome_kind == nil
      assert task_run.outcome_context == %{}

      assert_run_step_for(retry.id, "step_1")
    end

    test "five consecutive failures exhaust retries: FSM goes :failed and no further run_step fires" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1)

      subscribe_project(project.id)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      for n <- 1..5 do
        simulate_daemon_failure(task.id, project.id)
        if n < 5, do: wait_for_execution_count(task.id, n + 1)
      end

      wait_for_exit(pid)

      executions = executions_for_task(task.id)
      assert length(executions) == 5
      assert Enum.all?(executions, &(&1.status in ["started", "failed"]))
      failed_execution = List.last(executions)
      assert failed_execution.status == "failed"

      failed_run = Repo.one!(from(run in TaskRun, where: run.task_id == ^task.id))
      assert failed_run.status == :failed
      assert failed_run.latest_step_execution_id == failed_execution.id
      assert failed_run.outcome_kind == "retry_exhausted"

      assert failed_run.outcome_context["failed_execution_id"] == failed_execution.id
      assert failed_run.outcome_context["current_step_id"] == failed_execution.step_id
      assert failed_run.outcome_context["current_attempt"] == 5
      assert failed_run.outcome_context["max_attempts"] == 5
      assert failed_run.outcome_context["execution_found"]
      refute Map.has_key?(failed_run.outcome_context, "output_preview")
      refute Map.has_key?(failed_run.outcome_context, "logs")

      assert Repo.get!(Sacrum.Repo.Schemas.Task, task.id).completed_at == nil

      drain_run_step_broadcasts()
      refute_receive %Phoenix.Socket.Broadcast{event: "run_step"}, 50
    end

    test "successful completion resets the retry counter so the next step gets a full retry budget" do
      %{user: user, project: project, steps: [s1, s2, _s3], task: task} =
        setup_linear_workflow(step_count: 3, auto_advance: true)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      assert Repo.get!(Sacrum.Repo.Schemas.Task, task.id).current_step_id == s1.id

      # 4 failures on step_1 then a completion (5 executions for step_1)
      for n <- 1..4 do
        simulate_daemon_failure(task.id, project.id)
        wait_for_execution_count(task.id, n + 1)
      end

      simulate_daemon_completion(task.id, project.id, "step_1 recovered")

      wait_for_state(pid, :executing)
      assert Repo.get!(Sacrum.Repo.Schemas.Task, task.id).current_step_id == s2.id

      # If the counter didn't reset, even a single failure here would push to :failed
      # because run_retry_attempt would already be 4 from the prior step.
      simulate_daemon_failure(task.id, project.id)
      wait_for_execution_count(task.id, 7)
      assert {:executing, _} = :sys.get_state(pid)

      simulate_daemon_completion(task.id, project.id, "step_2 done")
      wait_for_exit(pid)

      assert Repo.get!(Sacrum.Repo.Schemas.Task, task.id).completed_at != nil
    end
  end
end
