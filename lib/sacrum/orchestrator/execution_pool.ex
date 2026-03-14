defmodule Sacrum.Orchestrator.ExecutionPool do
  @moduledoc """
  Manages concurrent execution slots with queuing.

  Maintains a fixed number of slots. When all are in use, requests are queued (FIFO).
  Monitored processes auto-release their slot on exit.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Request a slot. Blocks until one is available or timeout expires.
  The given `pid` is monitored; its slot is auto-released if it dies.
  """
  @spec request_slot(pid(), timeout()) :: {:ok, integer()} | {:error, atom()}
  def request_slot(pid, timeout \\ :infinity) do
    GenServer.call(__MODULE__, {:request_slot, pid}, timeout)
  end

  @spec release_slot(integer()) :: :ok
  def release_slot(slot_id) do
    GenServer.call(__MODULE__, {:release_slot, slot_id})
  end

  @spec pool_status() :: map()
  def pool_status do
    GenServer.call(__MODULE__, :pool_status)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    max_concurrent = Application.get_env(:sacrum, :max_concurrent_executions, 5)

    state = %{
      max_concurrent: max_concurrent,
      next_slot_id: 1,
      in_use: %{},
      monitors: %{},
      queue: :queue.new()
    }

    Logger.info("[ExecutionPool] Initialized with max_concurrent=#{max_concurrent}")
    {:ok, state}
  end

  @impl true
  def handle_call({:request_slot, pid}, from, state) do
    if available_slots(state) > 0 do
      {slot_id, new_state} = grant_slot(state, pid)
      {:reply, {:ok, slot_id}, new_state}
    else
      new_state = %{state | queue: :queue.in({pid, from}, state.queue)}
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:release_slot, slot_id}, _from, state) do
    case Map.fetch(state.in_use, slot_id) do
      {:ok, {_pid, monitor_ref}} ->
        Process.demonitor(monitor_ref, [:flush])
        new_state = remove_slot_and_serve_queue(state, slot_id)
        {:reply, :ok, new_state}

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:pool_status, _from, state) do
    status = %{
      available_slots: available_slots(state),
      in_use_count: map_size(state.in_use),
      queue_length: :queue.len(state.queue)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, slot_id} ->
        new_state = remove_slot_and_serve_queue(state, slot_id)
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  # Private helpers

  defp available_slots(state), do: state.max_concurrent - map_size(state.in_use)

  defp grant_slot(state, pid) do
    slot_id = state.next_slot_id
    monitor_ref = Process.monitor(pid)

    new_state = %{
      state
      | next_slot_id: state.next_slot_id + 1,
        in_use: Map.put(state.in_use, slot_id, {pid, monitor_ref}),
        monitors: Map.put(state.monitors, monitor_ref, slot_id)
    }

    {slot_id, new_state}
  end

  defp remove_slot_and_serve_queue(state, slot_id) do
    {_entry, monitors} =
      case Map.fetch(state.in_use, slot_id) do
        {:ok, {_pid, ref}} -> {{slot_id, ref}, Map.delete(state.monitors, ref)}
        :error -> {nil, state.monitors}
      end

    new_in_use = Map.delete(state.in_use, slot_id)
    state = %{state | in_use: new_in_use, monitors: monitors}

    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {queued_pid, queued_from}}, rest} ->
        {new_slot_id, new_state} = grant_slot(%{state | queue: rest}, queued_pid)
        GenServer.reply(queued_from, {:ok, new_slot_id})
        new_state
    end
  end
end
