defmodule SacrumWeb.DaemonChannel do
  @moduledoc """
  Standalone daemon registration channel.

  Join order closes the revalidation-to-registration race:

  1. authorize against durable credential state,
  2. claim the Registry registration (process-owned),
  3. re-revalidate after registration.

  A lifecycle mutation (revoke/rotation) committing at any point is therefore
  caught: before (1) rejects, between (1) and (2) is caught by (3) which
  releases the fresh registration, and after (2) is delivered through
  `Sacrum.DaemonConnectionRegistry.invalidate_sessions/1` or the bounded
  periodic recheck. Reconnects and restarts always re-derive authorization
  from the database.
  """

  use Phoenix.Channel

  alias Sacrum.Repo.Daemons

  @revalidate_interval :daemon_session_revalidate_interval_ms

  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t()} | {:error, map()}
  @impl true
  def join(
        "daemon:" <> daemon_id,
        _params,
        %{assigns: %{principal: %{type: :daemon} = principal}} = socket
      ) do
    with true <- daemon_id == principal.daemon_id,
         {:ok, daemon, credential} <-
           Daemons.revalidate_reconnect(daemon_id, principal.credential_id) do
      register(socket, daemon, credential.id)
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
    with {:ok, daemon, credential} <- Daemons.authenticate_reconnect(daemon_id, token),
         true <- daemon.user_id == user.id do
      register(socket, daemon, credential.id)
    else
      false -> {:error, %{reason: "identity_mismatch"}}
      {:error, _} -> {:error, %{reason: "invalid_credentials"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "invalid_registration"}}

  @doc "Standalone registration grants no execution/reporting authority."
  @spec handle_in(String.t(), term(), Phoenix.Socket.t()) ::
          {:reply, {:error, map()}, Phoenix.Socket.t()}
          | {:stop, :shutdown, Phoenix.Socket.t()}
  @impl true
  def handle_in(_event, _payload, socket) do
    case revalidate(socket) do
      :ok -> {:reply, {:error, %{reason: "unsupported_operation"}}, socket}
      :invalid -> {:stop, :shutdown, socket}
    end
  end

  @impl true
  def handle_info(:daemon_credentials_invalidated, socket) do
    case revalidate(socket) do
      :ok -> {:noreply, socket}
      :invalid -> {:stop, :shutdown, socket}
    end
  end

  def handle_info(:revalidate_daemon_session, socket) do
    case revalidate(socket) do
      :ok -> {:noreply, schedule_revalidation(socket)}
      :invalid -> {:stop, :shutdown, socket}
    end
  end

  @spec terminate(term(), Phoenix.Socket.t()) :: :ok
  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:daemon_registered],
      do: Sacrum.DaemonConnectionRegistry.unregister(socket.assigns.daemon_id)

    :ok
  end

  defp register(socket, daemon, credential_id) do
    case Sacrum.DaemonConnectionRegistry.register(daemon.id, %{
           user_id: daemon.user_id,
           credential_id: credential_id
         }) do
      :ok ->
        socket =
          assign(socket,
            daemon: daemon,
            daemon_id: daemon.id,
            user_id: daemon.user_id,
            credential_id: credential_id,
            daemon_registered: true
          )

        case revalidate(socket) do
          :ok ->
            {:ok, schedule_revalidation(socket)}

          :invalid ->
            Sacrum.DaemonConnectionRegistry.unregister(daemon.id)
            {:error, %{reason: "invalid_credentials"}}
        end

      {:error, :already_connected} ->
        {:error, %{reason: "already_connected"}}
    end
  end

  defp revalidate(%{assigns: %{daemon_id: daemon_id, credential_id: credential_id}}) do
    case Daemons.revalidate_reconnect(daemon_id, credential_id) do
      {:ok, _daemon, _credential} -> :ok
      {:error, _} -> :invalid
    end
  end

  defp revalidate(_socket), do: :invalid

  defp schedule_revalidation(socket) do
    case Application.get_env(:sacrum, @revalidate_interval, 30_000) do
      :infinity ->
        socket

      interval when is_integer(interval) and interval > 0 ->
        Process.send_after(self(), :revalidate_daemon_session, interval)
        socket

      _ ->
        socket
    end
  end
end
