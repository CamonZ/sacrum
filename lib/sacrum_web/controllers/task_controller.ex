defmodule SacrumWeb.TaskController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskHierarchy
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task

  action_fallback SacrumWeb.FallbackController

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

  def ready(conn, %{"project_id" => project_id}) do
    with {:ok, project} <- authorize_project(project_id, conn.assigns.current_user) do
      tasks = Tasks.ready(project.id)
      render(conn, :index, tasks: tasks)
    end
  end

  def tree(conn, %{"task_id" => task_id}) do
    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user) do
      tree = TaskHierarchy.build_tree(task)
      render(conn, :tree, tree: tree)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Task{} = task} <- find_task(id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user) do
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

  def update(conn, %{"id" => id} = params) do
    with {:ok, %Task{} = task} <- find_task(id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user),
         {:ok, %Task{} = updated} <- Tasks.update(task, params),
         :ok <- handle_nested_updates(updated, params) do
      render(conn, :show, task: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Task{} = task} <- find_task(id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user),
         {:ok, _} <- Tasks.delete(task) do
      send_resp(conn, :no_content, "")
    end
  end

  defp authorize_project(project_id, user) do
    with {:ok, %Project{} = project} <- Projects.get(project_id),
         true <- project.user_id == user.id do
      {:ok, project}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp authorize_task_owner(%Task{} = task, user) do
    task = Sacrum.Repo.preload(task, :project)

    if task.project && task.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
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

  defp handle_nested_updates(task, params) do
    with :ok <- maybe_set_parent(task, params),
         :ok <- maybe_set_dependencies(task, params) do
      :ok
    end
  end

  defp maybe_set_parent(_task, %{"parent_id" => nil}) do
    :ok
  end

  defp maybe_set_parent(task, %{"parent_id" => parent_id}) do
    case Tasks.get(parent_id) do
      {:ok, parent} ->
        # Remove existing parent first if any
        Sacrum.Repo.TaskHierarchy.remove_parent(task)

        case Sacrum.Repo.TaskHierarchy.set_parent(task, parent) do
          {:ok, _} -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  defp maybe_set_parent(_task, _params), do: :ok

  defp maybe_set_dependencies(task, %{"depends_on_ids" => ids}) when is_list(ids) do
    # Get current dependencies
    current = Sacrum.Repo.TaskDependencies.get_direct_blockers(task)
    current_ids = MapSet.new(Enum.map(current, & &1.id))
    desired_ids = MapSet.new(ids)

    # Remove dependencies that are no longer desired
    to_remove = MapSet.difference(current_ids, desired_ids)

    for id <- to_remove do
      case Tasks.get(id) do
        {:ok, dep} -> Sacrum.Repo.TaskDependencies.remove_dependency(task, dep)
        _ -> :ok
      end
    end

    # Add new dependencies
    to_add = MapSet.difference(desired_ids, current_ids)

    results =
      for id <- to_add do
        case Tasks.get(id) do
          {:ok, dep} -> Sacrum.Repo.TaskDependencies.add_dependency(task, dep)
          error -> error
        end
      end

    case Enum.find(results, fn
           {:error, _} -> true
           _ -> false
         end) do
      nil -> :ok
      error -> error
    end
  end

  defp maybe_set_dependencies(_task, _params), do: :ok
end
