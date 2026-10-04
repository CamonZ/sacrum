defmodule Sacrum.Repo.SessionLogs do
  @moduledoc """
  Operations for session logs within step executions.

  ## Error Contract

  - `get/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `get!/1` returns log or raises
  - `get_by/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `all/0` returns `[log]`
  - `insert/2` returns `{:ok, log}`, `{:error, changeset}`, or
    `{:error, :event_identity_conflict}` for an immutable harness event key

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.SessionLog

  import Ecto.Query
  alias Sacrum.Accounts.SessionLogs.UsageRollups
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution}

  @doc """
  Insert a new session log with user_id.
  Extracts step_execution_id and project_id from attrs.
  """
  @spec insert(String.t(), map()) ::
          {:ok, SessionLog.t()}
          | {:error, Ecto.Changeset.t() | :event_identity_conflict | :not_found}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    step_execution_id = Map.get(attrs, "step_execution_id") || Map.get(attrs, :step_execution_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    changeset =
      SessionLog.create_changeset(
        %SessionLog{
          user_id: user_id,
          step_execution_id: step_execution_id,
          project_id: project_id
        },
        attrs
      )

    if changeset.valid? do
      result =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:execution, fn _repo, _changes ->
          lock_execution(step_execution_id, user_id, project_id)
        end)
        |> Ecto.Multi.run(:log, fn _repo, _changes -> insert_immutable_event(changeset) end)
        |> Ecto.Multi.run(:rollup, fn _repo, %{execution: execution} ->
          UsageRollups.refresh_step_execution(execution)
        end)
        |> Repo.transaction()

      case result do
        {:ok, %{log: log}} -> {:ok, log}
        {:error, _operation, reason, _changes} -> {:error, reason}
      end
    else
      {:error, changeset}
    end
  end

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

    with {:ok, _log} <-
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
        {:ok, persisted}
      else
        {:error, :event_identity_conflict}
      end
    end
  end

  defoverridable insert: 2
end
