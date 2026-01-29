defmodule SacrumWeb.StepExecutionController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.Schemas.Task

  action_fallback SacrumWeb.FallbackController

  defp find_task(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> Tasks.get(id)
      :error -> Tasks.get_by_short_id(id)
    end
  end

  defp authorize_task_owner(%Task{} = task, user) do
    task = Sacrum.Repo.preload(task, :project)

    if task.project && task.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp authorize_execution_owner(execution, user) do
    execution = Sacrum.Repo.preload(execution, workflow: :project)

    if execution.workflow && execution.workflow.project &&
         execution.workflow.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
    end
  end

  def index(conn, %{"task_id" => task_id}) do
    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user) do
      executions = StepExecutions.list_for_task(task.id)
      render(conn, :index, executions: executions)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, execution} <- StepExecutions.get(id),
         :ok <- authorize_execution_owner(execution, conn.assigns.current_user) do
      render(conn, :show, execution: execution)
    end
  end
end
