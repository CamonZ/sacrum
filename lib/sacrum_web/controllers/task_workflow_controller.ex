defmodule SacrumWeb.TaskWorkflowController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.TaskWorkflows
  alias Sacrum.Repo.Schemas.Task

  action_fallback SacrumWeb.FallbackController

  defp find_task(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> Tasks.get(id)
      :error -> Tasks.get_by_short_id(id)
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

  def assign(conn, %{"task_id" => task_id, "workflow_id" => workflow_id}) do
    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user),
         {:ok, workflow} <- Workflows.get(workflow_id),
         {:ok, %Task{} = updated} <- TaskWorkflows.assign_workflow(task, workflow) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    end
  end

  def unassign(conn, %{"task_id" => task_id}) do
    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user),
         {:ok, %Task{} = updated} <- TaskWorkflows.unassign_workflow(task) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    end
  end

  def advance(conn, %{"task_id" => task_id}) do
    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user),
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

  def retreat(conn, %{"task_id" => task_id}) do
    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user),
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

  def reject(conn, %{"task_id" => task_id} = params) do
    reason = params["reason"] || params["rejection_reason"]

    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user),
         {:ok, %Task{} = updated} <- TaskWorkflows.reject_task(task, reason) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    else
      {:error, :no_workflow} ->
        {:error, :unprocessable_entity, "task has no workflow assigned"}

      {:error, :no_rejected_step} ->
        {:error, :unprocessable_entity, "workflow has no rejected step or on_reject_workflow"}

      other ->
        other
    end
  end
end
