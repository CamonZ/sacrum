defmodule Sacrum.Repo.SessionLogs do
  @moduledoc """
  Operations for session logs within step executions.

  ## Error Contract

  - `get/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `get!/1` returns log or raises
  - `get_by/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `all/0` returns `[log]`
  - `insert/1` returns `{:ok, log}` or `{:error, changeset}`
  - `update/2` returns `{:ok, log}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.SessionLog

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.SessionLog
  alias Sacrum.SessionLogRollups

  @doc """
  Insert a new session log with user_id.
  Extracts step_execution_id and project_id from attrs.
  """
  @spec insert(String.t(), map()) :: {:ok, SessionLog.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    step_execution_id = Map.get(attrs, "step_execution_id") || Map.get(attrs, :step_execution_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    Repo.transaction(fn ->
      with {:ok, log} <-
             %SessionLog{
               user_id: user_id,
               step_execution_id: step_execution_id,
               project_id: project_id
             }
             |> SessionLog.create_changeset(attrs)
             |> Repo.insert(),
           {:ok, _execution} <- SessionLogRollups.rollup_step_execution(log) do
        log
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Update an existing session log and refresh the owning step execution rollups.
  """
  @spec update(SessionLog.t(), map()) :: {:ok, SessionLog.t()} | {:error, Ecto.Changeset.t()}
  def update(%SessionLog{} = log, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, updated_log} <-
             log
             |> SessionLog.update_changeset(attrs)
             |> Repo.update(),
           {:ok, _execution} <- SessionLogRollups.recompute_step_execution(updated_log) do
        updated_log
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defoverridable insert: 2
end
