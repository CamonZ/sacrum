defmodule Sacrum.Repo.SessionLogs do
  @moduledoc """
  Operations for session logs within step executions.

  ## Error Contract

  - `get/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `get!/1` returns log or raises
  - `get_by/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `all/0` returns `[log]`
  - `persist_batch/4` returns `:ok` or `{:error, reason}`; database errors raise

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.SessionLog

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  @row_fields ~w(id content format logical_key step_execution_id project_id user_id inserted_at updated_at)a

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
  Insert accepted harness logs and write the execution's usage counters in one
  transaction.

  The logs carry the ids and timestamps assigned when they were accepted. A log
  whose `(step_execution_id, logical_key)` is already stored is skipped. The
  counters are written without locking the execution row: the execution's
  ingestion process is their only writer. `opts` are passed to the transaction.
  """
  @spec persist_batch(String.t(), [SessionLog.t()], map(), keyword()) ::
          :ok | {:error, term()}
  def persist_batch(step_execution_id, logs, counters, opts \\ []) do
    rows = Enum.map(logs, &Map.take(&1, @row_fields))

    result =
      Repo.transaction(
        fn ->
          Repo.insert_all(SessionLog, rows,
            on_conflict: :nothing,
            conflict_target:
              {:unsafe_fragment, "(step_execution_id, logical_key) WHERE logical_key IS NOT NULL"}
          )

          Repo.update_all(
            from(execution in StepExecution, where: execution.id == ^step_execution_id),
            set: [{:updated_at, DateTime.utc_now()} | Enum.to_list(counters)]
          )
        end,
        opts
      )

    case result do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "All harness logs for an execution, oldest first."
  @spec harness_logs(String.t(), keyword()) :: [SessionLog.t()]
  def harness_logs(step_execution_id, opts \\ []) do
    SessionLog
    |> where([log], log.step_execution_id == ^step_execution_id and log.format == "harness")
    |> order_by([log], asc: log.inserted_at, asc: log.id)
    |> Repo.all(opts)
  end
end
