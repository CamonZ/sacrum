defmodule SacrumWeb.WorkflowStepController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.WorkflowSteps
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.WorkflowStep

  action_fallback SacrumWeb.FallbackController

  def index(conn, params) do
    user = conn.assigns.current_user

    conditions =
      case Map.get(params, "workflow_id") do
        workflow_id when is_binary(workflow_id) ->
          [workflow_id: workflow_id]

        _ ->
          []
      end

    steps =
      WorkflowSteps.list_by(user.id, conditions: conditions)
      |> Repo.preload(:transitions)

    render(conn, :index, steps: steps)
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get_by(user.id, conditions: [id: id]) do
      step = Repo.preload(step, :transitions)
      render(conn, :show, step: step)
    end
  end

  def create(conn, %{"workflow_id" => workflow_id} = params) do
    user = conn.assigns.current_user

    with {:ok, workflow} <- Workflows.get_by(user.id, conditions: [id: workflow_id]),
         params = Map.put(params, "project_id", workflow.project_id),
         {:ok, %WorkflowStep{} = step} <-
           WorkflowSteps.insert(user.id, params) do
      conn
      |> put_status(:created)
      |> render(:show, step: step)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get_by(user.id, conditions: [id: id]),
         {:ok, %WorkflowStep{} = updated} <- WorkflowSteps.update(step, params),
         {:ok, %WorkflowStep{} = updated} <- maybe_sync_transitions(updated, params) do
      updated = Repo.preload(updated, :transitions)
      render(conn, :show, step: updated)
    else
      {:error, :duplicate_to_step_ids} ->
        {:error, :unprocessable_entity, "transitions array contains duplicate to_step_id entries"}

      {:error, :different_workflows} ->
        {:error, :unprocessable_entity, "to_step_id must belong to the same workflow"}

      other ->
        other
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, %WorkflowStep{} = step} <- WorkflowSteps.get_by(user.id, conditions: [id: id]),
         {:ok, _} <- WorkflowSteps.delete(step) do
      send_resp(conn, :no_content, "")
    end
  end

  defp maybe_sync_transitions(step, %{"transitions" => transitions}) when is_list(transitions) do
    case WorkflowSteps.sync_transitions(step, transitions) do
      {:ok, _transitions} -> {:ok, step}
      error -> error
    end
  end

  defp maybe_sync_transitions(step, _params), do: {:ok, step}
end
