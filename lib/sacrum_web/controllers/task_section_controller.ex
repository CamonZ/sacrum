defmodule SacrumWeb.TaskSectionController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  action_fallback SacrumWeb.FallbackController

  defp authorize_task(task_id, user) do
    with {:ok, %Task{} = task} <- Tasks.get(task_id),
         task <- Sacrum.Repo.preload(task, :project),
         true <- task.project && task.project.user_id == user.id do
      {:ok, task}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def index(conn, %{"task_id" => task_id}) do
    with {:ok, task} <- authorize_task(task_id, conn.assigns.current_user) do
      sections = TaskSections.list_for_task(task)
      render(conn, :index, sections: sections)
    end
  end

  def create(conn, %{"task_id" => task_id} = params) do
    with {:ok, task} <- authorize_task(task_id, conn.assigns.current_user),
         {:ok, %TaskSection{} = section} <- TaskSections.insert(task, params) do
      conn
      |> put_status(:created)
      |> render(:show, section: section)
    end
  end

  def update(conn, %{"task_id" => task_id, "id" => id} = params) do
    with {:ok, _task} <- authorize_task(task_id, conn.assigns.current_user),
         {:ok, %TaskSection{} = section} <- TaskSections.get(id),
         {:ok, %TaskSection{} = updated} <- TaskSections.update(section, params) do
      render(conn, :show, section: updated)
    end
  end

  def delete(conn, %{"task_id" => task_id, "id" => id}) do
    with {:ok, _task} <- authorize_task(task_id, conn.assigns.current_user),
         {:ok, %TaskSection{} = section} <- TaskSections.get(id),
         {:ok, _} <- TaskSections.delete(section) do
      send_resp(conn, :no_content, "")
    end
  end
end
