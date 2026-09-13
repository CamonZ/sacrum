defmodule SacrumWeb.AccountChannel do
  @moduledoc "Account-scoped realtime channel for authenticated daemon fleet clients."

  use Phoenix.Channel

  alias Sacrum.Realtime.AccountChannelCdcContract
  alias Sacrum.Repo.Schemas.Daemon

  @events AccountChannelCdcContract.event_names()
  @schema_version 1

  intercept(@events)

  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t()} | {:error, map()}
  @impl true
  def join(
        "account:" <> account_id,
        _params,
        %{assigns: %{current_user: %{id: account_id}}} = socket
      ) do
    {:ok, assign(socket, :account_id, account_id)}
  end

  def join("account:" <> _account_id, _params, _socket),
    do: {:error, %{reason: "forbidden"}}

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

  @impl true
  def handle_out(event, payload, socket) when event in @events do
    push(socket, event, daemon_payload(payload))
    {:noreply, socket}
  end

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
      enrolled_at: Map.get(daemon, :enrolled_at),
      inserted_at: Map.get(daemon, :inserted_at),
      updated_at: Map.get(daemon, :updated_at)
    }
  end
end
