defmodule SacrumWeb.DashboardLive do
  use SacrumWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Dashboard")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app_shell
      flash={@flash}
      current_user={@current_user}
      active={:dashboard}
    >
      <div id="dashboard" class="min-h-full" aria-label="Dashboard"></div>
    </Layouts.app_shell>
    """
  end
end
