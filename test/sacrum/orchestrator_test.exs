defmodule Sacrum.OrchestratorTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator
  alias Sacrum.Orchestrator.TaskFSMSupervisor
  alias Sacrum.Orchestrator.TaskRegistry
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

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

  defp create_task(user, project, attrs \\ %{}) do
    default_attrs = %{
      title: "Test Task",
      description: "Test description",
      level: "task",
      priority: "medium",
      tags: ["test"]
    }

    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, Map.merge(default_attrs, attrs))
    task
  end

  defp assign_workflow_to_task(task, workflow) do
    {:ok, updated_task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)
    updated_task
  end

  defp create_step_execution(task, user_id, status, task_run_id \\ nil) do
    {:ok, execution} =
      Accounts.StepExecutions.insert(user_id, %{
        task_id: task.id,
        task_run_id: task_run_id,
        step_name: "Test Step",
        status: status,
        workflow_id: task.workflow_id,
        project_id: task.project_id
      })

    execution
  end

  defp create_task_run(task, user_id, status \\ :executing) do
    {:ok, task_run} =
      Accounts.TaskRuns.insert(user_id, task.project_id, task.id, %{status: status})

    task_run
  end

  describe "Orchestrator.stop/1" do
    test "returns {:ok, :stopped} when an orchestrator exists and terminates the registered pid" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      child_spec = {Sacrum.Orchestrator.TaskOrchestrator, task_id: task.id, user_id: user.id}
      {:ok, pid} = TaskFSMSupervisor.start_child(child_spec)
      assert [{^pid, _}] = Registry.lookup(TaskRegistry, task.id)

      assert {:ok, :stopped} = Orchestrator.stop(task.id)

      Process.sleep(50)
      assert [] = Registry.lookup(TaskRegistry, task.id)
    end

    test "returns {:ok, :not_running} when no orchestrator is registered" do
      task_id = Ecto.UUID.generate()
      assert {:ok, :not_running} = Orchestrator.stop(task_id)
    end

    test "is idempotent: calling stop twice on the same task succeeds both times" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)
      _task_run = create_task_run(task, user.id, :executing)

      assert {:ok, :stopped} = Orchestrator.stop(task.id)
      assert {:ok, :not_running} = Orchestrator.stop(task.id)
    end

    test "stops a durable active TaskRun when no FSM is registered" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)
      task_run = create_task_run(task, user.id, :waiting)

      assert {:ok, :stopped} = Orchestrator.stop(task.id)

      stopped_run = Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id)
      assert stopped_run.status == :stopped
      assert %DateTime{} = stopped_run.stop_requested_at
      assert %DateTime{} = stopped_run.ended_at
    end
  end

  describe "Orchestrator.stop/1 with active StepExecution" do
    setup do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project) |> assign_workflow_to_task(workflow)

      test_pid = self()
      ref = make_ref()

      fake_orchestrator =
        spawn_link(fn ->
          {:ok, _} = Registry.register(TaskRegistry, task.id, nil)
          send(test_pid, {ref, :registered})
          receive do: ({:stop, ^ref} -> :ok)
        end)

      receive do: ({^ref, :registered} -> :ok)

      on_exit(fn ->
        if Process.alive?(fake_orchestrator), do: send(fake_orchestrator, {:stop, ref})
      end)

      task_run = create_task_run(task, user.id)

      {:ok, user: user, task: task, task_run: task_run}
    end

    test "cancels when the latest StepExecution status is 'in_progress'", ctx do
      execution = create_step_execution(ctx.task, ctx.user.id, "in_progress", ctx.task_run.id)

      assert {:ok, :stopped} = Orchestrator.stop(ctx.task.id)

      assert Repo.get!(StepExecution, execution.id).status == "cancelled"
      stopped_run = Repo.get!(Sacrum.Repo.Schemas.TaskRun, ctx.task_run.id)
      assert stopped_run.status == :stopped
      assert %DateTime{} = stopped_run.stop_requested_at
      assert %DateTime{} = stopped_run.ended_at
    end

    test "cancels when status is 'waiting'", ctx do
      execution = create_step_execution(ctx.task, ctx.user.id, "waiting", ctx.task_run.id)

      assert {:ok, :stopped} = Orchestrator.stop(ctx.task.id)

      assert Repo.get!(StepExecution, execution.id).status == "cancelled"
    end

    test "cancels when status is 'started' (existing behavior preserved)", ctx do
      execution = create_step_execution(ctx.task, ctx.user.id, "started", ctx.task_run.id)

      assert {:ok, :stopped} = Orchestrator.stop(ctx.task.id)

      assert Repo.get!(StepExecution, execution.id).status == "cancelled"
    end

    test "leaves a 'completed' row unchanged", ctx do
      execution = create_step_execution(ctx.task, ctx.user.id, "completed")

      assert {:ok, :stopped} = Orchestrator.stop(ctx.task.id)

      assert Repo.get!(StepExecution, execution.id).status == "completed"
    end

    test "matches the latest in-flight execution by inserted_at desc", ctx do
      older = create_step_execution(ctx.task, ctx.user.id, "started", ctx.task_run.id)
      Process.sleep(10)
      newer = create_step_execution(ctx.task, ctx.user.id, "in_progress", ctx.task_run.id)

      assert {:ok, :stopped} = Orchestrator.stop(ctx.task.id)

      assert Repo.get!(StepExecution, older.id).status == "started"
      assert Repo.get!(StepExecution, newer.id).status == "cancelled"
    end

    test "does not cancel a stale in-flight row from another run", ctx do
      {:ok, old_task_run} =
        Accounts.TaskRuns.insert(ctx.user.id, ctx.task.project_id, ctx.task.id, %{
          status: :failed,
          ended_at: DateTime.utc_now()
        })

      stale = create_step_execution(ctx.task, ctx.user.id, "in_progress", old_task_run.id)

      assert {:ok, :stopped} = Orchestrator.stop(ctx.task.id)

      assert Repo.get!(StepExecution, stale.id).status == "in_progress"
      assert Repo.get!(Sacrum.Repo.Schemas.TaskRun, ctx.task_run.id).status == :stopped
    end

    test "does not re-cancel a row already in 'cancelled' state", ctx do
      execution = create_step_execution(ctx.task, ctx.user.id, "cancelled")

      assert {:ok, :stopped} = Orchestrator.stop(ctx.task.id)

      assert Repo.get!(StepExecution, execution.id).status == "cancelled"
    end
  end
end
