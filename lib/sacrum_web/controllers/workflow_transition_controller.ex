defmodule SacrumWeb.WorkflowTransitionController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.WorkflowTransitions
  alias Sacrum.Repo.Schemas.WorkflowTransition

  action_fallback SacrumWeb.FallbackController

  def create(conn, %{"workflow_id" => from_workflow_id} = params) do
    user = conn.assigns.current_user

    params =
      params
      |> Map.put("from_workflow_id", from_workflow_id)

    with {:ok, from_workflow} <- Workflows.get_by(user.id, conditions: [id: from_workflow_id]),
         params = Map.put(params, "project_id", from_workflow.project_id),
         {:ok, %WorkflowTransition{} = transition} <- WorkflowTransitions.insert(user.id, params) do
      conn
      |> put_status(:created)
      |> render(:show, transition: transition)
    end
  end

  def delete(conn, %{"workflow_id" => from_workflow_id, "id" => id}) do
    user = conn.assigns.current_user

    with {:ok, _from_workflow} <- Workflows.get_by(user.id, conditions: [id: from_workflow_id]),
         {:ok, %WorkflowTransition{} = transition} <-
           WorkflowTransitions.get_by(user.id,
             conditions: [id: id, from_workflow_id: from_workflow_id]
           ),
         {:ok, _} <- WorkflowTransitions.delete(transition) do
      send_resp(conn, :no_content, "")
    end
  end
end
