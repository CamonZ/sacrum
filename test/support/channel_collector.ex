defmodule Sacrum.ChannelCollector do
  @moduledoc "A separate client transport inbox for attributed channel assertions."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [])
  def take(pid), do: GenServer.call(pid, :take)

  @impl true
  def init(_opts), do: {:ok, []}

  @impl true
  def handle_info(%Phoenix.Socket.Message{} = message, messages),
    do: {:noreply, [message | messages]}

  def handle_info(_message, messages), do: {:noreply, messages}

  @impl true
  def handle_call(:take, _from, messages), do: {:reply, Enum.reverse(messages), []}
end
