defmodule SacrumWeb.TaskRelationshipController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskHierarchy
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task

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

  def set_parent(conn, %{
        "project_id" => project_id,
        "task_id" => task_id,
        "parent_id" => parent_id
      }) do
    with {:ok, task} <- authorize_task(project_id, task_id, conn.assigns.current_user),
         {:ok, %Task{} = parent} <- Tasks.get(parent_id),
         {:ok, _hierarchy} <- TaskHierarchy.set_parent(task, parent) do
      render(conn, :show, task: Sacrum.Repo.get!(Task, task.id))
    end
  end

  def set_parent(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{parent_id: ["is required"]}})
  end

  def remove_parent(conn, %{"project_id" => project_id, "task_id" => task_id}) do
    with {:ok, task} <- authorize_task(project_id, task_id, conn.assigns.current_user),
         {:ok, _} <- TaskHierarchy.remove_parent(task) do
      send_resp(conn, :no_content, "")
    end
  end

  def create(conn, %{
        "project_id" => project_id,
        "task_id" => task_id,
        "depends_on_id" => depends_on_id
      }) do
    with {:ok, task} <- authorize_task(project_id, task_id, conn.assigns.current_user),
         {:ok, %Task{} = depends_on} <- Tasks.get(depends_on_id),
         {:ok, _dep} <- TaskDependencies.add_dependency(task, depends_on) do
      conn
      |> put_status(:created)
      |> json(%{data: %{task_id: task.id, depends_on_id: depends_on.id}})
    else
      {:error, :different_projects} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{depends_on_id: ["must be in the same project"]}})

      {:error, :self_dependency} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{depends_on_id: ["a task cannot depend on itself"]}})

      {:error, :circular_dependency} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{depends_on_id: ["would create a circular dependency"]}})

      error ->
        error
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{depends_on_id: ["is required"]}})
  end

  def delete(conn, %{"project_id" => project_id, "task_id" => task_id, "id" => depends_on_id}) do
    with {:ok, task} <- authorize_task(project_id, task_id, conn.assigns.current_user),
         {:ok, %Task{} = depends_on} <- Tasks.get(depends_on_id),
         {:ok, _} <- TaskDependencies.remove_dependency(task, depends_on) do
      send_resp(conn, :no_content, "")
    end
  end

  def blockers(conn, %{"project_id" => project_id, "task_id" => task_id}) do
    with {:ok, task} <- authorize_task(project_id, task_id, conn.assigns.current_user) do
      blockers = TaskDependencies.get_blockers(task)
      render(conn, :index, tasks: blockers)
    end
  end
end
