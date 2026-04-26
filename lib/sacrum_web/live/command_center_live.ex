defmodule SacrumWeb.CommandCenterLive do
  use SacrumWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # TODO: de40149c - Onboarding flow - distinguish first-run users
    # For now, default everyone to the Command Center
    {:ok, assign(socket, page_title: "Command Center")}
  end
end
