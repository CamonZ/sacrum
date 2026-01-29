defmodule SacrumWeb.WorkflowStepController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowStep

  action_fallback SacrumWeb.FallbackController

  defp authorize_workflow(project_id, workflow_id, user) do
    with {:ok, %Project{} = project} <- Projects.get(project_id),
         true <- project.user_id == user.id,
         {:ok, %Workflow{} = workflow} <- Workflows.get(workflow_id),
         true <- workflow.project_id == project.id do
      {:ok, workflow}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  def index(conn, %{"project_id" => project_id, "workflow_id" => workflow_id}) do
    with {:ok, workflow} <- authorize_workflow(project_id, workflow_id, conn.assigns.current_user) do
      steps = WorkflowSteps.list(workflow)
      render(conn, :index, steps: steps)
    end
  end

  def create(conn, %{"project_id" => project_id, "workflow_id" => workflow_id} = params) do
    with {:ok, workflow} <- authorize_workflow(project_id, workflow_id, conn.assigns.current_user),
         {:ok, %WorkflowStep{} = step} <- WorkflowSteps.insert(workflow, params) do
      conn
      |> put_status(:created)
      |> render(:show, step: step)
    end
  end

  def update(
        conn,
        %{"project_id" => project_id, "workflow_id" => workflow_id, "id" => id} = params
      ) do
    with {:ok, _workflow} <-
           authorize_workflow(project_id, workflow_id, conn.assigns.current_user),
         {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get(id),
         {:ok, %WorkflowStep{} = updated} <- WorkflowSteps.update(step, params) do
      render(conn, :show, step: updated)
    end
  end

  def delete(conn, %{"project_id" => project_id, "workflow_id" => workflow_id, "id" => id}) do
    with {:ok, _workflow} <-
           authorize_workflow(project_id, workflow_id, conn.assigns.current_user),
         {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get(id),
         {:ok, _} <- WorkflowSteps.delete(step) do
      send_resp(conn, :no_content, "")
    end
  end

  # Flat routes

  def show_flat(conn, %{"id" => id}) do
    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get(id),
         :ok <- authorize_step_owner(step, conn.assigns.current_user) do
      render(conn, :show, step: step)
    end
  end

  def update_flat(conn, %{"id" => id} = params) do
    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get(id),
         :ok <- authorize_step_owner(step, conn.assigns.current_user),
         {:ok, %WorkflowStep{} = updated} <- WorkflowSteps.update(step, params) do
      render(conn, :show, step: updated)
    end
  end

  def delete_flat(conn, %{"id" => id}) do
    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get(id),
         :ok <- authorize_step_owner(step, conn.assigns.current_user),
         {:ok, _} <- WorkflowSteps.delete(step) do
      send_resp(conn, :no_content, "")
    end
  end

  defp authorize_step_owner(%WorkflowStep{} = step, user) do
    step = Sacrum.Repo.preload(step, workflow: :project)

    if step.workflow && step.workflow.project && step.workflow.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
    end
  end
end
