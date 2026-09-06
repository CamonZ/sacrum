defmodule SacrumWeb.DaemonChannel do
  use Phoenix.Channel

  alias Sacrum.Repo.Daemons

  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t()} | {:error, map()}
  @impl true
  def join(
        "daemon:" <> daemon_id,
        _params,
        %{assigns: %{principal: %{type: :daemon} = principal}} = socket
      ) do
    with true <- daemon_id == principal.daemon_id,
         {:ok, daemon, _credential} <-
           Daemons.revalidate_reconnect(daemon_id, principal.credential_id) do
      register(socket, daemon)
    else
      false -> {:error, %{reason: "identity_mismatch"}}
      {:error, _} -> {:error, %{reason: "invalid_credentials"}}
    end
  end

  def join(
        "daemon:" <> daemon_id,
        %{"enrollment_token" => token},
        %{assigns: %{current_user: user}} = socket
      ) do
    with {:ok, daemon} <- Daemons.verify_token(daemon_id, token),
         true <- daemon.user_id == user.id do
      register(socket, daemon)
    else
      false -> {:error, %{reason: "identity_mismatch"}}
      {:error, _} -> {:error, %{reason: "invalid_credentials"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "invalid_registration"}}

  @spec terminate(term(), Phoenix.Socket.t()) :: :ok
  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:daemon_registered],
      do: Sacrum.DaemonConnectionRegistry.unregister(socket.assigns.daemon_id)

    :ok
  end

  defp register(socket, daemon) do
    case Sacrum.DaemonConnectionRegistry.register(daemon.id, daemon.user_id) do
      :ok ->
        {:ok,
         assign(socket,
           daemon: daemon,
           daemon_id: daemon.id,
           user_id: daemon.user_id,
           daemon_registered: true
         )}

      {:error, :already_connected} ->
        {:error, %{reason: "already_connected"}}
    end
  end
end
