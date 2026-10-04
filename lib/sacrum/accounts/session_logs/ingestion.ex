defmodule Sacrum.Accounts.SessionLogs.Ingestion do
  @moduledoc """
  Serializes harness session-log ingestion for one step execution.

  The process reads the execution's persisted logs once, on its first event, to
  seed usage totals, then advances them as logs commit. Streaming text deltas
  are published directly as `session_log_created` without writing a row or
  keeping their text. The item's text snapshot is persisted with the usage
  counters and reaches clients through CDC; deltas for an item
  `{stream_id, item_id}` that is already final are dropped. Every other event is
  persisted as it arrives.

  Delta identities are not durable, so a retried delta is broadcast again. An
  error while handling an event is returned to the caller and leaves the
  process running. The process stops after `@idle_timeout` without events.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Sacrum.Accounts.SessionLogs.{HarnessEventV1, UsageRollups}
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}
  alias Sacrum.Repo.SessionLogs, as: SessionLogRepo
  alias SacrumWeb.ProjectChannel

  @registry Sacrum.Accounts.SessionLogs.IngestionRegistry
  @supervisor Sacrum.Accounts.SessionLogs.IngestionSupervisor
  @idle_timeout :timer.minutes(5)
  @call_timeout :timer.seconds(30)

  @doc "Ingest one harness event for an authorized execution."
  @spec ingest(StepExecution.t(), map()) ::
          {:ok, SessionLog.t()}
          | {:error,
             Ecto.Changeset.t() | :event_identity_conflict | :not_found | :ingestion_failed}
  def ingest(%StepExecution{} = execution, attrs) do
    message = {:ingest, execution.user_id, attrs}

    try do
      GenServer.call(server(execution.id), message, @call_timeout)
    catch
      # The process stopped while idle before taking the message; start a new one.
      :exit, {reason, _call} when reason in [:noproc, :normal] ->
        GenServer.call(server(execution.id), message, @call_timeout)
    end
  end

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
    {:ok, %{execution_id: execution_id, rollup: nil, finalized: MapSet.new()}, @idle_timeout}
  end

  @impl true
  def handle_call({:ingest, user_id, attrs}, {caller, _tag}, state) do
    # Queries run on the caller's behalf. `:caller` lets an ownership pool,
    # such as the test SQL sandbox, use the caller's connection.
    repo_opts = [caller: caller]

    {reply, state} =
      try do
        state = load(state, repo_opts)

        user_id
        |> SessionLogRepo.changeset(attrs)
        |> ingest_changeset(state, repo_opts)
      catch
        # State only advances after a commit, so the pre-call state stays valid.
        kind, reason ->
          Logger.error(
            "Session-log ingestion failed for step execution #{state.execution_id}: " <>
              Exception.format(kind, reason, __STACKTRACE__)
          )

          {{:error, :ingestion_failed}, state}
      end

    {:reply, reply, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  defp load(%{rollup: nil} = state, repo_opts) do
    logs = SessionLogRepo.harness_logs(state.execution_id, repo_opts)

    finalized =
      for log <- logs,
          {:ok, event} <- [HarnessEventV1.decode(log.content, log.logical_key)],
          {"snapshot", key} <- [HarnessEventV1.text_item(event)],
          into: MapSet.new(),
          do: key

    %{
      state
      | rollup: Enum.reduce(logs, UsageRollups.new(), &UsageRollups.add(&2, &1)),
        finalized: finalized
    }
  end

  defp load(state, _repo_opts), do: state

  defp ingest_changeset(%Ecto.Changeset{valid?: false} = changeset, state, _repo_opts),
    do: {{:error, changeset}, state}

  defp ingest_changeset(changeset, state, repo_opts) do
    event = changeset |> Ecto.Changeset.get_field(:content) |> Jason.decode!()

    case HarnessEventV1.text_item(event) do
      {"delta", key} -> publish(changeset, key, state)
      {"snapshot", key} -> persist(changeset, key, state, repo_opts)
      nil -> persist(changeset, nil, state, repo_opts)
    end
  end

  defp publish(changeset, key, state) do
    log = unpersisted_log(changeset)

    unless MapSet.member?(state.finalized, key) do
      ProjectChannel.broadcast_session_log_created(log.project_id, log)
    end

    {{:ok, log}, state}
  end

  defp persist(changeset, key, state, repo_opts) do
    case SessionLogRepo.persist(changeset, state.rollup, repo_opts) do
      {:ok, log, rollup} -> {{:ok, log}, finalize(%{state | rollup: rollup}, key)}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp finalize(state, nil), do: state

  defp finalize(state, key), do: %{state | finalized: MapSet.put(state.finalized, key)}

  # Deltas never get a row; the reply and broadcast carry the same fields a
  # persisted log projects through CDC.
  defp unpersisted_log(changeset) do
    now = DateTime.utc_now()

    changeset
    |> Ecto.Changeset.apply_changes()
    |> Map.merge(%{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})
  end
end
