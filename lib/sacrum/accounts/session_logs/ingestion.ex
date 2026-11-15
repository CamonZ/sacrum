defmodule Sacrum.Accounts.SessionLogs.Ingestion do
  @moduledoc """
  Accepts, broadcasts and persists harness session-log events for one step
  execution, storing each item only once it completes.

  `ingest/2` validates the event in the caller and hands it to the execution's
  process, which replies as soon as the event is accepted. Accepting an event
  assigns its row id and timestamps and broadcasts it as `session_log_created`
  on the project channel, so every event reaches clients in arrival order
  without waiting on the database or CDC. A row persisted later keeps that id
  and `inserted_at`, so its CDC `session_log_created` replaces the live entry
  and history sorts it where it was accepted.

  Events are grouped by `Sacrum.Accounts.SessionLogs.HarnessItem`:

  - Deltas (text, reasoning, tool input, tool progress output) are broadcast
    and never stored; once their item is complete they are no longer broadcast.
  - An open tool item keeps, in memory, the latest snapshot of each event type
    (`tool_call`, `tool_output`, `file_change`). When it completes, only its
    final state is stored: those latest snapshots and the completing event.
    Superseded snapshots are broadcast but never stored.
  - A text snapshot completes its item and is stored.
  - Point events (usage, errors, lifecycle, ...) are complete on arrival.
  - `turn_finished`, `run_finished` and `session_closed` close the items still
    open on their stream, storing what they hold; `flush/2` closes every open
    item.

  Each completed item, or point event, becomes one unit, written in its own
  transaction with the execution's usage counters as of that unit. Units are
  written in completion order by a single writer task. The process is the only
  writer of those counters, so it does not lock the step execution row. A
  failed write is retried with backoff until it succeeds; only a write that can
  never succeed, such as for a deleted execution, is dropped and logged.

  Redelivery of an accepted event (same `logical_key` and content) returns the
  accepted log without broadcasting it again. Delta identities are not tracked,
  so a retried delta is broadcast again.

  The process seeds its totals, completed items and accepted keys from
  persisted history on its first event, and stops after `@idle_timeout`
  without events once no item is open and nothing is unwritten.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Sacrum.Accounts.SessionLogs.{HarnessItem, UsageRollups}
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}
  alias Sacrum.Repo.SessionLogs, as: SessionLogRepo
  alias SacrumWeb.ProjectChannel

  @registry Sacrum.Accounts.SessionLogs.IngestionRegistry
  @supervisor Sacrum.Accounts.SessionLogs.IngestionSupervisor
  @writers Sacrum.Accounts.SessionLogs.IngestionWriterSupervisor
  @idle_timeout :timer.minutes(5)
  @call_timeout :timer.seconds(30)
  @flush_timeout :timer.seconds(30)
  @shutdown_write_timeout :timer.seconds(4)
  @retry_base_ms 50
  @retry_max_ms :timer.seconds(5)

  @doc "Ingest one harness event for an authorized execution."
  @spec ingest(StepExecution.t(), map()) ::
          {:ok, SessionLog.t()}
          | {:error, Ecto.Changeset.t() | :event_identity_conflict | :ingestion_failed}
  def ingest(%StepExecution{} = execution, attrs) do
    case SessionLogRepo.changeset(execution.user_id, attrs) do
      %Ecto.Changeset{valid?: true} = changeset ->
        log = Ecto.Changeset.apply_changes(changeset)
        item = log.content |> Jason.decode!() |> HarnessItem.classify()
        message = {:ingest, log, item}

        try do
          GenServer.call(server(execution.id), message, @call_timeout)
        catch
          # The process stopped while idle before taking the message; start a new one.
          :exit, {reason, _call} when reason in [:noproc, :normal] ->
            GenServer.call(server(execution.id), message, @call_timeout)
        end

      changeset ->
        {:error, changeset}
    end
  end

  @doc """
  Close every open item and wait until every accepted event is persisted.

  Returns `:idle` when no ingestion process runs for the execution, `:flushed`
  once a running process has nothing unwritten, or `{:error, :timeout}`.
  """
  @spec flush(String.t(), timeout()) :: :idle | :flushed | {:error, :timeout}
  def flush(execution_id, timeout \\ @flush_timeout),
    do: call_flush(execution_id, :flush, timeout)

  defp call_flush(execution_id, message, timeout) do
    case Registry.lookup(@registry, execution_id) do
      [] ->
        :idle

      [{pid, _value}] ->
        try do
          GenServer.call(pid, message, timeout)
        catch
          # It stops only when nothing is open or unwritten.
          :exit, {reason, _call} when reason in [:noproc, :normal] -> :idle
          :exit, {:timeout, _call} -> {:error, :timeout}
        end
    end
  end

  @doc """
  Wait until every completed unit accepted so far is persisted, leaving open
  items open. Returns like `flush/2`.
  """
  @spec drain(String.t(), timeout()) :: :idle | :flushed | {:error, :timeout}
  def drain(execution_id, timeout \\ @flush_timeout),
    do: call_flush(execution_id, :drain, timeout)

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(execution_id) do
    GenServer.start_link(__MODULE__, execution_id,
      name: {:via, Registry, {@registry, execution_id}}
    )
  end

  defp server(execution_id) do
    case Registry.lookup(@registry, execution_id) do
      [{pid, _value}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, execution_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  @impl true
  def init(execution_id) do
    # Trap exits so a shutdown runs `terminate/2` and writes what it holds.
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       execution_id: execution_id,
       loaded?: false,
       rollup: UsageRollups.new(),
       # Items whose final state was accepted.
       completed: MapSet.new(),
       # Open tool items: key => %{event_type => latest snapshot log}.
       open: %{},
       accepted: %{},
       last_inserted_at: nil,
       # Units to write, oldest first: %{logs: [log], counters: map}.
       units: :queue.new(),
       # The head unit's write in flight: %{task: Task.t()}.
       writing: nil,
       attempts: 0,
       retry_timer: nil,
       waiters: [],
       caller: nil
     }, @idle_timeout}
  end

  @impl true
  def handle_call({:ingest, log, item}, {caller, _tag}, state) do
    # Queries run on the latest caller's behalf. `:caller` lets an ownership
    # pool, such as the test SQL sandbox, use the caller's connection.
    state = %{state | caller: caller}

    case load(state) do
      {:ok, state} ->
        {reply, state} = accept(log, item, state)
        {:reply, reply, write(state), @idle_timeout}

      :error ->
        {:reply, {:error, :ingestion_failed}, state, @idle_timeout}
    end
  end

  def handle_call(:flush, from, state) do
    state
    |> close_items(fn _key -> true end, "flush")
    |> write()
    |> await_writes(from)
  end

  def handle_call(:drain, from, state), do: await_writes(state, from)

  defp await_writes(state, from) do
    if idle?(state) do
      {:reply, :flushed, state, @idle_timeout}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}, @idle_timeout}
    end
  end

  @impl true
  def handle_info({ref, result}, %{writing: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, written(state, result), @idle_timeout}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{writing: %{task: %Task{ref: ref}}} = state
      ) do
    {:noreply, written(state, {:error, {:exit, reason}}), @idle_timeout}
  end

  def handle_info(:retry, state) do
    {:noreply, write(%{state | retry_timer: nil}), @idle_timeout}
  end

  def handle_info(:timeout, state) do
    if idle?(state) and state.open == %{} do
      {:stop, :normal, state}
    else
      {:noreply, state, @idle_timeout}
    end
  end

  def handle_info(_message, state), do: {:noreply, state, @idle_timeout}

  @impl true
  def terminate(_reason, state) do
    state = close_items(state, fn _key -> true end, "shutdown")

    units =
      case state.writing do
        nil ->
          state.units

        %{task: task} ->
          case Task.yield(task, @shutdown_write_timeout) || Task.shutdown(task) do
            {:ok, :ok} -> :queue.drop(state.units)
            _failed -> state.units
          end
      end

    write_now(state, :queue.to_list(units))
  end

  defp write_now(_state, []), do: :ok

  defp write_now(state, [unit | rest] = units) do
    case persist(state.execution_id, unit, state.caller) do
      :ok ->
        write_now(state, rest)

      {:error, reason} ->
        Logger.error(
          "Session-log ingestion for step execution #{state.execution_id} stopped " <>
            "with #{length(units)} unwritten units: #{inspect(reason)}"
        )
    end
  end

  # History is read once per process, on its first event.
  defp load(%{loaded?: true} = state), do: {:ok, state}

  defp load(state) do
    logs = SessionLogRepo.harness_logs(state.execution_id, caller: state.caller)

    completed =
      for log <- logs,
          {:ok, event} <- [Jason.decode(log.content)],
          HarnessItem.completes?(event),
          into: MapSet.new(),
          do: HarnessItem.item_key(event)

    {:ok,
     %{
       state
       | loaded?: true,
         rollup: Enum.reduce(logs, UsageRollups.new(), &UsageRollups.add(&2, &1)),
         completed: completed,
         accepted: Map.new(logs, &{&1.logical_key, identity(&1)}),
         last_inserted_at: logs |> List.last() |> then(&(&1 && &1.inserted_at))
     }}
  catch
    kind, reason ->
      Logger.error(
        "Session-log history load failed for step execution #{state.execution_id}: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      :error
  end

  defp accept(log, {:delta, key}, state) do
    {log, state} = stamp(log, state)

    unless MapSet.member?(state.completed, key) do
      ProjectChannel.broadcast_session_log_created(log.project_id, log)
    end

    {{:ok, log}, state}
  end

  defp accept(log, item, state) do
    case Map.fetch(state.accepted, log.logical_key) do
      {:ok, accepted} ->
        if accepted.format == log.format and accepted.hash == hash(log.content) do
          {{:ok, Map.merge(log, Map.take(accepted, [:id, :inserted_at, :updated_at]))}, state}
        else
          {{:error, :event_identity_conflict}, state}
        end

      :error ->
        {log, state} = stamp(log, state)
        state = %{state | accepted: Map.put(state.accepted, log.logical_key, identity(log))}
        ProjectChannel.broadcast_session_log_created(log.project_id, log)
        {{:ok, log}, place(log, item, state)}
    end
  end

  # An event for an item that already completed is complete in its own right.
  defp place(log, {kind, key, type}, state) when kind in [:open, :complete] do
    cond do
      MapSet.member?(state.completed, key) -> enqueue(state, [log])
      kind == :open -> update_item(state, key, type, log)
      true -> complete_item(state, key, type, log)
    end
  end

  defp place(log, {:close_stream, stream_id}, state) do
    state
    |> close_items(&match?({_kind, ^stream_id, _id}, &1), "#{stream_id} terminal event")
    |> enqueue([log])
  end

  defp place(log, :point, state), do: enqueue(state, [log])

  # An open item keeps only the latest snapshot of each event type.
  defp update_item(state, key, type, log) do
    %{state | open: Map.update(state.open, key, %{type => log}, &Map.put(&1, type, log))}
  end

  # The item's final state: its latest snapshots plus the completing event. A
  # terminal delta (`type` nil) carries no final state of its own.
  defp complete_item(state, key, type, log) do
    {snapshots, open} = Map.pop(state.open, key, %{})

    final =
      if type do
        Map.put(snapshots, type, log)
      else
        Logger.warning(
          "Harness item #{inspect(key)} completed by a delta (#{log.logical_key}); " <>
            "storing its last snapshots"
        )

        snapshots
      end

    enqueue(
      %{state | open: open, completed: MapSet.put(state.completed, key)},
      chronological(final)
    )
  end

  defp chronological(snapshots),
    do: snapshots |> Map.values() |> Enum.sort_by(& &1.inserted_at, DateTime)

  # Option (a): an item still open when its stream ends, at a flush or at
  # shutdown is stored as it stands, with a warning.
  defp close_items(state, match?, reason) do
    {closing, open} = Map.split_with(state.open, fn {key, _snapshots} -> match?.(key) end)

    closing
    |> Enum.map(fn {key, snapshots} -> {key, chronological(snapshots)} end)
    |> Enum.sort_by(fn {_key, [first | _]} -> first.inserted_at end, DateTime)
    |> Enum.reduce(%{state | open: open}, fn {key, logs}, state ->
      Logger.warning("Storing unfinished harness item #{inspect(key)} at #{reason}")
      enqueue(%{state | completed: MapSet.put(state.completed, key)}, logs)
    end)
  end

  defp enqueue(state, []), do: state

  defp enqueue(state, logs) do
    rollup = Enum.reduce(logs, state.rollup, &UsageRollups.add(&2, &1))
    unit = %{logs: logs, counters: UsageRollups.attrs(rollup)}
    %{state | rollup: rollup, units: :queue.in(unit, state.units)}
  end

  # Ids and strictly increasing timestamps are assigned on acceptance, so the
  # broadcast, the reply and the persisted row agree, and history reloads in
  # acceptance order.
  defp stamp(%SessionLog{} = log, state) do
    now = DateTime.utc_now()

    at =
      if state.last_inserted_at && DateTime.compare(now, state.last_inserted_at) != :gt,
        do: DateTime.add(state.last_inserted_at, 1, :microsecond),
        else: now

    log = %SessionLog{log | id: Ecto.UUID.generate(), inserted_at: at, updated_at: at}
    {log, %{state | last_inserted_at: at}}
  end

  defp identity(log) do
    %{
      id: log.id,
      inserted_at: log.inserted_at,
      updated_at: log.updated_at,
      format: log.format,
      hash: hash(log.content)
    }
  end

  defp hash(content), do: :crypto.hash(:sha256, content)

  # Write the oldest unit unless a write is in flight or waiting to be retried.
  # A unit leaves the queue only once its write succeeds or is dropped.
  defp write(%{writing: nil, retry_timer: nil} = state) do
    case :queue.peek(state.units) do
      {:value, unit} ->
        %{execution_id: execution_id, caller: caller} = state

        task =
          Task.Supervisor.async_nolink(@writers, fn ->
            persist(execution_id, unit, caller)
          end)

        %{state | writing: %{task: task}}

      :empty ->
        reply_waiters(state)
    end
  end

  defp write(state), do: state

  defp persist(execution_id, unit, caller) do
    SessionLogRepo.persist_batch(execution_id, unit.logs, unit.counters, caller: caller)
  rescue
    exception -> {:error, exception}
  end

  defp written(state, :ok) do
    write(%{state | writing: nil, attempts: 0, units: :queue.drop(state.units)})
  end

  defp written(state, {:error, reason}) do
    state = %{state | writing: nil}

    if permanent_failure?(reason) do
      {:value, unit} = :queue.peek(state.units)

      Logger.error(
        "Dropping #{length(unit.logs)} session-log events for step execution " <>
          "#{state.execution_id}: #{inspect(reason)}"
      )

      write(%{state | attempts: 0, units: :queue.drop(state.units)})
    else
      delay = min(@retry_base_ms * Integer.pow(2, state.attempts), @retry_max_ms)

      Logger.warning(
        "Session-log write for step execution #{state.execution_id} failed; " <>
          "retrying in #{delay}ms: #{inspect(reason)}"
      )

      %{
        state
        | attempts: state.attempts + 1,
          retry_timer: Process.send_after(self(), :retry, delay)
      }
    end
  end

  # The execution is gone, or (in tests) the connection owner exited.
  defp permanent_failure?(%Postgrex.Error{postgres: %{code: :foreign_key_violation}}), do: true
  defp permanent_failure?(%DBConnection.OwnershipError{}), do: true
  defp permanent_failure?(_reason), do: false

  defp idle?(state), do: :queue.is_empty(state.units) and is_nil(state.writing)

  defp reply_waiters(%{waiters: [_ | _]} = state) do
    if idle?(state) do
      Enum.each(state.waiters, &GenServer.reply(&1, :flushed))
      %{state | waiters: []}
    else
      state
    end
  end

  defp reply_waiters(state), do: state
end
