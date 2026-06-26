defmodule SacrumWeb.Live.Hooks.AssignCurrentUser do
  import Phoenix.Component, only: [assign: 3]

  alias Sacrum.Repo

  @type result :: {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) :: result()
  def on_mount(:default, _params, %{"user_id" => user_id}, socket) when is_binary(user_id) do
    case Repo.Users.get(user_id) do
      {:ok, user} -> {:cont, assign(socket, :current_user, user)}
      {:error, _} -> {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, assign(socket, :current_user, nil)}
  end
end
