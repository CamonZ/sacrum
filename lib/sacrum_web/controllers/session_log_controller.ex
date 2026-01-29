defmodule SacrumWeb.SessionLogController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.SessionLogs
  alias Sacrum.Repo.Schemas.Project

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

  def index(conn, %{"project_id" => project_id, "step_execution_id" => execution_id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, _execution} <- StepExecutions.get(execution_id) do
      logs = SessionLogs.list_for_execution(execution_id)
      render(conn, :index, logs: logs)
    end
  end
end
