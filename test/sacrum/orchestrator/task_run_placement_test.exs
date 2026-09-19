defmodule Sacrum.Orchestrator.TaskRunPlacementTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.TaskRunPlacement
  alias Sacrum.Repo.Schemas.{StepExecution, Task}

  setup do
    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "placement-#{System.unique_integer([:positive])}@example.com",
        username: "placement#{System.unique_integer([:positive])}",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Placement Project"})
    {:ok, root_daemon, root_bootstrap} = Sacrum.Repo.Daemons.create(user.id)
    {:ok, other_daemon, other_bootstrap} = Sacrum.Repo.Daemons.create(user.id)

    {:ok, _root_daemon, _root_reconnect, _root_credential} =
      Accounts.Daemons.exchange_bootstrap(root_daemon.id, root_bootstrap)

    {:ok, _other_daemon, _other_reconnect, _other_credential} =
      Accounts.Daemons.exchange_bootstrap(other_daemon.id, other_bootstrap)

    {:ok, root_task} =
      Accounts.Tasks.insert(user.id, project.id, %{
        title: "Root",
        workspace: %{daemon_id: root_daemon.id, worktree_path: "/tmp/root"}
      })

    %{
      user: user,
      project: project,
      root_task: root_task,
      root_daemon: root_daemon,
      other_daemon: other_daemon
    }
  end

  test "assigns an unassigned child to the root daemon before admission", ctx do
    {:ok, child} =
      Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{
        title: "Child",
        parent_id: ctx.root_task.id,
        workspace: %{worktree_path: "/tmp/child"}
      })

    {:ok, root_run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.root_task.id, %{
        status: :executing
      })

    {:ok, child_run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, child.id, %{
        status: :queued,
        parent_task_run_id: root_run.id,
        root_task_run_id: root_run.id
      })

    assert {:ok, %Task{} = placed_child, options} =
             TaskRunPlacement.resolve_admission_options(child, child_run)

    assert options[:daemon_id] == ctx.root_daemon.id
    assert placed_child.workspace.daemon_id == ctx.root_daemon.id
    assert placed_child.workspace.worktree_path == "/tmp/child"
    assert Repo.get!(Task, child.id).workspace.daemon_id == ctx.root_daemon.id
  end

  test "rejects a pre-existing child assignment to another daemon", ctx do
    {:ok, child} =
      Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{
        title: "Conflicting Child",
        parent_id: ctx.root_task.id,
        workspace: %{daemon_id: ctx.other_daemon.id, worktree_path: "/tmp/other"}
      })

    {:ok, root_run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, ctx.root_task.id, %{
        status: :executing
      })

    {:ok, child_run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, child.id, %{
        status: :queued,
        parent_task_run_id: root_run.id,
        root_task_run_id: root_run.id
      })

    assert {:error, {:child_daemon_conflict, other_daemon, root_daemon}} =
             TaskRunPlacement.resolve_admission_options(child, child_run)

    assert other_daemon == ctx.other_daemon.id
    assert root_daemon == ctx.root_daemon.id
    assert Repo.get!(Task, child.id).workspace.daemon_id == ctx.other_daemon.id

    execution = %StepExecution{
      task_run_id: child_run.id,
      task_id: child.id,
      user_id: ctx.user.id,
      project_id: ctx.project.id
    }

    # Cancellation follows the owning tree even when a child's assignment conflicts.
    query_ref = make_ref()
    owner = self()

    :ok =
      :telemetry.attach(
        query_ref,
        [:sacrum, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner, do: send(owner, {:query, query_ref, metadata.query})
        end,
        nil
      )

    try do
      assert TaskRunPlacement.daemon_id_for_execution(execution) == ctx.root_daemon.id
      assert_received {:query, ^query_ref, query}
      assert query =~ "SELECT"
      refute_received {:query, ^query_ref, _}
    after
      :telemetry.detach(query_ref)
    end

    assert {:error, :workspace_required} =
             TaskRunPlacement.daemon_id_for_execution(%{
               execution
               | user_id: Ecto.UUID.generate()
             })
  end

  test "refreshes first-time root assignment without using the stale task", ctx do
    :ok = connect_daemon(ctx.root_daemon.id, ctx.user.id)
    {:ok, stale_task} = Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{title: "Unassigned"})
    {:ok, task_run} = Sacrum.Orchestrator.TaskRuns.Root.get_or_create(stale_task)
    assert Task.workspace_daemon(stale_task) == nil
    assert {:ok, task, options} = TaskRunPlacement.resolve_admission_options(stale_task, task_run)
    assert Task.workspace_daemon(task) == ctx.root_daemon.id
    assert options[:daemon_id] == ctx.root_daemon.id
  end

  test "returns a placement error when a root task has no daemon", ctx do
    {:ok, task} = Accounts.Tasks.insert(ctx.user.id, ctx.project.id, %{title: "Unassigned"})

    {:ok, run} =
      Accounts.TaskRuns.insert(ctx.user.id, ctx.project.id, task.id, %{status: :queued})

    assert {:error, :workspace_required} = TaskRunPlacement.resolve_admission_options(task, run)
  end
end
