defmodule Sacrum.Orchestrator.TaskOrchestratorTest do
  use Sacrum.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.FSMData
  alias Sacrum.Orchestrator.ExecutionPool
  alias Sacrum.Orchestrator.TaskOrchestrator
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}
  alias Sacrum.Repo.TaskDependencies

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
        name: Keyword.get(opts, :name, "Test Workflow")
      })

    workflow
  end

  defp create_step(user, workflow, attrs) do
    default_attrs = %{
      "name" => "Test Step",
      "step_order" => 1,
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
    {:ok, daemon, bootstrap} = Sacrum.Repo.Daemons.create(user.id)

    {:ok, _daemon, _reconnect, _credential} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

    default_attrs = %{
      title: "Test Task",
      description: "Test description",
      level: "task",
      priority: "medium",
      tags: ["test"],
      workspace: %{daemon_id: daemon.id, worktree_path: "/tmp/orchestrator-task"}
    }

    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, Map.merge(default_attrs, attrs))
    :ok = connect_daemon(Sacrum.Repo.Schemas.Task.workspace_daemon(task), user.id)
    task
  end

  defp assign_workflow_to_task(task, workflow) do
    {:ok, updated_task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)
    updated_task
  end

  defp intra_route_config(destination_id) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "approved",
          "when" => %{
            "ref" => "previous_output.route.result",
            "op" => "eq",
            "value" => "approved"
          },
          "transition" => %{"type" => "intra_workflow", "step_id" => destination_id}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "intra_workflow", "step_id" => destination_id}
      }
    }
  end

  defp inter_route_config(destination_workflow_id) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "approved",
          "when" => %{
            "ref" => "previous_output.route.result",
            "op" => "eq",
            "value" => "approved"
          },
          "transition" => %{
            "type" => "inter_workflow",
            "workflow_id" => destination_workflow_id
          }
        }
      ],
      "default" => %{
        "transition" => %{
          "type" => "inter_workflow",
          "workflow_id" => destination_workflow_id
        }
      }
    }
  end

  defp predecessor_schema(result_values) do
    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["result", "handoff"],
          "properties" => %{
            "result" => %{"type" => "string", "enum" => result_values},
            "handoff" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => [],
              "properties" => %{}
            }
          }
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end

  defp setup_linear_workflow(opts) do
    step_count = Keyword.get(opts, :step_count, 3)
    finish_last_step = Keyword.get(opts, :finish_last_step, true)

    user = create_user()
    project = create_project(user)
    workflow = create_workflow(user, project)

    steps =
      for i <- 1..step_count do
        prompt =
          if i == step_count or
               (Keyword.get(opts, :promptless_after_first, false) and i > 1) do
            nil
          else
            "Run step for task {task_id}"
          end

        create_step(user, workflow, %{
          name: "step_#{i}",
          step_order: i,
          step_type: if(i == step_count and finish_last_step, do: "finish", else: "execute"),
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

  defp wait_for_task_step(task, step_id, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_task_step(task, step_id, deadline)
  end

  defp do_wait_for_task_step(task, step_id, deadline) do
    reloaded = reload_task(task)

    cond do
      reloaded.current_step_id == step_id ->
        reloaded

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Timed out waiting for task to reach step #{step_id}")

      true ->
        Process.sleep(10)
        do_wait_for_task_step(task, step_id, deadline)
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

  defp latest_waiting_execution(task_id) do
    Repo.one!(
      from(e in StepExecution,
        where: e.task_id == ^task_id and e.status == "waiting",
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
      )
    )
  end

  # ===== Tests =====

  describe "single-step workflow" do
    test "completes a single finish step without dispatching it" do
      %{user: user, project: _project, task: task} =
        setup_linear_workflow(step_count: 1)

      pid = start_orchestrator(task, user)
      wait_for_exit(pid)

      task = reload_task(task)
      assert task.completed_at != nil

      executions = get_all_executions(task.id)
      assert executions == []

      task_run = latest_task_run(task.id)
      assert task_run.status == :completed
      assert task_run.latest_step_execution_id == nil
      assert %DateTime{} = task_run.ended_at
      assert {:error, :not_found} = Accounts.TaskRuns.get_active_for_task(user.id, task.id)
    end

    test "uses the root TaskRun scope when requesting an execution slot" do
      %{user: user, task: task} = setup_linear_workflow(step_count: 2)

      {:ok, task_run} =
        Accounts.TaskRuns.insert(user.id, task.project_id, task.id, %{
          status: :queued,
          max_concurrency: 1
        })

      {:ok, pid} =
        TaskOrchestrator.start_link(task_id: task.id, user_id: user.id, task_run_id: task_run.id)

      wait_for_state(pid, :executing)

      assert ExecutionPool.pool_status().in_use_by_scope == %{task_run.id => 1}

      ref = Process.monitor(pid)
      :ok = :gen_statem.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2000

      assert ExecutionPool.pool_status().in_use_by_scope == %{}
    end
  end

  describe "multi-step prompted continuation workflow" do
    test "persists configured structured output before advancing" do
      %{user: user, project: project, steps: [s1, s2, _s3], task: task} =
        setup_linear_workflow(step_count: 3)

      output_schema = %{
        "type" => "object",
        "properties" => %{"result" => %{"type" => "string"}},
        "required" => ["result"],
        "additionalProperties" => false
      }

      assert {:ok, _updated_step} =
               Accounts.WorkflowSteps.update(s1, %{
                 output_schema: output_schema,
                 persistence_options: %{"artifact" => %{"logical_name" => "step_result"}}
               })

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_completion(task.id, project.id, ~s({"result":"ready"}))

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s2.id

      assert [
               %{
                 filename: "step_result.json",
                 body: ~s({"result":"ready"}),
                 logical_name: "step_result"
               }
             ] =
               Accounts.Artifacts.list_for_subject(user.id, project.id, "task", task.id)

      :gen_statem.stop(pid)
    end

    test "persists completed human input output before advancing" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      output_schema = %{
        "type" => "object",
        "properties" => %{"result" => %{"type" => "string"}},
        "required" => ["result"],
        "additionalProperties" => false
      }

      human_step =
        create_step(user, workflow, %{
          name: "human_input",
          step_order: 1,
          step_type: "human_input",
          output_schema: output_schema,
          persistence_options: %{"artifact" => %{"logical_name" => "human_result"}}
        })

      finish_step =
        create_step(user, workflow, %{
          name: "finish",
          step_order: 2,
          step_type: "finish",
          prompt: nil
        })

      create_transition(user, human_step, finish_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: human_step.id})

      task = create_task(user, project) |> assign_workflow_to_task(workflow)
      pid = start_orchestrator(task, user)
      wait_for_exit(pid)

      waiting_execution = latest_waiting_execution(task.id)

      assert {:ok, _completed_execution} =
               Sacrum.Orchestrator.Routing.HumanInput.resume(
                 user.id,
                 waiting_execution.id,
                 %{"result" => "approved"}
               )

      wait_for_task_step(task, finish_step.id)

      assert [%{logical_name: "human_result", filename: "human_result.json", body: body}] =
               Accounts.Artifacts.list_for_subject(user.id, project.id, "task", task.id)

      assert Jason.decode!(body) == %{"result" => "approved"}
    end

    test "fails without advancing when configured structured output cannot be persisted" do
      %{user: user, project: _project, steps: [s1, _s2], task: task} =
        setup_linear_workflow(step_count: 2, finish_last_step: false)

      output_schema = %{
        "type" => "object",
        "properties" => %{"result" => %{"type" => "string"}},
        "required" => ["result"],
        "additionalProperties" => false
      }

      assert {:ok, _updated_step} =
               Accounts.WorkflowSteps.update(s1, %{
                 output_schema: output_schema,
                 persistence_options: %{"artifact" => %{"logical_name" => "step_result"}}
               })

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, task.project_id, "not json")
      wait_for_exit(pid)

      assert reload_task(task).current_step_id == s1.id
      assert latest_task_run(task.id).status == :failed
      assert [] = Accounts.Artifacts.list_for_subject(user.id, task.project_id, "task", task.id)
    end

    test "replaces an existing artifact when the task logical name already exists" do
      %{user: user, project: project, steps: [s1, s2], task: task} =
        setup_linear_workflow(step_count: 2, finish_last_step: false)

      output_schema = %{
        "type" => "object",
        "properties" => %{"result" => %{"type" => "string"}},
        "required" => ["result"],
        "additionalProperties" => false
      }

      assert {:ok, _updated_step} =
               Accounts.WorkflowSteps.update(s1, %{
                 output_schema: output_schema,
                 persistence_options: %{"artifact" => %{"logical_name" => "step_result"}}
               })

      assert {:ok, _existing} =
               Accounts.Artifacts.create_and_link(
                 user.id,
                 project.id,
                 %{filename: "existing.json", body: ~s({"result":"existing"})},
                 %{subject_type: "task", subject_id: task.id, logical_name: "step_result"}
               )

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id, ~s({"result":"ready"}))
      wait_for_state(pid, :executing)

      assert reload_task(task).current_step_id == s2.id
      assert latest_task_run(task.id).status in [:executing, :queued]

      assert [%{logical_name: "step_result", filename: "step_result.json", body: body}] =
               Accounts.Artifacts.list_for_subject(user.id, project.id, "task", task.id)

      assert Jason.decode!(body) == %{"result" => "ready"}
      :gen_statem.stop(pid)
    end

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

      wait_for_exit(pid)

      task = reload_task(task)
      assert task.completed_at != nil
      assert task.current_step_id == s3.id
    end

    test "does not create a step execution for the finish destination" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 3)

      pid = start_orchestrator(task, user)

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)

      wait_for_exit(pid)

      executions = get_all_executions(task.id)
      step_names = Enum.map(executions, & &1.step_name)

      assert "step_1" in step_names
      assert "step_2" in step_names
      refute "step_3" in step_names
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
      wait_for_exit(pid)
      assert reload_task(task).current_step_id == s3.id
    end
  end

  describe "finish step routing" do
    test "notifies dependents when a prompted step transitions into finish" do
      %{user: user, project: project, task: task} = setup_linear_workflow(step_count: 2)
      dependent_workflow = create_workflow(user, project, name: "Dependent Workflow")
      dependent_step = create_step(user, dependent_workflow, %{name: "dependent_step"})

      {:ok, _} =
        Accounts.Workflows.update(dependent_workflow, %{initial_step_id: dependent_step.id})

      dependent = create_task(user, project) |> assign_workflow_to_task(dependent_workflow)
      {:ok, _dependency} = TaskDependencies.add_dependency(dependent, task)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id)
      wait_for_exit(pid)

      assert [{dependent_pid, _}] =
               Registry.lookup(Sacrum.Orchestrator.TaskRegistry, dependent.id)

      Process.exit(dependent_pid, :shutdown)
    end

    test "routes to finish and completes without dispatching the destination" do
      %{user: user, project: project, steps: [s1, _s2, s3], task: task} =
        setup_linear_workflow(step_count: 3)

      pid = start_orchestrator(task, user)

      wait_for_state(pid, :executing)
      assert reload_task(task).current_step_id == s1.id
      simulate_daemon_completion(task.id, project.id, "s1 done")

      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id, "s2 done")
      wait_for_exit(pid)

      completed = reload_task(task)
      assert completed.current_step_id == s3.id
      assert completed.completed_at != nil

      executions = get_all_executions(task.id)
      assert Enum.map(executions, & &1.step_name) == ["step_1", "step_2"]
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
          step_type: "wait_children"
        })

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          step_type: "finish",
          prompt: nil
        })

      create_transition(user, wait_step, final_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent w/ wait_children"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      pid = start_orchestrator(parent_task, user)

      wait_for_exit(pid)

      completed = reload_task(parent_task)
      assert completed.current_step_id == final_step.id
      assert completed.completed_at != nil

      refute Enum.any?(get_all_executions(parent_task.id), &(&1.step_id == final_step.id))
    end
  end

  describe "stop step routing" do
    defp setup_stop_boundary_workflow do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      work_step =
        create_step(user, workflow, %{
          name: "work_step",
          step_order: 1,
          step_type: "execute",
          prompt: "Do the work"
        })

      stop_step =
        create_step(user, workflow, %{
          name: "stop_boundary",
          step_order: 2,
          step_type: "stop",
          prompt: nil
        })

      loop_start =
        create_step(user, workflow, %{
          name: "loop_start",
          step_order: 3,
          step_type: "execute",
          prompt: "Start the next iteration"
        })

      create_transition(user, work_step, stop_step)
      create_transition(user, stop_step, loop_start)
      create_transition(user, loop_start, stop_step)
      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: work_step.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      %{user: user, project: project, task: task, work_step: work_step, stop_step: stop_step}
    end

    test "ends the current run at stop without dispatching or completing the task" do
      %{user: user, project: project, task: task, stop_step: stop_step} =
        setup_stop_boundary_workflow()

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)
      simulate_daemon_completion(task.id, project.id, "work complete")
      wait_for_exit(pid)

      task = reload_task(task)
      task_run = latest_task_run(task.id)

      assert task.current_step_id == stop_step.id
      assert task.completed_at == nil
      assert task_run.status == :stopped
      assert task_run.outcome_kind == "run_boundary"
      assert task_run.outcome_context["reason"] == "stop_step"
      assert task_run.outcome_context["step_id"] == stop_step.id
      assert %DateTime{} = task_run.ended_at
      assert {:error, :not_found} = Accounts.TaskRuns.get_active_for_task(user.id, task.id)

      assert [%StepExecution{step_name: "work_step", status: "completed"}] =
               get_all_executions(task.id)
    end

    test "a new TaskRun bypasses stop and executes the destination in that run" do
      %{user: user, project: project, task: task, stop_step: stop_step} =
        setup_stop_boundary_workflow()

      first_pid = start_orchestrator(task, user)
      wait_for_state(first_pid, :executing)
      simulate_daemon_completion(task.id, project.id, "first iteration")
      wait_for_exit(first_pid)

      first_run = latest_task_run(task.id)
      assert first_run.status == :stopped

      second_pid = start_orchestrator(task, user)
      wait_for_state(second_pid, :executing)

      second_run = latest_task_run(task.id)
      assert second_run.id != first_run.id
      assert reload_task(task).current_step_id != stop_step.id

      second_execution = get_latest_started_execution(task.id)
      assert second_execution.task_run_id == second_run.id
      assert second_execution.step_name == "loop_start"

      simulate_daemon_completion(task.id, project.id, "second iteration")
      wait_for_exit(second_pid)

      final_run = latest_task_run(task.id)
      assert final_run.id == second_run.id
      assert final_run.status == :stopped
      assert final_run.outcome_kind == "run_boundary"
      refute reload_task(task).completed_at
    end
  end

  describe "non-prompted continuation workflow" do
    test "continues into a promptless execute step instead of stopping" do
      %{user: user, project: project, steps: [_s1, s2, _s3], task: task} =
        setup_linear_workflow(step_count: 3, promptless_after_first: true)

      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_completion(task.id, project.id)
      wait_for_task_step(task, s2.id)

      assert reload_task(task).completed_at == nil
      assert Process.alive?(pid)
    end

    test "completes at a promptless final sink step in a final workflow without executing it" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      active_step =
        create_step(user, workflow, %{
          name: "active_step",
          step_order: 1,
          prompt: "Run active step"
        })

      sink_step =
        create_step(user, workflow, %{
          name: "done_sink",
          step_order: 2,
          step_type: "finish",
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
        setup_linear_workflow(step_count: 1, finish_last_step: false)

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

  describe "configured workflow validation at TaskRun entry" do
    test "executes a configured route locally before it can acquire a daemon slot" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      source =
        create_step(user, workflow, %{
          name: "source",
          step_order: 1,
          output_schema: predecessor_schema(["approved"])
        })

      destination =
        create_step(user, workflow, %{
          name: "finish",
          step_order: 3,
          step_type: "finish",
          prompt: nil
        })

      route =
        create_step(user, workflow, %{
          name: "configured route",
          step_order: 2,
          step_type: "route",
          prompt: "This prompt must not be rendered",
          route_config: intra_route_config(destination.id)
        })

      create_transition(user, source, route)
      create_transition(user, route, destination)

      {:ok, _workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: source.id})

      task = create_task(user, project) |> assign_workflow_to_task(workflow)
      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_completion(
        task.id,
        project.id,
        Jason.encode!(%{"route" => %{"result" => "approved", "handoff" => %{}}})
      )

      wait_for_exit(pid)

      assert reload_task(task).current_step_id == destination.id
      assert latest_task_run(task.id).status == :completed

      assert [source_execution, route_execution] = get_all_executions(task.id)
      assert source_execution.step_id == source.id
      assert source_execution.status == "completed"

      assert %StepExecution{
               id: route_execution_id,
               step_id: route_step_id,
               status: "completed",
               task_run_id: route_run_id,
               handoff: nil,
               context: %{
                 "route" => %{
                   "mode" => "deterministic",
                   "source_execution_id" => source_execution_id,
                   "config_version" => 1,
                   "matched_rule_id" => "approved",
                   "used_default" => false,
                   "context" => %{
                     "execution" => %{"step_visit_count" => 1},
                     "previous_output" => %{
                       "route" => %{"result" => "approved", "handoff" => %{}}
                     }
                   }
                 }
               }
             } = route_execution

      assert source_execution_id == source_execution.id
      assert route_step_id == route.id
      assert route_run_id == latest_task_run(task.id).id
      assert latest_task_run(task.id).latest_step_execution_id == route_execution_id

      refute Map.has_key?(
               ExecutionPool.pool_status().in_use_by_scope,
               latest_task_run(task.id).id
             )
    end

    test "resumes after a deterministic intra-workflow route to an executable step" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      source =
        create_step(user, workflow, %{
          name: "source",
          step_order: 1,
          output_schema: predecessor_schema(["approved"])
        })

      destination =
        create_step(user, workflow, %{
          name: "destination",
          step_order: 3,
          step_type: "execute"
        })

      finish =
        create_step(user, workflow, %{
          name: "finish",
          step_order: 4,
          step_type: "finish",
          prompt: nil
        })

      route =
        create_step(user, workflow, %{
          name: "configured route",
          step_order: 2,
          step_type: "route",
          prompt: nil,
          route_config: intra_route_config(destination.id)
        })

      create_transition(user, source, route)
      create_transition(user, route, destination)
      create_transition(user, destination, finish)

      {:ok, _workflow} = Accounts.Workflows.update(workflow, %{initial_step_id: source.id})

      task = create_task(user, project) |> assign_workflow_to_task(workflow)
      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_completion(
        task.id,
        project.id,
        Jason.encode!(%{"route" => %{"result" => "approved", "handoff" => %{}}})
      )

      wait_for_state(pid, :executing)

      assert %{current_step_id: destination_id} = reload_task(task)

      assert %StepExecution{status: "started", step_id: ^destination_id} =
               Enum.find(get_all_executions(task.id), &(&1.step_id == destination.id))

      simulate_daemon_completion(task.id, project.id, "destination complete")
      wait_for_exit(pid)

      assert %{current_step_id: finish_id} = reload_task(task)
      assert finish_id == finish.id
      assert latest_task_run(task.id).status == :completed
    end

    test "resumes after a deterministic inter-workflow route to an executable step" do
      user = create_user()
      project = create_project(user)
      source_workflow = create_workflow(user, project, name: "Source Workflow")
      destination_workflow = create_workflow(user, project, name: "Destination Workflow")

      source =
        create_step(user, source_workflow, %{
          name: "source",
          step_order: 1,
          output_schema: predecessor_schema(["approved"])
        })

      destination =
        create_step(user, destination_workflow, %{
          name: "destination",
          step_order: 1,
          step_type: "execute"
        })

      finish =
        create_step(user, destination_workflow, %{
          name: "finish",
          step_order: 2,
          step_type: "finish",
          prompt: nil
        })

      create_transition(user, destination, finish)

      {:ok, _workflow_transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          from_workflow_id: source_workflow.id,
          to_workflow_id: destination_workflow.id,
          project_id: project.id,
          target_step_id: destination.id
        })

      route =
        create_step(user, source_workflow, %{
          name: "configured route",
          step_order: 2,
          step_type: "route",
          prompt: nil,
          route_config: inter_route_config(destination_workflow.id)
        })

      create_transition(user, source, route)

      {:ok, _workflow} = Accounts.Workflows.update(source_workflow, %{initial_step_id: source.id})

      {:ok, _workflow} =
        Accounts.Workflows.update(destination_workflow, %{initial_step_id: destination.id})

      task = create_task(user, project) |> assign_workflow_to_task(source_workflow)
      pid = start_orchestrator(task, user)
      wait_for_state(pid, :executing)

      simulate_daemon_completion(
        task.id,
        project.id,
        Jason.encode!(%{"route" => %{"result" => "approved", "handoff" => %{}}})
      )

      wait_for_state(pid, :executing)

      assert %{workflow_id: destination_workflow_id, current_step_id: destination_id} =
               reload_task(task)

      assert destination_workflow_id == destination_workflow.id

      assert %StepExecution{status: "started", step_id: ^destination_id} =
               Enum.find(get_all_executions(task.id), &(&1.step_id == destination.id))

      simulate_daemon_completion(task.id, project.id, "destination complete")
      wait_for_exit(pid)

      assert %{current_step_id: finish_id} = reload_task(task)
      assert finish_id == finish.id
      assert latest_task_run(task.id).status == :completed
    end

    test "fails a drifted invalid graph before slot allocation or step execution" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)

      source =
        create_step(user, workflow, %{
          name: "source",
          step_order: 1,
          output_schema: predecessor_schema(["approved"])
        })

      destination =
        create_step(user, workflow, %{
          name: "destination",
          step_order: 2,
          step_type: "finish",
          prompt: nil
        })

      route =
        create_step(user, workflow, %{
          name: "route",
          step_order: 3,
          step_type: "route",
          route_config: intra_route_config(destination.id)
        })

      create_transition(user, source, route)
      outgoing = create_transition(user, route, destination)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: source.id})

      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)
      assert task.current_step_id == source.id

      Repo.delete(outgoing)

      pid = start_orchestrator(task, user)
      wait_for_exit(pid)

      task_run = latest_task_run(task.id)
      assert task_run.status == :failed
      assert reload_task(task).current_step_id == source.id
      assert get_all_executions(task.id) == []
      refute Map.has_key?(ExecutionPool.pool_status().in_use_by_scope, task_run.id)
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
        setup_linear_workflow(step_count: 1, finish_last_step: false)

      logs =
        capture_log(fn ->
          pid = start_orchestrator(task, user)
          wait_for_state(pid, :executing)
          simulate_daemon_completion(task.id, project.id)
          wait_for_exit(pid)
        end)

      assert logs =~ "[TaskOrchestrator:#{task.id}] terminate reason=:normal"
    end
  end

  describe "execution failure retry" do
    test "failure log line includes the attempt counter" do
      %{user: user, project: project, task: task} =
        setup_linear_workflow(step_count: 1, finish_last_step: false)

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
        setup_linear_workflow(step_count: 1, finish_last_step: false)

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
    defp create_wait_children_step(user, workflow, attrs \\ %{}) do
      create_step(
        user,
        workflow,
        Map.merge(
          %{
            name: "wait_children",
            step_order: 1,
            step_type: "wait_children"
          },
          attrs
        )
      )
    end

    defp create_child_task(user, project, parent_task) do
      task = create_task(user, project, %{title: "Child Task"})

      {:ok, task} = Accounts.Tasks.update(task, %{parent_id: parent_task.id})

      {:ok, task} =
        Accounts.Tasks.update(task, %{
          workspace: %{
            daemon_id: Sacrum.Repo.Schemas.Task.workspace_daemon(parent_task),
            worktree_path: Sacrum.Repo.Schemas.Task.workspace_worktree(task)
          }
        })

      task
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
          step_type: "finish",
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
          step_type: "finish",
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
          step_order: 1
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow_1, %{initial_step_id: child_step_1.id})

      child_task_1 = create_child_task(user, project, parent_task)
      child_task_1 = assign_workflow_to_task(child_task_1, child_workflow_1)

      child_workflow_2 = create_workflow(user, project)

      child_step_2 =
        create_step(user, child_workflow_2, %{
          name: "child_step_2",
          step_order: 1
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
          step_type: "finish",
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
          step_type: "human_input"
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
          step_type: "finish",
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
          step_order: 1
        })

      {:ok, _} = Accounts.Workflows.update(child_workflow_1, %{initial_step_id: child_step_1.id})

      child_task_1 = create_child_task(user, project, parent_task)
      child_task_1 = assign_workflow_to_task(child_task_1, child_workflow_1)

      child_workflow_2 = create_workflow(user, project)

      child_step_2 =
        create_step(user, child_workflow_2, %{
          name: "child_step_2",
          step_order: 1
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
          step_order: 2
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
          step_order: 1
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
          step_order: 2
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
          step_order: 1
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
          step_order: 1
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
          step_order: 2
        })

      create_transition(user, parent_wait_step, parent_final_step)

      {:ok, _} =
        Accounts.Workflows.update(parent_workflow, %{initial_step_id: parent_wait_step.id})

      # Create parent
      parent_task = create_task(user, project, %{title: "Parent"})
      parent_task = assign_workflow_to_task(parent_task, parent_workflow)

      {:ok, root_task_run} =
        Accounts.TaskRuns.insert(user.id, project.id, parent_task.id, %{
          status: :queued,
          max_concurrency: 1
        })

      # Create child workflow with wait_children
      child_workflow = create_workflow(user, project)
      child_wait_step = create_wait_children_step(user, child_workflow)

      child_final_step =
        create_step(user, child_workflow, %{
          name: "child_final",
          step_order: 2
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
          step_order: 1
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
      assert parent_run.id == root_task_run.id
      assert parent_run.max_concurrency == 1

      assert child_run.parent_task_run_id == parent_run.id
      assert child_run.root_task_run_id == parent_run.id
      assert child_run.triggered_by_step_execution_id == parent_waiting_exec.id
      assert child_run.max_concurrency == nil

      assert leaf_run.parent_task_run_id == child_run.id
      assert leaf_run.root_task_run_id == parent_run.id
      assert leaf_run.triggered_by_step_execution_id == child_waiting_exec.id
      assert leaf_run.max_concurrency == nil

      assert {:ok, %{id: parent_root_id, max_concurrency: 1}} =
               Accounts.TaskRuns.get_concurrency_scope(child_run)

      assert parent_root_id == parent_run.id

      assert {:ok, %{id: ^parent_root_id, max_concurrency: 1}} =
               Accounts.TaskRuns.get_concurrency_scope(leaf_run)

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
          step_order: 2
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1
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
          step_order: 2
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      child_workflow = create_workflow(user, project)

      child_step =
        create_step(user, child_workflow, %{
          name: "child_step",
          step_order: 1
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

      wait_step =
        create_wait_children_step(user, workflow, %{
          output_schema: %{"type" => "object"},
          persistence_options: %{"artifact" => %{"logical_name" => "children_result"}}
        })

      final_step =
        create_step(user, workflow, %{
          name: "final_step",
          step_order: 2,
          step_type: "finish",
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
          step_order: 1
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

      assert [%{logical_name: "children_result", filename: "children_result.json", body: body}] =
               Accounts.Artifacts.list_for_subject(user.id, project.id, "task", parent_task.id)

      assert Jason.decode!(body)["snapshot_type"] == "wait_children_status"

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
          step_order: 2
        })

      create_transition(user, wait_step, final_step)

      {:ok, _} = Accounts.Workflows.update(workflow, %{initial_step_id: wait_step.id})

      parent_task = create_task(user, project, %{title: "Parent Task"})
      parent_task = assign_workflow_to_task(parent_task, workflow)

      child_workflow_1 = create_workflow(user, project)

      child_step_1 =
        create_step(user, child_workflow_1, %{
          name: "child_step_1",
          step_order: 1
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
          output_schema: predecessor_schema(["approved"])
        })

      {:ok, _} = Accounts.Workflows.update(source_workflow, %{initial_step_id: source_step.id})

      dest_workflow = create_workflow(user, project)

      dest_step =
        create_step(user, dest_workflow, %{
          name: "dest_step",
          step_order: 1
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
          route_config: inter_route_config(dest_workflow.id)
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
                e.step_type == :wait_children and
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
          step_order: 1
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
      assert waiting_exec.step_type == :wait_children
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
          step_order: 1
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
