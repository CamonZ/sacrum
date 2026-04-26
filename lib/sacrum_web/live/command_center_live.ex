defmodule SacrumWeb.CommandCenterLive do
  use SacrumWeb, :live_view

  alias Sacrum.Repo.Projects

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    has_projects = Projects.all(conditions: [user_id: user.id]) != []

    {:ok,
     assign(socket,
       page_title: "Command Center",
       has_projects: has_projects,
       chat_expanded: false
     )}
  end

  @impl true
  def handle_event("toggle-chat", _params, socket) do
    {:noreply, update(socket, :chat_expanded, &(!&1))}
  end
end
