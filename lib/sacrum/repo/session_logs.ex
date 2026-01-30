defmodule Sacrum.Repo.SessionLogs do
  @moduledoc """
  Operations for session logs within step executions.

  ## Error Contract

  - `get/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `insert/1` returns `{:ok, log}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.SessionLog
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Broadcaster

  def get(id) do
    case Repo.get(SessionLog, id) do
      nil -> {:error, :not_found}
      log -> {:ok, log}
    end
  end

  def list_for_execution(%StepExecution{id: execution_id}), do: list_for_execution(execution_id)

  def list_for_execution(execution_id) when is_binary(execution_id) do
    from(l in SessionLog,
      where: l.step_execution_id == ^execution_id,
      order_by: [asc: l.inserted_at]
    )
    |> Repo.all()
  end

  def insert(attrs) do
    %SessionLog{}
    |> SessionLog.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_session_log(:session_log_created)
  end
end
