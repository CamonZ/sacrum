defmodule Sacrum.TestWorkspace do
  alias Sacrum.Accounts
  alias Sacrum.Repo.Schemas.Task

  @doc "Assigns an enrolled daemon workspace to a task used by an execution test."
  def assign_workspace(%Task{} = task, user_id, path \\ nil) do
    {:ok, daemon, bootstrap} = Sacrum.Repo.Daemons.create(user_id)

    {:ok, _daemon, _reconnect, _credential} =
      Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

    path = path || "/tmp/test-workspace-#{task.id}"

    {:ok, task} =
      Accounts.Tasks.update(task, %{workspace: %{daemon_id: daemon.id, worktree_path: path}})

    task
  end
end
