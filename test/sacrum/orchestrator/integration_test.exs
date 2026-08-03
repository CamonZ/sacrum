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
  alias Sacrum.Orchestrator.ExecutionPool
  alias Sacrum.Orchestrator.Routing.HumanInput
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

  defp create_workflow(user, project) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: "Integration Workflow"
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "step",
      "step_order" => 1,
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
        level: "task",
        priority: "medium",
        tags: ["test"]
      })

    task
  end

  defp setup_linear_workflow(opts) do
    step_count = Keyword.get(opts, :step_count, 3)
    finish_last_step = Keyword.get(opts, :finish_last_step, true)
    first_prompt = Keyword.get(opts, :first_prompt, "Run step for task {task_id}")
    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project)

    steps =
      for i <- 1..step_count do
        create_step(user, workflow, %{
          name: "step_#{i}",
          step_order: i,
          step_type: if(i == step_count and finish_last_step, do: "finish", else: "execute"),
          prompt: if(i == step_count and finish_last_step, do: nil, else: first_prompt)
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

  defp setup_human_input_workflow(opts) do
    next_final? = Keyword.get(opts, :next_final?, false)
    next_prompt = Keyword.get(opts, :next_prompt, "After human input")
    human_prompt = Keyword.get(opts, :human_prompt, "Approve {{ task.title }}")

    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project)

    schema = %{
      "type" => "object",
      "properties" => %{
        "approved" => %{"type" => "boolean"}
      },
      "required" => ["approved"],
      "additionalProperties" => false
    }

    human_step =
      create_step(user, workflow, %{
        name: "human_input",
        step_order: 1,
        step_type: "human_input",
        output_schema: schema,
        prompt: human_prompt
      })

    next_step =
      create_step(user, workflow, %{
        name: "after_human_input",
        step_order: 2,
        step_type: if(next_final?, do: "finish", else: "execute"),
        prompt: if(next_final?, do: nil, else: next_prompt)
      })

    create_transition(user, human_step, next_step)
    {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: human_step.id})

    task = create_task(user, project)
    {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)

    %{
      user: user,
      project: project,
      workflow: workflow,
      human_step: human_step,
      next_step: next_step,
      task: task,
      schema: schema
    }
  end

  # ===== Orchestration helpers =====

  defp subscribe_project(project_id) do
    :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project_id}")
  end

  defp start_orchestrator(task, user, opts \\ []) do
    child_spec = {TaskOrchestrator, [task_id: task.id, user_id: user.id] ++ opts}
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

  defp wait_for_orchestrator(task_id, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_orchestrator(task_id, deadline)
  end

  defp do_wait_for_orchestrator(task_id, deadline) do
    case Registry.lookup(TaskRegistry, task_id) do
      [{pid, _}] ->
        pid

      [] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("Timed out waiting for orchestrator for task #{task_id}")
        end

        Process.sleep(10)
        do_wait_for_orchestrator(task_id, deadline)
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

  defp simulate_daemon_completion(task_id, _project_id, output) do
    execution = latest_started_execution(task_id)

    {:ok, updated} =
      execution
      |> StepExecution.update_changeset(%{status: "completed", output: output})
      |> Repo.update()

    Sacrum.Orchestrator.ExecutionEvents.broadcast_status_changed(updated)

    updated
  end

  defp simulate_daemon_failure(task_id, _project_id) do
    execution = latest_started_execution(task_id)

    {:ok, updated} =
      execution
      |> StepExecution.update_changeset(%{status: "failed", output: "daemon error"})
      |> Repo.update()

    Sacrum.Orchestrator.ExecutionEvents.broadcast_status_changed(updated)

    updated
  end

  defp wait_for_execution_count(task_id, expected, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_execution_count(task_id, expected, deadline)
  end

  defp wait_until(fun, description, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, description, deadline)
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

  defp do_wait_until(fun, description, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Timed out waiting for #{description}")

      true ->
        Process.sleep(10)
        do_wait_until(fun, description, deadline)
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

  describe "human_input orchestration" do
    test "renders task artifact IDs in the persisted human_input prompt" do
      %{user: user, human_step: human_step, task: task} =
        setup_human_input_workflow(
          next_final?: true,
          human_prompt:
            ~s|Approve artifact {{ artifacts["task_run"]["result"].id }} prior={{ artifacts["step_execution"]["history"][0]["prior"].id }}|
        )

      {:ok, task_run} =
        Accounts.TaskRuns.insert(user.id, task.project_id, task.id, %{status: :queued})

      {:ok, prior_execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          project_id: task.project_id,
          task_run_id: task_run.id,
          workflow_id: human_step.workflow_id,
          step_name: "prior",
          status: "completed"
        })

      {:ok, %{artifact: prior_artifact}} =
        Accounts.Artifacts.create_and_link(
          user.id,
          task.project_id,
          %{filename: "human-prior-result.json", body: "private human prior body"},
          %{
            subject_type: "step_execution",
            subject_id: prior_execution.id,
            logical_name: "prior"
          }
        )

      {:ok, %{artifact: artifact}} =
        Accounts.Artifacts.create_and_link(
          user.id,
          task.project_id,
          %{filename: "human-task-run-result.json", body: "private human task-run body"},
          %{subject_type: "task_run", subject_id: task_run.id, logical_name: "result"}
        )

      pid = start_orchestrator(task, user, task_run_id: task_run.id)
      wait_for_exit(pid)

      [prior, execution] = executions_for_task(task.id)

      assert %StepExecution{
               step_id: step_id,
               status: "waiting",
               prompt: prompt
             } = execution

      assert step_id == human_step.id
      assert prompt == "Approve artifact #{artifact.id} prior=#{prior_artifact.id}"
      assert execution.prompt == prompt
      assert prior.id == prior_execution.id
      refute prompt =~ "private human task-run body"
      refute prompt =~ "private human prior body"
    end

    test "entering a human_input step parks the run without daemon dispatch" do
      %{user: user, project: project, human_step: human_step, task: task} =
        setup_human_input_workflow(next_final?: true)

      available_before = ExecutionPool.pool_status().available_slots
      subscribe_project(project.id)

      pid = start_orchestrator(task, user)
      wait_for_exit(pid)

      assert ExecutionPool.pool_status().available_slots == available_before

      assert [
               %StepExecution{
                 step_id: step_id,
                 step_name: "human_input",
                 step_type: :human_input,
                 status: "waiting",
                 output: nil,
                 prompt: "Approve Integration Task"
               } = execution
             ] = executions_for_task(task.id)

      assert step_id == human_step.id

      task_run = Repo.one!(from(run in TaskRun, where: run.task_id == ^task.id))
      assert task_run.status == :waiting
      assert task_run.latest_step_execution_id == execution.id

      refute_receive %Phoenix.Socket.Broadcast{event: "run_step"}, 100
    end

    test "valid human output completes the waiting execution and resumes the same TaskRun" do
      %{
        user: user,
        project: project,
        next_step: next_step,
        task: task
      } =
        setup_human_input_workflow(
          next_prompt: "Approved: {{ execution.previous_output.approved }}"
        )

      subscribe_project(project.id)

      pid = start_orchestrator(task, user)
      wait_for_exit(pid)
      [waiting_execution] = executions_for_task(task.id)
      task_run = Repo.one!(from(run in TaskRun, where: run.task_id == ^task.id))
      drain_run_step_broadcasts()

      assert {:ok, %StepExecution{id: resumed_id}} =
               HumanInput.resume(user.id, waiting_execution.id, %{approved: true})

      assert resumed_id == waiting_execution.id
      wait_for_execution_count(task.id, 2)

      [completed_human, next_execution] = executions_for_task(task.id)
      assert completed_human.id == waiting_execution.id
      assert completed_human.status == "completed"
      assert completed_human.output == ~s({"approved":true})
      assert Jason.decode!(completed_human.output) == %{"approved" => true}

      assert next_execution.step_id == next_step.id
      assert next_execution.status == "started"
      assert next_execution.task_run_id == task_run.id

      assert [same_run] = Repo.all(from(run in TaskRun, where: run.task_id == ^task.id))
      assert same_run.id == task_run.id
      assert same_run.status == :executing
      assert same_run.latest_step_execution_id == next_execution.id

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "run_step",
                       payload: %{id: next_execution_id, prompt: "Approved: true"}
                     },
                     1500

      assert next_execution_id == next_execution.id

      assert {:ok, :stopped} = Orchestrator.stop(task.id)
      wait_for_registry_clear(task.id)
    end

    test "invalid human output leaves the StepExecution and TaskRun waiting" do
      %{user: user, project: project, task: task} =
        setup_human_input_workflow(next_final?: true)

      subscribe_project(project.id)

      pid = start_orchestrator(task, user)
      wait_for_exit(pid)
      [waiting_execution] = executions_for_task(task.id)
      drain_run_step_broadcasts()

      assert {:error, {:invalid_human_input, {:validation_failed, errors}}} =
               HumanInput.resume(user.id, waiting_execution.id, %{"approved" => "yes"})

      assert [_ | _] = errors

      reloaded_execution = Repo.get!(StepExecution, waiting_execution.id)
      assert reloaded_execution.status == "waiting"
      assert reloaded_execution.output == nil

      task_run = Repo.one!(from(run in TaskRun, where: run.task_id == ^task.id))
      assert task_run.status == :waiting
      assert task_run.latest_step_execution_id == waiting_execution.id

      assert Registry.lookup(TaskRegistry, task.id) == []
      refute_receive %Phoenix.Socket.Broadcast{event: "run_step"}, 100
    end

    test "resume from another user is rejected and leaves the run waiting" do
      %{user: user, task: task} = setup_human_input_workflow(next_final?: true)

      suffix = System.unique_integer([:positive])

      {:ok, other_user} =
        Repo.Users.insert(%{
          email: "human-input-other-#{suffix}@example.com",
          username: "human_input_other_#{suffix}",
          password: "password123"
        })

      pid = start_orchestrator(task, user)
      wait_for_exit(pid)
      [waiting_execution] = executions_for_task(task.id)

      assert {:error, :not_found} =
               HumanInput.resume(other_user.id, waiting_execution.id, %{"approved" => true})

      reloaded_execution = Repo.get!(StepExecution, waiting_execution.id)
      assert reloaded_execution.status == "waiting"
      assert reloaded_execution.output == nil

      task_run = Repo.one!(from(run in TaskRun, where: run.task_id == ^task.id))
      assert task_run.status == :waiting
      assert Registry.lookup(TaskRegistry, task.id) == []
    end

    test "valid human output can complete the workflow when the next step is final" do
      %{user: user, project: _project, task: task} =
        setup_human_input_workflow(next_final?: true)

      pid = start_orchestrator(task, user)
      wait_for_exit(pid)
      [waiting_execution] = executions_for_task(task.id)

      assert {:ok, _completed} =
               HumanInput.resume(user.id, waiting_execution.id, %{"approved" => true})

      resumed_pid = wait_for_orchestrator(task.id)
      assert is_pid(resumed_pid)

      wait_until(
        fn -> Repo.get!(Sacrum.Repo.Schemas.Task, task.id).completed_at != nil end,
        "task completion after human_input resume"
      )

      assert [task_run] = Repo.all(from(run in TaskRun, where: run.task_id == ^task.id))
      assert task_run.status == :completed
      assert task_run.outcome_kind == "completed"
    end
  end

  describe "transition to next step on daemon completion" do
    test "creates a new started execution and broadcasts run_step for step_2" do
      %{user: user, project: project, steps: [_s1, s2, _s3], task: task} =
        setup_linear_workflow(step_count: 3)

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
        setup_linear_workflow(step_count: 3)

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
      %{user: user, project: _project, task: task} =
        setup_linear_workflow(step_count: 1, finish_last_step: false)

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
    test "retries render and persist the same task artifact ID" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(
          step_count: 1,
          finish_last_step: false,
          first_prompt:
            ~s|Retry task={{ artifacts["task_run"]["result"].id }} previous={{ artifacts["step_execution"]["history"][0]["result"].id }} older={{ artifacts["step_execution"]["history"][1]["result"].id }}|
        )

      {:ok, task_run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      {:ok, %{artifact: artifact}} =
        Accounts.Artifacts.create_and_link(
          user.id,
          project.id,
          %{filename: "retry-task-run-result.json", body: "private retry task-run body"},
          %{subject_type: "task_run", subject_id: task_run.id, logical_name: "result"}
        )

      first_expected = "Retry task=#{artifact.id} previous= older="
      subscribe_project(project.id)

      pid = start_orchestrator(task, user, task_run_id: task_run.id)
      wait_for_state(pid, :executing)
      first_exec = latest_started_execution(task.id)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "run_step",
                       payload: %{id: first_id, prompt: ^first_expected}
                     },
                     1500

      assert first_id == first_exec.id
      assert first_exec.prompt == first_expected

      {:ok, %{artifact: first_artifact}} =
        Accounts.Artifacts.create_and_link(
          user.id,
          project.id,
          %{filename: "first-step-result.json", body: "private first execution body"},
          %{
            subject_type: "step_execution",
            subject_id: first_exec.id,
            logical_name: "result"
          }
        )

      simulate_daemon_failure(task.id, project.id)
      wait_for_execution_count(task.id, 2)

      [_failed, retry] = executions_for_task(task.id)
      retry_expected = "Retry task=#{artifact.id} previous=#{first_artifact.id} older="
      assert retry.prompt == retry_expected

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "run_step",
                       payload: %{id: retry_id, prompt: ^retry_expected}
                     },
                     1500

      assert retry_id == retry.id

      {:ok, %{artifact: retry_artifact}} =
        Accounts.Artifacts.create_and_link(
          user.id,
          project.id,
          %{filename: "retry-step-result.json", body: "private retry execution body"},
          %{
            subject_type: "step_execution",
            subject_id: retry.id,
            logical_name: "result"
          }
        )

      simulate_daemon_failure(task.id, project.id)
      wait_for_execution_count(task.id, 3)

      [_first_failed, _second_failed, second_retry] = executions_for_task(task.id)

      second_retry_expected =
        "Retry task=#{artifact.id} previous=#{retry_artifact.id} older=#{first_artifact.id}"

      assert second_retry.prompt == second_retry_expected

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "run_step",
                       payload: %{id: second_retry_id, prompt: ^second_retry_expected}
                     },
                     1500

      assert second_retry_id == second_retry.id
      refute second_retry.prompt =~ "private first execution body"
      refute second_retry.prompt =~ "private retry execution body"
    end

    test "single failure inserts a fresh started execution and re-broadcasts run_step for the same step" do
      %{user: user, project: project, steps: [s1 | _], task: task} =
        setup_linear_workflow(step_count: 1, finish_last_step: false)

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
        setup_linear_workflow(step_count: 1, finish_last_step: false)

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
      %{user: user, project: project, steps: [s1, s2, s3], task: task} =
        setup_linear_workflow(step_count: 3)

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

      completed_task = Repo.get!(Sacrum.Repo.Schemas.Task, task.id)
      assert completed_task.completed_at != nil
      refute Enum.any?(executions_for_task(task.id), &(&1.step_id == s3.id))
    end
  end
end
