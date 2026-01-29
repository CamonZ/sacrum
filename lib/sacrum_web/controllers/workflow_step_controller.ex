defmodule SacrumWeb.WorkflowStepController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowStep

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"workflow_id" => workflow_id}) do
    with {:ok, workflow} <- Workflows.get(workflow_id),
         :ok <- authorize_step_owner_via_workflow(workflow, conn.assigns.current_user) do
      steps = WorkflowSteps.list(workflow)
      render(conn, :index, steps: steps)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get(id),
         :ok <- authorize_step_owner(step, conn.assigns.current_user) do
      render(conn, :show, step: step)
    end
  end

  def create(conn, %{"workflow_id" => workflow_id} = params) do
    with {:ok, workflow} <- Workflows.get(workflow_id),
         :ok <- authorize_step_owner_via_workflow(workflow, conn.assigns.current_user),
         {:ok, %WorkflowStep{} = step} <- WorkflowSteps.insert(workflow, params) do
      conn
      |> put_status(:created)
      |> render(:show, step: step)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get(id),
         :ok <- authorize_step_owner(step, conn.assigns.current_user),
         {:ok, %WorkflowStep{} = updated} <- WorkflowSteps.update(step, params) do
      render(conn, :show, step: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get(id),
         :ok <- authorize_step_owner(step, conn.assigns.current_user),
         {:ok, _} <- WorkflowSteps.delete(step) do
      send_resp(conn, :no_content, "")
    end
  end

  defp authorize_step_owner_via_workflow(%Workflow{} = workflow, user) do
    workflow = Sacrum.Repo.preload(workflow, :project)

    if workflow.project && workflow.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
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
