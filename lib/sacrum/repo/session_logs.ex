defmodule Sacrum.Repo.SessionLogs do
  @moduledoc """
  Operations for session logs within step executions.

  ## Error Contract

  - `get/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `get!/1` returns log or raises
  - `get_by/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `all/0` returns `[log]`
  - `persist/3` returns `{:ok, log, rollup}`, `{:error, changeset}`,
    `{:error, :not_found}`, or `{:error, :event_identity_conflict}` for an
    immutable harness event key

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.SessionLog

  import Ecto.Query
  alias Sacrum.Accounts.SessionLogs.UsageRollups
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  @doc """
  Build the create changeset for a session log owned by user_id.
  Takes step_execution_id and project_id from attrs.
  """
  @spec changeset(String.t(), map()) :: Ecto.Changeset.t()
  def changeset(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    SessionLog.create_changeset(
      %SessionLog{
        user_id: user_id,
        step_execution_id:
          Map.get(attrs, "step_execution_id") || Map.get(attrs, :step_execution_id),
        project_id: Map.get(attrs, "project_id") || Map.get(attrs, :project_id)
      },
      attrs
    )
  end

  @doc """
  Persist a valid log and its usage counters in one transaction.

  A newly inserted log is folded into `rollup` and the execution counters are
  written from the result. Redelivery of an identical event returns the stored
  row and leaves the rollup unchanged. `opts` are passed to the transaction.
  """
  @spec persist(Ecto.Changeset.t(), UsageRollups.t(), keyword()) ::
          {:ok, SessionLog.t(), UsageRollups.t()}
          | {:error, Ecto.Changeset.t() | :event_identity_conflict | :not_found}
  def persist(changeset, rollup, opts \\ [])

  def persist(%Ecto.Changeset{valid?: true} = changeset, rollup, opts) do
    log = Ecto.Changeset.apply_changes(changeset)

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:execution, fn _repo, _changes ->
        lock_execution(log.step_execution_id, log.user_id, log.project_id)
      end)
      |> Ecto.Multi.run(:log, fn _repo, _changes -> insert_immutable_event(changeset) end)
      |> Ecto.Multi.run(:rollup, fn _repo, %{execution: execution, log: log} ->
        rollup_inserted(execution, log, rollup)
      end)
      |> Repo.transaction(opts)

    case result do
      {:ok, %{log: {log, _inserted?}, rollup: rollup}} -> {:ok, log, rollup}
      {:error, _operation, reason, _changes} -> {:error, reason}
    end
  end

  def persist(%Ecto.Changeset{} = changeset, _rollup, _opts), do: {:error, changeset}

  @doc "All harness logs for an execution, oldest first."
  @spec harness_logs(String.t(), keyword()) :: [SessionLog.t()]
  def harness_logs(step_execution_id, opts \\ []) do
    SessionLog
    |> where([log], log.step_execution_id == ^step_execution_id and log.format == "harness")
    |> order_by([log], asc: log.inserted_at, asc: log.id)
    |> Repo.all(opts)
  end

  defp rollup_inserted(execution, {log, true}, rollup) do
    rollup = UsageRollups.add(rollup, log)

    with {:ok, _execution} <-
           execution
           |> StepExecution.update_changeset(UsageRollups.attrs(rollup))
           |> Repo.update() do
      {:ok, rollup}
    end
  end

  defp rollup_inserted(_execution, {_log, false}, rollup), do: {:ok, rollup}

  defp lock_execution(execution_id, user_id, project_id) do
    query =
      from execution in StepExecution,
        where:
          execution.id == ^execution_id and execution.user_id == ^user_id and
            execution.project_id == ^project_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :not_found}
      execution -> {:ok, execution}
    end
  end

  defp insert_immutable_event(changeset) do
    step_execution_id = Ecto.Changeset.get_field(changeset, :step_execution_id)
    logical_key = Ecto.Changeset.get_field(changeset, :logical_key)
    content = Ecto.Changeset.get_field(changeset, :content)
    format = Ecto.Changeset.get_field(changeset, :format)

    with {:ok, inserted} <-
           Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target:
               {:unsafe_fragment,
                "(step_execution_id, logical_key) WHERE logical_key IS NOT NULL"}
           ),
         %SessionLog{} = persisted <-
           Repo.one(
             from(log in SessionLog,
               where:
                 log.step_execution_id == ^step_execution_id and log.logical_key == ^logical_key
             )
           ) do
      if persisted.content == content and persisted.format == format do
        {:ok, {persisted, persisted.id == inserted.id}}
      else
        {:error, :event_identity_conflict}
      end
    end
  end
end
