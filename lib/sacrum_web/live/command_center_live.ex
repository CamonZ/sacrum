defmodule SacrumWeb.CommandCenterLive do
  use SacrumWeb, :live_view

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Pulse

  @pulse_events ~w(step_execution_created step_execution_status_changed task_created task_updated)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    projects = Projects.all(conditions: [user_id: user.id])

    Enum.each(projects, fn project ->
      Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")
    end)

    socket =
      socket
      |> assign(
        page_title: "Command Center",
        has_projects: projects != [],
        chat_expanded: false
      )
      |> assign_pulse_metrics(Pulse.get_all_metrics())

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle-chat", _params, socket) do
    {:noreply, update(socket, :chat_expanded, &(!&1))}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: event}, socket)
      when event in @pulse_events do
    {:noreply, assign_pulse_metrics(socket, Pulse.get_all_metrics())}
  end

  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  defp assign_pulse_metrics(socket, metrics) do
    assign(socket,
      concurrency: metrics.concurrency,
      cap: metrics.cap,
      spend_usd: metrics.spend_usd,
      spend_tokens: metrics.spend_tokens,
      throughput: metrics.throughput,
      p50_duration_ms: metrics.p50_duration_ms
    )
  end
end
