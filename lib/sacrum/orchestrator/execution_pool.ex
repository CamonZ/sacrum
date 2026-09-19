defmodule Sacrum.Orchestrator.ExecutionPool do
  @moduledoc """
  Coordinates in-memory step admission and task-run placement.

  Every task-run tree is pinned to one assigned daemon for the lifetime of the
  coordinator. Active steps consume temporary slots from that daemon. The
  coordinator has no fleet-wide capacity limit.
  """

  use GenServer

  require Logger

  @retry_interval 100

  @type slot_id :: pos_integer()

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Requests admission for one attempt and waits fairly for capacity."
  @spec request_slot(pid(), timeout()) :: {:ok, slot_id()} | {:error, atom()}
  def request_slot(pid, timeout \\ :infinity)

  def request_slot(pid, timeout) when is_pid(pid) do
    request_slot(__MODULE__, pid, timeout, [])
  end

  @spec request_slot(pid(), timeout(), keyword()) :: {:ok, slot_id()} | {:error, atom()}
  def request_slot(pid, timeout, opts) when is_pid(pid) and is_list(opts) do
    request_slot(__MODULE__, pid, timeout, opts)
  end

  @spec request_slot(GenServer.server(), pid(), timeout()) ::
          {:ok, slot_id()} | {:error, atom()}
  def request_slot(server, pid, timeout), do: request_slot(server, pid, timeout, [])

  @spec request_slot(GenServer.server(), pid(), timeout(), keyword()) ::
          {:ok, slot_id()} | {:error, atom()}
  def request_slot(server, pid, timeout, opts) when is_list(opts) do
    GenServer.call(server, {:request_slot, pid, normalize_request(opts)}, timeout)
  end

  @spec release_slot(slot_id() | nil) :: :ok
  def release_slot(nil), do: :ok

  def release_slot(slot_id), do: release_slot(__MODULE__, slot_id)

  @spec release_slot(GenServer.server(), slot_id() | nil) :: :ok
  def release_slot(_server, nil), do: :ok

  def release_slot(server, slot_id), do: GenServer.call(server, {:release_slot, slot_id})

  @doc "Cancels all queued requests owned by a process. Active slots are not cancelled here."
  @spec cancel_request(pid()) :: :ok
  def cancel_request(pid) when is_pid(pid), do: cancel_request(__MODULE__, pid)

  @spec cancel_request(GenServer.server(), pid()) :: :ok
  def cancel_request(server, pid) when is_pid(pid),
    do: GenServer.call(server, {:cancel_request, pid})

  @spec pool_status() :: map()
  def pool_status, do: pool_status(__MODULE__)

  @spec pool_status(GenServer.server()) :: map()
  def pool_status(server), do: GenServer.call(server, :pool_status)

  @doc "Releases a completed root task-run placement when it has no active slots."
  @spec release_task_group(String.t() | nil) :: :ok
  def release_task_group(nil), do: :ok
  def release_task_group(task_group_id), do: release_task_group(__MODULE__, task_group_id)

  @spec release_task_group(GenServer.server(), String.t() | nil) :: :ok
  def release_task_group(_server, nil), do: :ok

  def release_task_group(server, task_group_id) do
    GenServer.call(server, {:release_task_group, task_group_id})
  end

  @impl true
  def init(_opts) do
    state = %{
      next_slot_id: 1,
      in_use: %{},
      in_use_by_scope: %{},
      in_use_by_daemon: %{},
      daemon_limits: %{},
      task_groups: %{},
      monitors: %{},
      queue: :queue.new(),
      queued_monitors: %{},
      retry_timer: nil
    }

    Logger.info("[ExecutionPool] Initialized with per-daemon capacity")

    {:ok, state}
  end

  @impl true
  def handle_call({:request_slot, pid, request}, from, state) do
    request = %{request | pid: pid}

    {:ok, request, state} = bind_task_group(state, request)
    state = remember_daemon_limit(state, request)

    result =
      case duplicate_slot(state, request) do
        slot_id when is_integer(slot_id) ->
          {:reply, {:ok, slot_id}, state}

        nil ->
          handle_new_request(state, pid, request, from)
      end

    case result do
      {:reply, reply, state} -> {:reply, reply, serve_queue(state)}
      {:noreply, state} -> {:noreply, state}
    end
  end

  @impl true
  def handle_call({:release_slot, slot_id}, _from, state) do
    case Map.fetch(state.in_use, slot_id) do
      {:ok, _entry} ->
        {:reply, :ok, remove_slot_and_serve_queue(state, slot_id)}

      :error ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:cancel_request, pid}, _from, state) do
    {cancelled, remaining} =
      state.queue
      |> :queue.to_list()
      |> Enum.split_with(&(&1.pid == pid))

    Enum.each(cancelled, fn %{from: from, monitor_ref: monitor_ref} ->
      Process.demonitor(monitor_ref, [:flush])
      GenServer.reply(from, {:error, :cancelled})
    end)

    queued_monitors =
      Enum.reduce(cancelled, state.queued_monitors, fn request, monitors ->
        Map.delete(monitors, request.monitor_ref)
      end)

    {:reply, :ok, %{state | queue: :queue.from_list(remaining), queued_monitors: queued_monitors}}
  end

  @impl true
  def handle_call(:pool_status, _from, state) do
    {:reply, pool_status_map(state), state}
  end

  @impl true
  def handle_call({:release_task_group, task_group_id}, _from, state) do
    {:reply, :ok, %{state | task_groups: release_task_group_if_idle(state, task_group_id)}}
  end

  @impl true
  def handle_info(:retry_queue, state) do
    state = serve_queue(%{state | retry_timer: nil})
    {:noreply, schedule_retry(state)}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, slot_id} ->
        # A process-owned in-memory slot is released when its owner exits.
        {:noreply, remove_slot_and_serve_queue(state, slot_id)}

      :error ->
        {:noreply, remove_queued_request(state, monitor_ref)}
    end
  end

  defp grant_or_queue(state, request, from) do
    {slot_id, state} = grant_slot(state, %{request | from: from})
    {:granted, slot_id, state}
  end

  defp bind_task_group(state, %{task_group_id: nil} = request),
    do: {:ok, request, state}

  defp bind_task_group(
         %{task_groups: task_groups} = state,
         %{task_group_id: task_group_id, daemon_id: nil} = request
       )
       when is_binary(task_group_id) do
    case Map.get(task_groups, task_group_id) do
      nil ->
        {:ok, request, state}

      daemon_id ->
        daemon_max_concurrency = Map.get(state.daemon_limits, daemon_id)

        {:ok, %{request | daemon_id: daemon_id, daemon_max_concurrency: daemon_max_concurrency},
         state}
    end
  end

  defp bind_task_group(
         %{task_groups: task_groups} = state,
         %{task_group_id: task_group_id, daemon_id: daemon_id} = request
       )
       when is_binary(task_group_id) and is_binary(daemon_id) do
    case Map.get(task_groups, task_group_id) do
      nil ->
        state = put_in(state, [:task_groups, task_group_id], daemon_id)
        state = rebind_queued_task_group(state, task_group_id, daemon_id, request)
        {:ok, request, state}

      ^daemon_id ->
        {:ok, request, state}

      assigned_daemon_id ->
        daemon_max_concurrency =
          Map.get(state.daemon_limits, assigned_daemon_id, request.daemon_max_concurrency)

        {:ok,
         %{
           request
           | daemon_id: assigned_daemon_id,
             daemon_max_concurrency: daemon_max_concurrency
         }, state}
    end
  end

  defp remember_daemon_limit(state, %{daemon_id: daemon_id, daemon_max_concurrency: limit})
       when is_binary(daemon_id) do
    %{state | daemon_limits: Map.put(state.daemon_limits, daemon_id, normalize_limit(limit))}
  end

  defp remember_daemon_limit(state, _request), do: state

  defp rebind_queued_task_group(state, task_group_id, daemon_id, request) do
    queue =
      state.queue
      |> :queue.to_list()
      |> Enum.map(fn
        %{task_group_id: ^task_group_id} = queued_request ->
          %{
            queued_request
            | daemon_id: daemon_id,
              daemon_max_concurrency: request.daemon_max_concurrency
          }

        queued_request ->
          queued_request
      end)

    %{state | queue: :queue.from_list(queue)}
  end

  defp handle_new_request(state, pid, request, from) do
    cond do
      queued_duplicate?(state, request) ->
        {:reply, {:error, :duplicate_attempt}, state}

      slot_available?(state, request) ->
        handle_available_request(state, request, from)

      true ->
        queue_request(state, pid, from, request)
    end
  end

  defp handle_available_request(state, request, from) do
    {:granted, slot_id, new_state} = grant_or_queue(state, request, from)
    {:reply, {:ok, slot_id}, new_state}
  end

  defp queue_request(state, pid, from, request) do
    {:noreply, schedule_retry(enqueue_request(state, pid, from, request))}
  end

  defp pool_status_map(state) do
    daemon_ids =
      state.in_use_by_daemon
      |> Map.keys()
      |> Kernel.++(Map.keys(state.daemon_limits))
      |> Enum.uniq()

    per_daemon =
      Enum.reduce(daemon_ids, %{}, fn daemon_id, result ->
        local_in_use = Map.get(state.in_use_by_daemon, daemon_id, 0)
        configured = Map.get(state.daemon_limits, daemon_id)

        Map.put(result, daemon_id, %{
          daemon_id: daemon_id,
          in_use: local_in_use,
          configured: configured,
          available: available(configured, local_in_use)
        })
      end)

    %{
      in_use_count: map_size(state.in_use),
      in_use_by_scope: state.in_use_by_scope,
      in_use_by_daemon: state.in_use_by_daemon,
      task_groups: state.task_groups,
      per_daemon: per_daemon,
      queue_length: :queue.len(state.queue)
    }
  end

  defp available(nil, _in_use), do: :infinity
  defp available(:infinity, _in_use), do: :infinity
  defp available(limit, in_use), do: max(limit - in_use, 0)

  defp slot_available?(state, request) do
    daemon_available?(state, request) and scope_available?(state, request.scope)
  end

  defp daemon_available?(_state, %{daemon_id: nil}), do: true

  defp daemon_available?(state, %{daemon_id: daemon_id}) do
    case Map.get(state.daemon_limits, daemon_id) do
      nil -> true
      limit -> Map.get(state.in_use_by_daemon, daemon_id, 0) < limit
    end
  end

  defp scope_available?(_state, nil), do: true

  defp scope_available?(state, %{id: id, limit: limit}) do
    Map.get(state.in_use_by_scope, id, 0) < limit
  end

  defp duplicate_slot(state, %{daemon_id: daemon_id, attempt_id: attempt_id})
       when is_binary(daemon_id) and is_binary(attempt_id) do
    case Enum.find(state.in_use, fn {_slot_id, entry} ->
           entry.daemon_id == daemon_id and entry.attempt_id == attempt_id
         end) do
      {slot_id, _entry} -> slot_id
      nil -> nil
    end
  end

  defp duplicate_slot(_state, _request), do: nil

  defp queued_duplicate?(state, %{daemon_id: daemon_id, attempt_id: attempt_id})
       when is_binary(daemon_id) and is_binary(attempt_id) do
    state.queue
    |> :queue.to_list()
    |> Enum.any?(fn request ->
      request.daemon_id == daemon_id and request.attempt_id == attempt_id
    end)
  end

  defp queued_duplicate?(_state, _request), do: false

  defp grant_slot(state, %{pid: pid, scope: scope} = request) do
    slot_id = state.next_slot_id
    monitor_ref = Process.monitor(pid)
    daemon_id = request.daemon_id

    entry = %{
      pid: pid,
      monitor_ref: monitor_ref,
      scope: scope,
      daemon_id: daemon_id,
      task_group_id: request.task_group_id,
      attempt_id: request.attempt_id,
      execution_id: request.execution_id,
      from: request.from
    }

    new_state = %{
      state
      | next_slot_id: slot_id + 1,
        in_use: Map.put(state.in_use, slot_id, entry),
        in_use_by_scope: increment_scope(state.in_use_by_scope, scope),
        in_use_by_daemon: increment_daemon(state.in_use_by_daemon, daemon_id),
        daemon_limits: put_limit(state.daemon_limits, daemon_id, request.daemon_max_concurrency),
        monitors: Map.put(state.monitors, monitor_ref, slot_id)
    }

    Logger.info(
      "[ExecutionPool] Admitted slot=#{slot_id} daemon=#{inspect(daemon_id)} attempt=#{inspect(request.attempt_id)}"
    )

    {slot_id, new_state}
  end

  defp enqueue_request(state, pid, from, request) do
    monitor_ref = Process.monitor(pid)
    request = Map.merge(request, %{pid: pid, from: from, monitor_ref: monitor_ref})

    %{
      state
      | queue: :queue.in(request, state.queue),
        queued_monitors: Map.put(state.queued_monitors, monitor_ref, true)
    }
  end

  defp remove_slot_and_serve_queue(state, slot_id) do
    case Map.pop(state.in_use, slot_id) do
      {nil, _in_use} ->
        state

      {%{monitor_ref: monitor_ref} = entry, in_use} ->
        Process.demonitor(monitor_ref, [:flush])

        state
        |> Map.put(:in_use, in_use)
        |> Map.put(:monitors, Map.delete(state.monitors, monitor_ref))
        |> Map.put(:in_use_by_scope, decrement_scope(state.in_use_by_scope, entry.scope))
        |> Map.put(:in_use_by_daemon, decrement_daemon(state.in_use_by_daemon, entry.daemon_id))
        |> serve_queue()
    end
  end

  defp release_task_group_if_idle(state, task_group_id) do
    if task_group_active?(state, task_group_id) do
      state.task_groups
    else
      Map.delete(state.task_groups, task_group_id)
    end
  end

  defp task_group_active?(state, task_group_id) do
    Enum.any?(state.in_use, fn {_slot_id, entry} -> entry.task_group_id == task_group_id end) or
      Enum.any?(:queue.to_list(state.queue), &(&1.task_group_id == task_group_id))
  end

  defp serve_queue(state), do: serve_queue(state, :queue.len(state.queue))
  defp serve_queue(state, 0), do: state

  defp serve_queue(state, attempts) do
    case take_eligible_request(state) do
      {:none, state} ->
        state

      {%{from: from} = request, state} ->
        state = remove_queued_monitor(state, request.monitor_ref)

        {:granted, slot_id, state} = grant_or_queue(state, request, from)
        GenServer.reply(from, {:ok, slot_id})
        serve_queue(state, attempts - 1)
    end
  end

  defp take_eligible_request(state) do
    queue = :queue.to_list(state.queue)

    case Enum.find_index(queue, &slot_available?(state, &1)) do
      nil ->
        {:none, state}

      index ->
        {request, queue} = List.pop_at(queue, index)
        {request, %{state | queue: :queue.from_list(queue)}}
    end
  end

  defp remove_queued_monitor(state, monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    %{state | queued_monitors: Map.delete(state.queued_monitors, monitor_ref)}
  end

  defp remove_queued_request(state, monitor_ref) do
    if Map.has_key?(state.queued_monitors, monitor_ref) do
      remaining =
        state.queue
        |> :queue.to_list()
        |> Enum.reject(&(&1.monitor_ref == monitor_ref))

      %{
        state
        | queue: :queue.from_list(remaining),
          queued_monitors: Map.delete(state.queued_monitors, monitor_ref)
      }
    else
      state
    end
  end

  defp schedule_retry(%{queue: queue, retry_timer: nil} = state) do
    if :queue.is_empty(queue) do
      state
    else
      %{state | retry_timer: Process.send_after(self(), :retry_queue, @retry_interval)}
    end
  end

  defp schedule_retry(state), do: state

  defp increment_scope(counts, nil), do: counts
  defp increment_scope(counts, %{id: id}), do: Map.update(counts, id, 1, &(&1 + 1))

  defp decrement_scope(counts, nil), do: counts

  defp decrement_scope(counts, %{id: id}) do
    case Map.get(counts, id, 0) do
      count when count <= 1 -> Map.delete(counts, id)
      count -> Map.put(counts, id, count - 1)
    end
  end

  defp increment_daemon(counts, nil), do: counts
  defp increment_daemon(counts, id), do: Map.update(counts, id, 1, &(&1 + 1))

  defp decrement_daemon(counts, nil), do: counts

  defp decrement_daemon(counts, id) do
    case Map.get(counts, id, 0) do
      count when count <= 1 -> Map.delete(counts, id)
      count -> Map.put(counts, id, count - 1)
    end
  end

  defp put_limit(limits, nil, _limit), do: limits
  defp put_limit(limits, id, nil), do: Map.put(limits, id, nil)

  defp put_limit(limits, id, limit) when is_integer(limit) and limit > 0,
    do: Map.put(limits, id, limit)

  defp put_limit(limits, _id, _limit), do: limits

  defp normalize_request(opts) do
    %{
      pid: nil,
      from: nil,
      monitor_ref: nil,
      scope: normalize_scope(opts),
      daemon_id: Keyword.get(opts, :daemon_id),
      daemon_max_concurrency: Keyword.get(opts, :daemon_max_concurrency),
      task_group_id: Keyword.get(opts, :task_group_id, Keyword.get(opts, :root_task_run_id)),
      attempt_id: Keyword.get(opts, :attempt_id),
      execution_id: Keyword.get(opts, :execution_id)
    }
  end

  defp normalize_scope(opts) do
    case {Keyword.get(opts, :root_task_run_id), Keyword.get(opts, :max_concurrency)} do
      {id, limit} when is_binary(id) and is_integer(limit) and limit > 0 ->
        %{id: id, limit: limit}

      _ ->
        nil
    end
  end

  defp normalize_limit(nil), do: nil
  defp normalize_limit(:infinity), do: :infinity
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_limit), do: nil
end
