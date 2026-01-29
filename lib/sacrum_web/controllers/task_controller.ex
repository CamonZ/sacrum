defmodule SacrumWeb.TaskController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task

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

  def index(conn, %{"project_id" => project_id} = params) do
    with {:ok, project} <- authorize_project(project_id, conn.assigns.current_user) do
      opts =
        [project_id: project.id]
        |> maybe_add_filter(:level, params["level"])
        |> maybe_add_filter(:parent_id, params["parent_id"])
        |> maybe_add_filter(:search, params["search"])
        |> maybe_add_blocked_filter(params["blocked"])
        |> maybe_add_filter(:status, params["status"])
        |> maybe_add_tags_filter(params["tags"])
        |> maybe_add_root_only_filter(params["root_only"])
        |> maybe_add_filter(:workflow_id, params["workflow_id"])

      tasks = Tasks.list_tasks(opts)
      render(conn, :index, tasks: tasks)
    end
  end

  def show(conn, %{"project_id" => project_id, "id" => id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- find_task(id) do
      render(conn, :show, task: task)
    end
  end

  def create(conn, %{"project_id" => project_id} = params) do
    with {:ok, project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- Tasks.insert(project, params) do
      conn
      |> put_status(:created)
      |> render(:show, task: task)
    end
  end

  def update(conn, %{"project_id" => project_id, "id" => id} = params) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- find_task(id),
         {:ok, %Task{} = updated} <- Tasks.update(task, params) do
      render(conn, :show, task: updated)
    end
  end

  def delete(conn, %{"project_id" => project_id, "id" => id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- find_task(id),
         {:ok, _} <- Tasks.delete(task) do
      send_resp(conn, :no_content, "")
    end
  end

  # Allow lookup by UUID or short_id
  defp find_task(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> Tasks.get(id)
      :error -> Tasks.get_by_short_id(id)
    end
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_add_blocked_filter(opts, "false"), do: Keyword.put(opts, :blocked, false)
  defp maybe_add_blocked_filter(opts, _), do: opts

  defp maybe_add_tags_filter(opts, nil), do: opts
  defp maybe_add_tags_filter(opts, ""), do: opts

  defp maybe_add_tags_filter(opts, tags) when is_list(tags),
    do: Keyword.put(opts, :tags, tags)

  defp maybe_add_tags_filter(opts, tags) when is_binary(tags),
    do: Keyword.put(opts, :tags, String.split(tags, ",", trim: true))

  defp maybe_add_root_only_filter(opts, "true"), do: Keyword.put(opts, :root_only, true)
  defp maybe_add_root_only_filter(opts, _), do: opts
end
