defmodule SacrumWeb.TaskController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Projects
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Repo.TaskHierarchy
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.Schemas.Task

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"project_id" => project_id} = params) do
    user = conn.assigns.current_user

    conditions =
      [project_id: project_id]
      |> maybe_add_filter(:level, params["level"])
      |> maybe_add_filter(:parent_id, params["parent_id"])
      |> maybe_add_filter(:search, params["search"])
      |> maybe_add_blocked_filter(params["blocked"])
      |> maybe_add_filter(:status, params["status"])
      |> maybe_add_tags_filter(params["tags"])
      |> maybe_add_root_only_filter(params["root_only"])
      |> maybe_add_filter(:workflow_id, params["workflow_id"])

    tasks =
      Tasks.list_tasks(user.id, conditions: conditions, preloads: [:sections, :task_dependencies, :parent])

    render(conn, :index, tasks: tasks)
  end

  def ready(conn, %{"project_id" => project_id}) do
    user = conn.assigns.current_user

    tasks = Tasks.ready(user.id, project_id)
    render(conn, :index, tasks: tasks)
  end

  def tree(conn, %{"task_id" => task_id}) do
    user = conn.assigns.current_user

    with {:ok, %Task{} = task} <- Tasks.find(user.id, task_id) do
      tree = TaskHierarchy.build_tree(task)
      render(conn, :tree, tree: tree)
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, %Task{} = task} <- Tasks.find(user.id, id) do
      render(conn, :show, task: task)
    end
  end

  def create(conn, %{"project_id" => project_id} = params) do
    user = conn.assigns.current_user

    with {:ok, _project} <- Projects.get_by(user.id, conditions: [id: project_id]),
         {:ok, %Task{} = task} <- Tasks.insert(user.id, project_id, params) do
      conn
      |> put_status(:created)
      |> render(:show, task: task)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, %Task{} = task} <- Tasks.find(user.id, id),
         {:ok, %Task{} = updated} <- Tasks.update(task, params) do
      render(conn, :show, task: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, %Task{} = task} <- Tasks.find(user.id, id),
         {:ok, _} <- Tasks.delete(task) do
      send_resp(conn, :no_content, "")
    end
  end

  def blockers(conn, %{"task_id" => task_id}) do
    user = conn.assigns.current_user

    with {:ok, %Task{} = task} <- Tasks.find(user.id, task_id) do
      blockers = TaskDependencies.get_blockers(task)
      render(conn, :blockers, tasks: blockers)
    end
  end

  def path(conn, %{"task_id" => task_id, "to" => target_id}) do
    user = conn.assigns.current_user

    with {:ok, %Task{} = task} <- Tasks.find(user.id, task_id),
         {:ok, %Task{} = target} <- Tasks.get_by(user.id, conditions: [id: target_id]),
         {:ok, path_ids} <- TaskDependencies.find_path(task, target) do
      json(conn, %{data: %{path: path_ids}})
    end
  end

  def path(conn, %{"task_id" => task_id}) do
    with {:ok, %Task{} = _task} <- Tasks.find(conn.assigns.current_user.id, task_id) do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: %{to: ["query parameter is required"]}})
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
