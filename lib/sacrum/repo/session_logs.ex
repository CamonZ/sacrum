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
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.SessionLog
  alias Sacrum.SessionLogRollups

  @harness_format "harness"

  @doc """
  Insert a new session log with user_id.
  Extracts step_execution_id and project_id from attrs.
  """
  @spec insert(String.t(), map()) ::
          {:ok, SessionLog.t()} | {:error, Ecto.Changeset.t() | :event_identity_conflict}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    step_execution_id = Map.get(attrs, "step_execution_id") || Map.get(attrs, :step_execution_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    Repo.transaction(fn ->
      changeset =
        SessionLog.create_changeset(
          %SessionLog{
            user_id: user_id,
            step_execution_id: step_execution_id,
            project_id: project_id
          },
          attrs
        )

      logical_key = Ecto.Changeset.get_field(changeset, :logical_key)
      format = Ecto.Changeset.get_field(changeset, :format)

      with {:ok, log} <-
             insert_or_upsert(changeset, logical_key, format),
           {:ok, _execution} <- rollup_step_execution(log, logical_key) do
        log
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_or_upsert(changeset, "harness:" <> _event_id, _format),
    do: insert_immutable_event(changeset)

  defp insert_or_upsert(changeset, logical_key, @harness_format) when is_binary(logical_key),
    do: insert_immutable_event(changeset)

  defp insert_or_upsert(changeset, logical_key, _format) when is_binary(logical_key),
    do: upsert_by_logical_key(changeset)

  defp insert_or_upsert(changeset, _logical_key, _format), do: Repo.insert(changeset)

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

  defp upsert_by_logical_key(changeset) do
    Repo.insert(changeset,
      on_conflict: {:replace, [:content, :format, :updated_at]},
      conflict_target:
        {:unsafe_fragment, "(step_execution_id, logical_key) WHERE logical_key IS NOT NULL"},
      returning: true
    )
  end

  defp rollup_step_execution(log, logical_key) when is_binary(logical_key),
    do: SessionLogRollups.refresh_step_execution(log)

  defp rollup_step_execution(log, _logical_key), do: SessionLogRollups.rollup_step_execution(log)

  defoverridable insert: 2
end
