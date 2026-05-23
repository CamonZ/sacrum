defmodule Sacrum.Orchestrator.Routing.WaitChildrenTest do
  @moduledoc """
  Tests that wait_children fan-out respects task dependencies — children
  whose blockers are not yet complete must not be dispatched at parent
  wait_children entry, while independent siblings still fan out in parallel.
  """

  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator
  alias Sacrum.Orchestrator.TaskCompletion
  alias Sacrum.Orchestrator.{FSMData, TaskRegistry}
  alias Sacrum.Orchestrator.Routing.WaitChildren
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  import Ecto.Query

  describe "handle_wait_children_entry/1 with dependencies" do
    test "keeps completed children in handoff but starts only incomplete children" do
      ctx = setup_workflows()
      parent = create_parent(ctx)

      completed_child =
        ctx
        |> create_child(parent, "Completed Child")
        |> complete_task()

      incomplete_child = create_child(ctx, parent, "Incomplete Child")

      track_orchestrator_cleanup([parent.id, completed_child.id, incomplete_child.id])

      data = build_parent_fsm_data(ctx, parent)
      assert {:stop_parent, _} = WaitChildren.handle_wait_children_entry(data)

      Process.sleep(80)

      assert Registry.lookup(TaskRegistry, completed_child.id) == [],
             "completed_child must remain in handoff but must not be started"

      assert Registry.lookup(TaskRegistry, incomplete_child.id) != [],
             "incomplete_child should be dispatched at fan-out"

      child_ids = waiting_handoff_child_ids(parent.id)
      assert Enum.sort(child_ids) == Enum.sort([completed_child.id, incomplete_child.id])

      assert active_task_runs(completed_child.id) == []
      assert [%TaskRun{status: status}] = active_task_runs(incomplete_child.id)
      assert status in [:queued, :executing]
    end

    test "dispatches only children whose blockers are complete" do
      ctx = setup_workflows()
      parent = create_parent(ctx)

      # child2 depends on child1; child1 has no blockers
      child1 = create_child(ctx, parent, "Child 1")
      child2 = create_child(ctx, parent, "Child 2")
      add_dependency(child2, child1)

      track_orchestrator_cleanup([parent.id, child1.id, child2.id])

      data = build_parent_fsm_data(ctx, parent)
      assert {:stop_parent, _} = WaitChildren.handle_wait_children_entry(data)

      Process.sleep(80)

      # child1 has no blockers, so it should be dispatched
      assert Registry.lookup(TaskRegistry, child1.id) != [],
             "child1 (no blockers) should have its orchestrator started"

      # child2 depends on child1 which is not yet completed -> must NOT be started
      assert Registry.lookup(TaskRegistry, child2.id) == [],
             "child2 (blocked by child1) must NOT have its orchestrator started"

      # The waiting StepExecution still captures both child_ids so the parent
      # waits for every child regardless of dispatch order.
      child_ids = waiting_handoff_child_ids(parent.id)
      assert Enum.sort(child_ids) == Enum.sort([child1.id, child2.id])
    end

    test "fans out independent siblings in parallel and defers blocked children" do
      ctx = setup_workflows()
      parent = create_parent(ctx)

      # 3 children:
      # - independent_a: no deps -> should start
      # - independent_b: no deps -> should start (parallel sibling)
      # - dependent_c: depends on independent_a -> must NOT start now
      independent_a = create_child(ctx, parent, "Independent A")
      independent_b = create_child(ctx, parent, "Independent B")
      dependent_c = create_child(ctx, parent, "Dependent C")
      add_dependency(dependent_c, independent_a)

      track_orchestrator_cleanup([
        parent.id,
        independent_a.id,
        independent_b.id,
        dependent_c.id
      ])

      data = build_parent_fsm_data(ctx, parent)
      assert {:stop_parent, _} = WaitChildren.handle_wait_children_entry(data)

      Process.sleep(80)

      assert Registry.lookup(TaskRegistry, independent_a.id) != [],
             "independent_a should be dispatched at fan-out"

      assert Registry.lookup(TaskRegistry, independent_b.id) != [],
             "independent_b should be dispatched in parallel with independent_a"

      assert Registry.lookup(TaskRegistry, dependent_c.id) == [],
             "dependent_c must wait for independent_a to complete before starting"

      child_ids = waiting_handoff_child_ids(parent.id)

      assert Enum.sort(child_ids) ==
               Enum.sort([independent_a.id, independent_b.id, dependent_c.id])
    end
  end

  # ===== Helpers =====

  defp setup_workflows do
    user = create_user()
    project = create_project(user)

    # Parent workflow: starts with a wait_children step
    parent_workflow = create_workflow(user, project, "Parent Workflow")
    parent_step = create_wait_children_step(user, parent_workflow)

    {:ok, parent_workflow} =
      Accounts.Workflows.update(parent_workflow, %{initial_step_id: parent_step.id})

    # Child workflow: a long-running execute step so child orchestrators
    # remain registered and observable after dispatch.
    child_workflow = create_workflow(user, project, "Child Workflow")
    child_step = create_execute_step(user, child_workflow)

    {:ok, child_workflow} =
      Accounts.Workflows.update(child_workflow, %{initial_step_id: child_step.id})

    %{
      user: user,
      project: project,
      parent_workflow: parent_workflow,
      parent_step: parent_step,
      child_workflow: child_workflow
    }
  end

  defp create_parent(ctx) do
    parent = create_task(ctx.user, ctx.project, %{title: "Parent"})
    parent = assign_workflow(parent, ctx.parent_workflow)
    {:ok, _parent_run} = Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, parent.id)
    parent
  end

  defp create_child(ctx, parent, title) do
    {:ok, child} = Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{title: title})
    {:ok, child} = Repo.TaskHierarchy.set_parent(child, parent)
    assign_workflow(child, ctx.child_workflow)
  end

  defp build_parent_fsm_data(ctx, parent) do
    {:ok, parent_run} = Accounts.TaskRuns.get_active_for_task(ctx.user.id, parent.id)
    workflow = Repo.preload(ctx.parent_workflow, :workflow_steps)

    steps =
      workflow.workflow_steps
      |> Enum.map(&{&1.id, &1})
      |> Map.new()

    %FSMData{
      user_id: ctx.user.id,
      project_id: ctx.project.id,
      task: parent,
      task_run_id: parent_run.id,
      workflow: workflow,
      steps: steps,
      transitions: %{},
      slot_id: nil,
      pending_handoff: nil,
      current_execution_id: nil
    }
  end

  defp create_user do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Repo.Users.insert(%{
        email: "wait-children-#{suffix}@example.com",
        username: "waitchildren#{suffix}",
        password: "password123"
      })

    user
  end

  defp create_project(user) do
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "WC Project"})
    project
  end

  defp create_workflow(user, project, name) do
    {:ok, workflow} =
      Accounts.Workflows.insert(user.id, project.id, %{
        name: name
      })

    workflow
  end

  defp create_wait_children_step(user, workflow) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(user.id, %{
        "name" => "Wait Children",
        "step_order" => 1,
        "is_final" => true,
        "step_type" => "wait_children",
        "agents" => ["test"],
        "skills" => ["test"],
        "agent_config" => %{"model" => "test-model"},
        "workflow_id" => workflow.id,
        "project_id" => workflow.project_id
      })

    step
  end

  defp create_execute_step(user, workflow) do
    {:ok, step} =
      Accounts.WorkflowSteps.insert(user.id, %{
        "name" => "Execute",
        "step_order" => 1,
        "is_final" => true,
        "step_type" => "execute",
        "agents" => ["test"],
        "skills" => ["test"],
        "agent_config" => %{"model" => "test-model"},
        "workflow_id" => workflow.id,
        "project_id" => workflow.project_id
      })

    step
  end

  defp create_task(user, project, attrs) do
    base = %{
      title: "Task",
      description: "x",
      level: "task",
      priority: "normal",
      tags: ["test"]
    }

    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, Map.merge(base, attrs))
    task
  end

  defp assign_workflow(task, workflow) do
    {:ok, task} = Repo.TaskWorkflows.assign_workflow(task, workflow)
    task
  end

  defp add_dependency(task, depends_on) do
    {:ok, _} = Repo.TaskDependencies.add_dependency(task, depends_on)
  end

  defp complete_task(task) do
    {:ok, task} = Repo.update(TaskCompletion.completion_changeset(task))
    task
  end

  defp waiting_handoff_child_ids(parent_id) do
    execution =
      Repo.one(
        from(e in StepExecution,
          where: e.task_id == ^parent_id and e.status == "waiting",
          order_by: [desc: e.inserted_at],
          limit: 1
        )
      )

    Map.get(execution.handoff || %{}, "child_ids", [])
  end

  defp active_task_runs(task_id) do
    Repo.all(
      from(tr in TaskRun,
        where: tr.task_id == ^task_id and tr.status in ^TaskRunStatus.active_statuses(),
        order_by: [asc: tr.inserted_at]
      )
    )
  end

  defp track_orchestrator_cleanup(task_ids) do
    on_exit(fn ->
      Enum.each(task_ids, fn id ->
        try do
          Orchestrator.stop(id)
        catch
          :exit, _ -> :ok
        end
      end)
    end)
  end
end
