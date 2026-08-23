defmodule Sacrum.Orchestrator.ExecutionPool do
  @moduledoc """
  Manages concurrent execution slots with queuing.

  Maintains a fixed number of slots. When all are in use, requests are queued (FIFO).
  Monitored processes auto-release their slot on exit.

  Accepts an optional `:name` option on `start_link/1`. When omitted, registers
  as `__MODULE__` (the global default). Pass a custom name in tests to get an
  isolated pool instance.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Request a slot. Blocks until one is available or timeout expires.
  The given `pid` is monitored; its slot is auto-released if it dies.
  """
  @spec request_slot(pid(), timeout()) :: {:ok, integer()} | {:error, atom()}
  def request_slot(pid, timeout \\ :infinity)

  def request_slot(pid, timeout) when is_pid(pid) do
    request_slot(__MODULE__, pid, timeout, [])
  end

  @spec request_slot(pid(), timeout(), keyword()) :: {:ok, integer()} | {:error, atom()}
  def request_slot(pid, timeout, opts) when is_pid(pid) and is_list(opts) do
    request_slot(__MODULE__, pid, timeout, opts)
  end

  @spec request_slot(GenServer.server(), pid(), timeout()) :: {:ok, integer()} | {:error, atom()}
  def request_slot(server, pid, timeout) do
    request_slot(server, pid, timeout, [])
  end

  @spec request_slot(GenServer.server(), pid(), timeout(), keyword()) ::
          {:ok, integer()} | {:error, atom()}
  def request_slot(server, pid, timeout, opts) when is_list(opts) do
    GenServer.call(server, {:request_slot, pid, normalize_scope(opts)}, timeout)
  end

  @spec release_slot(integer()) :: :ok
  def release_slot(slot_id) do
    release_slot(__MODULE__, slot_id)
  end

  @spec release_slot(GenServer.server(), integer()) :: :ok
  def release_slot(server, slot_id) do
    GenServer.call(server, {:release_slot, slot_id})
  end

  @spec pool_status() :: map()
  def pool_status do
    pool_status(__MODULE__)
  end

  @spec pool_status(GenServer.server()) :: map()
  def pool_status(server) do
    GenServer.call(server, :pool_status)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    max_concurrent =
      Keyword.get(
        opts,
        :max_concurrent,
        Application.get_env(:sacrum, :max_concurrent_executions, 5)
      )

    state = %{
      max_concurrent: max_concurrent,
      next_slot_id: 1,
      in_use: %{},
      in_use_by_scope: %{},
      monitors: %{},
      queue: :queue.new()
    }

    Logger.info("[ExecutionPool] Initialized with max_concurrent=#{max_concurrent}")
    {:ok, state}
  end

  @impl true
  def handle_call({:request_slot, pid, scope}, from, state) do
    if slot_available?(state, scope) do
      {slot_id, new_state} = grant_slot(state, %{pid: pid, scope: scope})

      Logger.info(
        "[ExecutionPool] Granted slot #{slot_id} to #{inspect(pid)} scope=#{inspect(scope)} (#{available_slots(new_state)} remaining)"
      )

      {:reply, {:ok, slot_id}, new_state}
    else
      Logger.info(
        "[ExecutionPool] No slots available, queuing #{inspect(pid)} scope=#{inspect(scope)} (queue_len=#{:queue.len(state.queue) + 1})"
      )

      new_state = %{state | queue: :queue.in(%{pid: pid, from: from, scope: scope}, state.queue)}
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:release_slot, slot_id}, _from, state) do
    case Map.fetch(state.in_use, slot_id) do
      {:ok, _entry} ->
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
      in_use_by_scope: state.in_use_by_scope,
      max_concurrent: state.max_concurrent,
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

  defp slot_available?(state, scope) do
    available_slots(state) > 0 and scope_available?(state, scope)
  end

  defp scope_available?(_state, nil), do: true

  defp scope_available?(state, %{id: id, limit: limit}) do
    Map.get(state.in_use_by_scope, id, 0) < limit
  end

  defp grant_slot(state, %{pid: pid, scope: scope}) do
    slot_id = state.next_slot_id
    monitor_ref = Process.monitor(pid)

    new_state = %{
      state
      | next_slot_id: state.next_slot_id + 1,
        in_use:
          Map.put(state.in_use, slot_id, %{pid: pid, monitor_ref: monitor_ref, scope: scope}),
        in_use_by_scope: increment_scope(state.in_use_by_scope, scope),
        monitors: Map.put(state.monitors, monitor_ref, slot_id)
    }

    {slot_id, new_state}
  end

  defp remove_slot_and_serve_queue(state, slot_id) do
    case Map.pop(state.in_use, slot_id) do
      {nil, _in_use} ->
        state

      {%{monitor_ref: monitor_ref, scope: scope}, in_use} ->
        Process.demonitor(monitor_ref, [:flush])

        state
        |> Map.put(:in_use, in_use)
        |> Map.put(:monitors, Map.delete(state.monitors, monitor_ref))
        |> Map.put(:in_use_by_scope, decrement_scope(state.in_use_by_scope, scope))
        |> serve_queue()
    end
  end

  defp serve_queue(state) do
    case take_eligible_request(state) do
      {:none, state} ->
        state

      {%{from: from} = request, state} ->
        {slot_id, state} = grant_slot(state, request)
        GenServer.reply(from, {:ok, slot_id})
        serve_queue(state)
    end
  end

  defp take_eligible_request(state) do
    queue = :queue.to_list(state.queue)

    case Enum.find_index(queue, &slot_available?(state, &1.scope)) do
      nil ->
        {:none, state}

      index ->
        {request, queue} = List.pop_at(queue, index)
        {request, %{state | queue: :queue.from_list(queue)}}
    end
  end

  defp increment_scope(counts, nil), do: counts

  defp increment_scope(counts, %{id: id}) do
    Map.update(counts, id, 1, &(&1 + 1))
  end

  defp decrement_scope(counts, nil), do: counts

  defp decrement_scope(counts, %{id: id}) do
    case Map.get(counts, id, 0) do
      count when count <= 1 -> Map.delete(counts, id)
      count -> Map.put(counts, id, count - 1)
    end
  end

  defp normalize_scope(opts) do
    case {Keyword.get(opts, :root_task_run_id), Keyword.get(opts, :max_concurrency)} do
      {id, limit} when is_binary(id) and is_integer(limit) and limit > 0 ->
        %{id: id, limit: limit}

      _ ->
        nil
    end
  end
end
