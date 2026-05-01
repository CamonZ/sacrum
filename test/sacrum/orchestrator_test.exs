defmodule Sacrum.OrchestratorTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator
  alias Sacrum.Orchestrator.TaskFSMSupervisor
  alias Sacrum.Orchestrator.TaskRegistry

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

  describe "Orchestrator.stop/1" do
    test "returns {:ok, :stopped} when an orchestrator exists and terminates the registered pid" do
      user = create_user()
      project = create_project(user)
      workflow = create_workflow(user, project, auto_advance: false)
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
      workflow = create_workflow(user, project, auto_advance: false)
      _step = create_step(user, workflow, %{})
      task = create_task(user, project)
      task = assign_workflow_to_task(task, workflow)

      child_spec = {Sacrum.Orchestrator.TaskOrchestrator, task_id: task.id, user_id: user.id}
      {:ok, _pid} = TaskFSMSupervisor.start_child(child_spec)

      assert {:ok, :stopped} = Orchestrator.stop(task.id)
      Process.sleep(50)
      assert {:ok, :not_running} = Orchestrator.stop(task.id)
    end
  end
end
