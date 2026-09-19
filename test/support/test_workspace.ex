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

    :ok = connect_daemon(Task.workspace_daemon(task), user_id)
    task
  end

  def connect_daemon(daemon_id, user_id) do
    case Sacrum.DaemonConnectionRegistry.lookup(daemon_id) do
      [] ->
        Sacrum.DaemonConnectionRegistry.register(daemon_id, %{
          user_id: user_id,
          credential_id: Ecto.UUID.generate(),
          metrics: nil
        })

      [{pid, %{user_id: ^user_id}}] when pid == self() ->
        :ok
    end
  end
end
