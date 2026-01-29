defmodule SacrumWeb.WorkflowTransitionController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.WorkflowTransitions
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.WorkflowTransition

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

  def index(conn, %{"project_id" => project_id}) do
    with {:ok, project} <- authorize_project(project_id, conn.assigns.current_user) do
      transitions = WorkflowTransitions.list_for_project(project.id)
      render(conn, :index, transitions: transitions)
    end
  end

  def create(conn, %{"project_id" => project_id} = params) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %WorkflowTransition{} = transition} <- WorkflowTransitions.insert(params) do
      conn
      |> put_status(:created)
      |> render(:show, transition: transition)
    end
  end

  def delete(conn, %{"project_id" => project_id, "id" => id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %WorkflowTransition{} = transition} <- WorkflowTransitions.get(id),
         {:ok, _} <- WorkflowTransitions.delete(transition) do
      send_resp(conn, :no_content, "")
    end
  end
end
