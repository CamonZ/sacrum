defmodule SacrumWeb.DaemonChannel do
  use Phoenix.Channel

  alias Sacrum.Repo.Daemons

  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t()} | {:error, map()}
  @impl true
  def join("daemon:" <> daemon_id, %{"enrollment_token" => token}, socket) do
    user = socket.assigns.current_user

    with {:ok, daemon} <- Daemons.verify_token(daemon_id, token),
         true <- daemon.user_id == user.id,
         :ok <- Sacrum.DaemonConnectionRegistry.register(daemon.id, user.id) do
      {:ok, assign(socket, daemon: daemon, daemon_id: daemon.id, user_id: user.id)}
    else
      false -> {:error, %{reason: "identity_mismatch"}}
      {:error, :already_connected} -> {:error, %{reason: "already_connected"}}
      {:error, _} -> {:error, %{reason: "invalid_credentials"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "invalid_registration"}}

  @spec terminate(term(), Phoenix.Socket.t()) :: :ok
  @impl true
  def terminate(_reason, socket) do
    if daemon_id = socket.assigns[:daemon_id],
      do: Sacrum.DaemonConnectionRegistry.unregister(daemon_id)

    :ok
  end
end
