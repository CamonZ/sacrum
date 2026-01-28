defmodule SacrumWeb.TaskWorkflowController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.TaskWorkflows
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

  defp find_task(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> Tasks.get(id)
      :error -> Tasks.get_by_short_id(id)
    end
  end

  def assign(conn, %{
        "project_id" => project_id,
        "task_id" => task_id,
        "workflow_id" => workflow_id
      }) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- find_task(task_id),
         {:ok, workflow} <- Workflows.get(workflow_id),
         {:ok, %Task{} = updated} <- TaskWorkflows.assign_workflow(task, workflow) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    end
  end

  def unassign(conn, %{"project_id" => project_id, "task_id" => task_id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- find_task(task_id),
         {:ok, %Task{} = updated} <- TaskWorkflows.unassign_workflow(task) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    end
  end

  def advance(conn, %{"project_id" => project_id, "task_id" => task_id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- find_task(task_id),
         {:ok, %Task{} = updated} <- TaskWorkflows.advance_step(task) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    else
      {:error, :no_current_step} ->
        {:error, :unprocessable_entity, "task has no current workflow step"}

      {:error, :no_transition} ->
        {:error, :unprocessable_entity, "no valid transition from current step"}

      other ->
        other
    end
  end

  def retreat(conn, %{"project_id" => project_id, "task_id" => task_id}) do
    with {:ok, _project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Task{} = task} <- find_task(task_id),
         {:ok, %Task{} = updated} <- TaskWorkflows.retreat_step(task) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    else
      {:error, :no_current_step} ->
        {:error, :unprocessable_entity, "task has no current workflow step"}

      {:error, :no_retreat_transition} ->
        {:error, :unprocessable_entity, "no valid retreat transition from current step"}

      other ->
        other
    end
  end
end
