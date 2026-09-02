defmodule Sacrum.DaemonConnectionRegistry do
  @moduledoc "Tracks active daemon channel registrations by stable daemon ID."

  @spec register(String.t(), String.t()) :: :ok | {:error, :already_connected}
  def register(daemon_id, user_id) do
    case Registry.register(__MODULE__, daemon_id, user_id) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, :already_connected}
    end
  end

  @spec unregister(String.t()) :: :ok
  def unregister(daemon_id), do: Registry.unregister(__MODULE__, daemon_id)

  @spec lookup(String.t()) :: [{pid(), String.t()}]
  def lookup(daemon_id), do: Registry.lookup(__MODULE__, daemon_id)
end
