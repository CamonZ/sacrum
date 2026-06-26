defmodule SacrumWeb.SignInLive do
  use SacrumWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_user] do
      {:ok, push_navigate(socket, to: "/")}
    else
      {:ok, socket}
    end
  end
end
