defmodule SacrumWeb.TaskWorkflowController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Repo.TaskWorkflows

  action_fallback SacrumWeb.FallbackController

  def assign(conn, %{"task_id" => task_id, "workflow_id" => workflow_id}) do
    user = conn.assigns.current_user

    with {:ok, %Sacrum.Repo.Schemas.Task{} = task} <- Tasks.find(user.id, task_id),
         {:ok, workflow} <- Workflows.get_by(user.id, conditions: [id: workflow_id]),
         {:ok, %Sacrum.Repo.Schemas.Task{} = updated} <-
           TaskWorkflows.assign_workflow(task, workflow) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    end
  end

  def unassign(conn, %{"task_id" => task_id}) do
    user = conn.assigns.current_user

    with {:ok, %Sacrum.Repo.Schemas.Task{} = task} <- Tasks.find(user.id, task_id),
         {:ok, %Sacrum.Repo.Schemas.Task{} = updated} <- TaskWorkflows.unassign_workflow(task) do
      conn
      |> put_view(json: SacrumWeb.TaskJSON)
      |> render(:show, task: updated)
    end
  end

  def move_to(conn, %{"task_id" => task_id, "step_id" => step_id}) do
    user = conn.assigns.current_user

    with {:ok, %Sacrum.Repo.Schemas.Task{} = task} <- Tasks.find(user.id, task_id),
         {:ok, %Sacrum.Repo.Schemas.Task{} = updated} <- TaskWorkflows.move_to_step(task, step_id) do
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
