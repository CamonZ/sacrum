defmodule SacrumWeb.TaskWorkflowController do
  use SacrumWeb, :controller

  import SacrumWeb.Helpers.Authorization

  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.TaskWorkflows
  alias Sacrum.Repo.Schemas.Task

  action_fallback SacrumWeb.FallbackController

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

  def move_to(conn, %{"task_id" => task_id, "step_id" => step_id}) do
    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user),
         {:ok, %Task{} = updated} <- TaskWorkflows.move_to_step(task, step_id) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    else
      {:error, :no_workflow} ->
        {:error, :unprocessable_entity, "task has no workflow assigned"}

      {:error, :no_current_step} ->
        {:error, :unprocessable_entity, "task has no current workflow step"}

      {:error, :step_not_found} ->
        {:error, :unprocessable_entity, "step not found"}

      {:error, :step_not_in_workflow} ->
        {:error, :unprocessable_entity, "step does not belong to the task's current workflow"}

      {:error, :no_transition} ->
        {:error, :unprocessable_entity, "no valid transition from current step to target step"}

      other ->
        other
    end
  end
end
