defmodule Sacrum.DaemonConnectionRegistry do
  @moduledoc """
  Tracks active daemon channel registrations by stable daemon ID.

  Each registration value is `%{user_id: ..., credential_id: ...}`: the
  credential identity that authorized the session. Registrations are owned
  exclusively by their channel process; only that process can unregister
  (`Registry.unregister/2` is process-local), so a delayed or duplicated
  invalidation can never release a newer session's registration.

  Session invalidation after a committed lifecycle mutation is best-effort
  local delivery: every currently registered channel for the daemon receives
  `:daemon_credentials_invalidated` and re-derives its own authorization from
  durable database state. Messages that arrive late (or target dead pids) are
  harmless — a newer session revalidates successfully and ignores them. Lost
  deliveries are additionally bounded by revalidation at join, on every
  inbound event and by the periodic session recheck in `SacrumWeb.DaemonChannel`.
  """

  @invalidation_message :daemon_credentials_invalidated

  @type session :: %{user_id: String.t(), credential_id: String.t()}

  @spec register(String.t(), session()) :: :ok | {:error, :already_connected}
  def register(daemon_id, session) do
    case Registry.register(__MODULE__, daemon_id, session) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :already_connected}
    end
  end

  @doc "Releases only the calling process registration; other sessions cannot unregister its owner."
  @spec unregister(String.t()) :: :ok
  def unregister(daemon_id), do: Registry.unregister(__MODULE__, daemon_id)

  @spec lookup(String.t()) :: [{pid(), session()}]
  def lookup(daemon_id), do: Registry.lookup(__MODULE__, daemon_id)

  @doc """
  Asks every registered session of this daemon to re-derive authorization
  from the database. Called only after a lifecycle mutation has committed, so
  a failed mutation never disconnects anything. Sends to dead pids are
  no-ops (the session is already gone).
  """
  @spec invalidate_sessions(String.t()) :: :ok
  def invalidate_sessions(daemon_id) do
    daemon_id
    |> lookup()
    |> Enum.each(fn {pid, _session} -> send(pid, @invalidation_message) end)

    :ok
  end
end
