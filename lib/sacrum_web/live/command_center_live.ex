defmodule SacrumWeb.CommandCenterLive do
  use SacrumWeb, :live_view

  alias Sacrum.Repo.Attention
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Pulse

  @pulse_events ~w(step_execution_created step_execution_status_changed task_created task_updated)
  @attention_events ~w(step_execution_status_changed step_execution_created task_created)

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
        has_projects: projects != []
      )
      |> assign_pulse_metrics(Pulse.get_all_metrics())
      |> load_attention_rows()

    {:ok, socket}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: event}, socket)
      when event in @pulse_events do
    {:noreply, assign_pulse_metrics(socket, Pulse.get_all_metrics())}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: event}, socket)
      when event in @attention_events do
    {:noreply, load_attention_rows(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{}, socket), do: {:noreply, socket}

  @spec cause_label(Sacrum.Repo.Attention.cause()) :: String.t()
  def cause_label(:failed), do: "FAILED"
  def cause_label(:dead), do: "DEAD"
  def cause_label(:gate), do: "GATE"
  def cause_label(:context_pressure), do: "CTX"

  @spec cause_badge_class(Sacrum.Repo.Attention.cause()) :: String.t()
  def cause_badge_class(:failed), do: "bg-error text-accent-fg"
  def cause_badge_class(:dead), do: "bg-warning text-accent-fg"
  def cause_badge_class(:gate), do: "bg-accent text-accent-fg"
  def cause_badge_class(:context_pressure), do: "bg-border text-text-muted"

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

  defp load_attention_rows(socket) do
    rows = Attention.get_rows()

    socket
    |> assign(attention_empty: rows == [])
    |> stream(:attention_rows, rows, reset: true)
  end
end
