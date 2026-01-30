defmodule SacrumWeb.ProjectController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Schemas.Project

  action_fallback SacrumWeb.FallbackController

  def index(conn, _params) do
    user = conn.assigns.current_user
    projects = Projects.list_by(user.id)
    render(conn, :index, projects: projects)
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, %Project{} = project} <- Projects.get_by(user.id, id: id) do
      render(conn, :show, project: project)
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, %Project{} = project} <- Projects.insert(user.id, params) do
      conn
      |> put_status(:created)
      |> render(:show, project: project)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, %Project{} = project} <- Projects.get_by(user.id, id: id),
         {:ok, %Project{} = updated} <- Projects.update(project, params) do
      render(conn, :show, project: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, %Project{} = project} <- Projects.get_by(user.id, id: id),
         {:ok, _} <- Projects.delete(project) do
      send_resp(conn, :no_content, "")
    end
  end
end
