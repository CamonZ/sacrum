defmodule SacrumWeb.CodeRefController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.CodeRefs
  alias Sacrum.Repo.Schemas.CodeRef

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"task_id" => task_id}) do
    user = conn.assigns.current_user

    with {:ok, task} <- Tasks.get_by(user.id, id: task_id) do
      refs = CodeRefs.list_by(user.id, task_id: task.id)
      render(conn, :index, code_refs: refs)
    end
  end

  def create(conn, %{"task_id" => task_id} = params) do
    user = conn.assigns.current_user

    with {:ok, task} <- Tasks.get_by(user.id, id: task_id),
         {:ok, %CodeRef{} = ref} <- CodeRefs.insert_for_task(user.id, task.id, params) do
      conn
      |> put_status(:created)
      |> render(:show, code_ref: ref)
    end
  end

  def delete(conn, %{"task_id" => task_id, "id" => id}) do
    user = conn.assigns.current_user

    with {:ok, _task} <- Tasks.get_by(user.id, id: task_id),
         {:ok, %CodeRef{} = ref} <- CodeRefs.get_by(user.id, id: id),
         {:ok, _} <- CodeRefs.delete(ref) do
      send_resp(conn, :no_content, "")
    end
  end
end
