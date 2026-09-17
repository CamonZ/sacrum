defmodule SacrumWeb.AccountChannel do
  @moduledoc """
  Account-scoped realtime channel for authenticated account clients.

  Clients join the public `accounts:me` topic. The channel derives the
  account from the authenticated user socket and subscribes internally to
  that user's `account:<user_id>` topic, which is reserved for server-side
  broadcasts.
  """

  use Phoenix.Channel

  alias Phoenix.Socket.Broadcast
  alias Sacrum.Realtime.AccountChannelCdcContract
  alias Sacrum.Repo.Schemas.Daemon

  @events AccountChannelCdcContract.event_names()
  @metrics_event AccountChannelCdcContract.metrics_event_name()
  @schema_version 1
  @public_topic "accounts:me"

  intercept([@metrics_event | @events])

  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t()} | {:error, map()}
  @impl true
  def join(
        @public_topic,
        _params,
        %{assigns: %{current_user: %{id: user_id}}} = socket
      ) do
    account_topic = AccountChannelCdcContract.topic(user_id)
    :ok = SacrumWeb.Endpoint.subscribe(account_topic)

    {:ok,
     socket
     |> assign(:account_id, user_id)
     |> assign(:account_topic, account_topic)}
  end

  def join(_, _, _), do: {:error, %{reason: "forbidden"}}

  @spec event_names() :: [String.t()]
  def event_names, do: @events

  @spec broadcast_daemon_created(String.t(), Daemon.t() | map()) :: :ok | {:error, term()}
  def broadcast_daemon_created(account_id, daemon) when is_map(daemon) do
    broadcast_daemon(account_id, "daemon_created", daemon)
  end

  @spec broadcast_daemon_updated(String.t(), Daemon.t() | map()) :: :ok | {:error, term()}
  def broadcast_daemon_updated(account_id, daemon) when is_map(daemon) do
    broadcast_daemon(account_id, "daemon_updated", daemon)
  end

  @spec broadcast_daemon_deleted(String.t(), Daemon.t() | map()) :: :ok | {:error, term()}
  def broadcast_daemon_deleted(account_id, daemon) when is_map(daemon) do
    broadcast_daemon(account_id, "daemon_deleted", daemon)
  end

  @spec broadcast_daemon_metrics(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_daemon_metrics(account_id, metrics) when is_map(metrics) do
    SacrumWeb.Endpoint.broadcast(
      AccountChannelCdcContract.topic(account_id),
      @metrics_event,
      metrics_payload(metrics)
    )
  end

  @spec metrics_event_name() :: String.t()
  def metrics_event_name, do: @metrics_event

  @impl true
  def handle_out(event, payload, socket) when event in @events do
    push(socket, event, daemon_payload(payload))
    {:noreply, socket}
  end

  @impl true
  def handle_out(@metrics_event, payload, socket) do
    push(socket, @metrics_event, metrics_payload(payload))
    {:noreply, socket}
  end

  @impl true
  def handle_info(
        %Broadcast{topic: topic, event: event, payload: payload},
        %{assigns: %{account_topic: topic}} = socket
      )
      when event in @events do
    handle_out(event, payload, socket)
  end

  def handle_info(
        %Broadcast{topic: topic, event: @metrics_event, payload: payload},
        %{assigns: %{account_topic: topic}} = socket
      ) do
    handle_out(@metrics_event, payload, socket)
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp broadcast_daemon(account_id, event, daemon) do
    SacrumWeb.Endpoint.broadcast(
      AccountChannelCdcContract.topic(account_id),
      event,
      daemon_payload(daemon)
    )
  end

  defp daemon_payload(daemon) do
    id = Map.fetch!(daemon, :id)
    name = Map.get(daemon, :name)

    %{
      schema_version: @schema_version,
      id: id,
      status: Map.get(daemon, :status),
      name: name,
      display_name: Daemon.display_name(%Daemon{id: id, name: name}),
      max_concurrency: Map.get(daemon, :max_concurrency),
      enrolled_at: Map.get(daemon, :enrolled_at),
      inserted_at: Map.get(daemon, :inserted_at),
      updated_at: Map.get(daemon, :updated_at)
    }
  end

  defp metrics_payload(metrics) do
    %{
      schema_version: @schema_version,
      id: Map.fetch!(metrics, :id),
      report_version: Map.get(metrics, :report_version),
      daemon_version: Map.get(metrics, :daemon_version),
      os: Map.get(metrics, :os),
      architecture: Map.get(metrics, :architecture),
      host: Map.get(metrics, :host),
      started_at: Map.get(metrics, :started_at),
      last_seen_at: Map.get(metrics, :last_seen_at),
      capabilities: Map.get(metrics, :capabilities),
      connection_status: Map.get(metrics, :connection_status),
      health: Map.get(metrics, :health),
      health_reason: Map.get(metrics, :health_reason)
    }
  end
end
