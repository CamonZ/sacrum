defmodule SacrumWeb.ProjectController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Schemas.Project

  action_fallback SacrumWeb.FallbackController

  def index(conn, _params) do
    projects = Projects.list(conn.assigns.current_user)
    render(conn, :index, projects: projects)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Project{} = project} <- Projects.get(id),
         :ok <- authorize(project, conn.assigns.current_user) do
      render(conn, :show, project: project)
    end
  end

  def create(conn, params) do
    with {:ok, %Project{} = project} <- Projects.insert(conn.assigns.current_user, params) do
      conn
      |> put_status(:created)
      |> render(:show, project: project)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, %Project{} = project} <- Projects.get(id),
         :ok <- authorize(project, conn.assigns.current_user),
         {:ok, %Project{} = updated} <- Projects.update(project, params) do
      render(conn, :show, project: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Project{} = project} <- Projects.get(id),
         :ok <- authorize(project, conn.assigns.current_user),
         {:ok, _} <- Projects.delete(project) do
      send_resp(conn, :no_content, "")
    end
  end

  defp authorize(%Project{user_id: user_id}, %{id: user_id}), do: :ok
  defp authorize(_, _), do: {:error, :not_found}
end
