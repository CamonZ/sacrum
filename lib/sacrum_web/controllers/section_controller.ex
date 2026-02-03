defmodule SacrumWeb.SectionController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Sections
  alias Sacrum.Repo.Schemas.TaskSection

  action_fallback SacrumWeb.FallbackController

  def create(conn, %{"task_id" => task_id} = params) do
    user = conn.assigns.current_user

    with {:ok, task} <- Tasks.find(user.id, task_id),
         {:ok, %TaskSection{} = section} <- Sections.insert(task, params) do
      conn
      |> put_status(:created)
      |> render(:show, section: section)
    end
  end

  def delete(conn, %{"task_id" => task_id, "id" => id}) do
    user = conn.assigns.current_user

    with {:ok, _task} <- Tasks.find(user.id, task_id),
         {:ok, %TaskSection{} = section} <- Sections.get_by(user.id, conditions: [id: id]),
         {:ok, _} <- Sections.delete(section) do
      send_resp(conn, :no_content, "")
    end
  end
end
