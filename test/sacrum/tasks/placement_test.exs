defmodule Sacrum.Tasks.PlacementTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Accounts
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Tasks.Placement

  setup do
    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "placement-update-#{System.unique_integer([:positive])}@example.com",
        username: "placement_update_#{System.unique_integer([:positive])}",
        password: "password123"
      })

    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Placement Update Project"})
    {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Placement Task"})
    task = Sacrum.TestWorkspace.assign_workspace(task, user.id, "/tmp/original-worktree")

    {:ok, _task_run} =
      Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :executing})

    %{user: user, project: project, task: task}
  end

  test "allows an active task run to change only the worktree path", ctx do
    daemon_id = Task.workspace_daemon(ctx.task)

    assert {:ok, updated} =
             Accounts.Tasks.update(ctx.task, %{
               workspace: %{daemon_id: daemon_id, worktree_path: "/tmp/updated-worktree"}
             })

    assert Task.workspace_daemon(updated) == daemon_id
    assert Task.workspace_worktree(updated) == "/tmp/updated-worktree"

    persisted = Repo.get!(Task, ctx.task.id)
    assert Task.workspace_daemon(persisted) == daemon_id
    assert Task.workspace_worktree(persisted) == "/tmp/updated-worktree"
  end

  test "rejects daemon reassignment during an active task run and rolls back the update", ctx do
    {:ok, other_daemon, other_bootstrap} = Sacrum.Repo.Daemons.create(ctx.user.id)

    {:ok, _daemon, _reconnect, _credential} =
      Accounts.Daemons.exchange_bootstrap(other_daemon.id, other_bootstrap)

    assert {:error, :workspace_locked} =
             Accounts.Tasks.update(ctx.task, %{
               title: "Should roll back",
               workspace: %{daemon_id: other_daemon.id, worktree_path: "/tmp/other-worktree"}
             })

    persisted = Repo.get!(Task, ctx.task.id)
    assert persisted.title == "Placement Task"
    assert Task.workspace_daemon(persisted) == Task.workspace_daemon(ctx.task)
    assert Task.workspace_worktree(persisted) == "/tmp/original-worktree"
  end

  test "rejects clearing the daemon during an active task run", ctx do
    assert {:error, :workspace_locked} =
             Accounts.Tasks.update(ctx.task, %{
               workspace: %{daemon_id: nil, worktree_path: "/tmp/cleared-daemon"}
             })

    persisted = Repo.get!(Task, ctx.task.id)
    assert Task.workspace_daemon(persisted) == Task.workspace_daemon(ctx.task)
    assert Task.workspace_worktree(persisted) == "/tmp/original-worktree"
  end

  test "still validates daemon enrollment for an active worktree update", ctx do
    daemon = Repo.get!(Sacrum.Repo.Schemas.Daemon, Task.workspace_daemon(ctx.task))
    {:ok, _pending_daemon} = Repo.update(Ecto.Changeset.change(daemon, status: "pending"))

    assert {:error, :daemon_not_enrolled} =
             Accounts.Tasks.update(ctx.task, %{
               workspace: %{daemon_id: daemon.id, worktree_path: "/tmp/rejected-worktree"}
             })

    persisted = Repo.get!(Task, ctx.task.id)
    assert Task.workspace_daemon(persisted) == daemon.id
    assert Task.workspace_worktree(persisted) == "/tmp/original-worktree"
  end

  test "keeps workspace ownership validation scoped to the task owner", ctx do
    {:ok, other_user} =
      Sacrum.Repo.Users.insert(%{
        email: "other-placement-#{System.unique_integer([:positive])}@example.com",
        username: "other_placement_#{System.unique_integer([:positive])}",
        password: "password123"
      })

    {:ok, other_daemon, other_bootstrap} = Sacrum.Repo.Daemons.create(other_user.id)

    {:ok, _daemon, _reconnect, _credential} =
      Accounts.Daemons.exchange_bootstrap(other_daemon.id, other_bootstrap)

    assert {:error, :daemon_not_found} =
             Placement.validate_workspace_owner(ctx.user.id, %{daemon_id: other_daemon.id})
  end
end
