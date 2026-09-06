defmodule SacrumWeb.UserSocket do
  use Phoenix.Socket

  alias Sacrum.Auth
  alias Sacrum.Repo.Daemons

  channel "project:*", SacrumWeb.ProjectChannel
  channel "daemon:*", SacrumWeb.DaemonChannel

  @impl true
  def connect(
        %{"daemon_id" => daemon_id, "reconnect_token" => token} = params,
        socket,
        _connect_info
      )
      when not is_map_key(params, "token") do
    case Daemons.authenticate_reconnect(daemon_id, token) do
      {:ok, daemon, credential} ->
        principal = %{
          type: :daemon,
          daemon_id: daemon.id,
          user_id: daemon.user_id,
          credential_id: credential.id
        }

        {:ok, assign(socket, :principal, principal)}

      {:error, _} ->
        :error
    end
  end

  def connect(%{"token" => token} = params, socket, _connect_info)
      when not is_map_key(params, "daemon_id") and not is_map_key(params, "reconnect_token") do
    case Auth.verify_token(token) do
      {:ok, user} ->
        {:ok, assign(socket, :current_user, user)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(%{assigns: %{principal: %{type: :daemon} = principal}}),
    do: "daemon_socket:#{principal.daemon_id}:#{principal.credential_id}"

  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
