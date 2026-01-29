defmodule SacrumWeb.StepExecutionController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task

  action_fallback SacrumWeb.FallbackController

  defp authorize_project(project_id, user) do
    with {:ok, %Project{} = project} <- Projects.get(project_id),
         true <- project.user_id == user.id do
      {:ok, project}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp find_task(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> Tasks.get(id)
      :error -> Tasks.get_by_short_id(id)
    end
  end

  def index(conn, %{"project_id" => project_id, "task_id" => task_id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- find_task(task_id) do
      executions = StepExecutions.list_for_task(task.id)
      render(conn, :index, executions: executions)
    end
  end

  def show(conn, %{"project_id" => project_id, "id" => id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, execution} <- StepExecutions.get(id) do
      render(conn, :show, execution: execution)
    end
  end
end
