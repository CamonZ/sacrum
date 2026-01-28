defmodule SacrumWeb.WorkflowController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Workflow

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
      workflows = Workflows.list(project)
      render(conn, :index, workflows: workflows)
    end
  end

  def show(conn, %{"project_id" => project_id, "id" => id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Workflow{} = workflow} <- Workflows.get(id) do
      render(conn, :show, workflow: workflow)
    end
  end

  def create(conn, %{"project_id" => project_id} = params) do
    with {:ok, project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Workflow{} = workflow} <- Workflows.insert(project, params) do
      conn
      |> put_status(:created)
      |> render(:show, workflow: workflow)
    end
  end

  def update(conn, %{"project_id" => project_id, "id" => id} = params) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Workflow{} = workflow} <- Workflows.get(id),
         {:ok, %Workflow{} = updated} <- Workflows.update(workflow, params) do
      render(conn, :show, workflow: updated)
    end
  end

  def delete(conn, %{"project_id" => project_id, "id" => id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Workflow{} = workflow} <- Workflows.get(id),
         {:ok, _} <- Workflows.delete(workflow) do
      send_resp(conn, :no_content, "")
    end
  end
end
