defmodule Sacrum.Repo.SessionLogs do
  @moduledoc """
  Operations for session logs within step executions.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.SessionLog
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.Project

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
    |> broadcast()
  end

  defp broadcast({:ok, log}) do
    log = Repo.preload(log, :step_execution)

    if log.step_execution do
      task = Repo.get(Task, log.step_execution.task_id)

      if task do
        task = Repo.preload(task, :project)

        case task.project do
          %Project{slug: slug} ->
            SacrumWeb.ProjectChannel.broadcast_session_log_created(slug, log)

          _ ->
            :ok
        end
      end
    end

    {:ok, log}
  end

  defp broadcast({:error, _} = error), do: error
end
