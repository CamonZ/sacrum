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

  def create(conn, %{"project_id" => _project_id} = params) do
    # project_id passed as query/body param for auth
    with {:ok, _project} <- authorize_project(params["project_id"], conn.assigns.current_user),
         {:ok, %WorkflowTransition{} = transition} <- WorkflowTransitions.insert(params) do
      conn
      |> put_status(:created)
      |> render(:show, transition: transition)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %WorkflowTransition{} = transition} <- WorkflowTransitions.get(id),
         transition <- Sacrum.Repo.preload(transition, from_workflow: :project),
         :ok <- authorize_transition_owner(transition, conn.assigns.current_user),
         {:ok, _} <- WorkflowTransitions.delete(transition) do
      send_resp(conn, :no_content, "")
    end
  end

  defp authorize_transition_owner(%WorkflowTransition{} = transition, user) do
    if transition.from_workflow && transition.from_workflow.project &&
         transition.from_workflow.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
    end
  end
end
