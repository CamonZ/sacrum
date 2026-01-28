defmodule SacrumWeb.CodeRefController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.CodeRefs
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.CodeRef

  action_fallback SacrumWeb.FallbackController

  defp authorize_task(project_id, task_id, user) do
    with {:ok, %Project{} = project} <- Projects.get(project_id),
         true <- project.user_id == user.id,
         {:ok, %Task{} = task} <- Tasks.get(task_id),
         true <- task.project_id == project.id do
      {:ok, task}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def index(conn, %{"project_id" => project_id, "task_id" => task_id}) do
    with {:ok, task} <- authorize_task(project_id, task_id, conn.assigns.current_user) do
      refs = CodeRefs.list_for_task(task)
      render(conn, :index, code_refs: refs)
    end
  end

  def create(conn, %{"project_id" => project_id, "task_id" => task_id} = params) do
    with {:ok, task} <- authorize_task(project_id, task_id, conn.assigns.current_user),
         {:ok, %CodeRef{} = ref} <- CodeRefs.insert_for_task(task, params) do
      conn
      |> put_status(:created)
      |> render(:show, code_ref: ref)
    end
  end

  def delete(conn, %{"project_id" => project_id, "task_id" => task_id, "id" => id}) do
    with {:ok, _task} <- authorize_task(project_id, task_id, conn.assigns.current_user),
         {:ok, %CodeRef{} = ref} <- CodeRefs.get(id),
         {:ok, _} <- CodeRefs.delete(ref) do
      send_resp(conn, :no_content, "")
    end
  end
end
