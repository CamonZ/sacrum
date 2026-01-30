defmodule Sacrum.Repo.StepExecutions do
  @moduledoc """
  Operations for step execution audit trail.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.Project

  def get(id) do
    case Repo.get(StepExecution, id) do
      nil -> {:error, :not_found}
      execution -> {:ok, execution}
    end
  end

  def list_for_task(task_id) when is_binary(task_id) do
    from(e in StepExecution,
      where: e.task_id == ^task_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  def insert(attrs) do
    %StepExecution{}
    |> StepExecution.create_changeset(attrs)
    |> Repo.insert()
    |> broadcast(:step_execution_created)
  end

  defp broadcast({:ok, execution}, event) do
    broadcast_event(execution, event)
    {:ok, execution}
  end

  defp broadcast({:error, _} = error, _event), do: error

  defp broadcast_event(execution, event) do
    task = Repo.get(Task, execution.task_id)

    if task do
      task = Repo.preload(task, :project)

      case task.project do
        %Project{slug: slug} ->
          apply(SacrumWeb.ProjectChannel, :"broadcast_#{event}", [slug, execution])

        _ ->
          :ok
      end
    else
      :ok
    end
  end
end
