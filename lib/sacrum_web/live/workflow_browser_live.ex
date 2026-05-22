defmodule SacrumWeb.WorkflowBrowserLive do
  use SacrumWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Workflow Browser")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app_shell
      flash={@flash}
      current_user={@current_user}
      active={:workflow_browser}
    >
      <div class="p-6 text-text-muted text-sm">Workflow Browser coming soon.</div>
    </Layouts.app_shell>
    """
  end
end
