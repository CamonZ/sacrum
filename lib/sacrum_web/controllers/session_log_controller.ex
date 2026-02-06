defmodule SacrumWeb.SessionLogController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.SessionLogs
  alias Sacrum.Repo.StepExecutions

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"step_execution_id" => execution_id}) do
    user = conn.assigns.current_user
    logs = SessionLogs.list_by(user.id, conditions: [step_execution_id: execution_id])

    render(conn, :index, logs: logs)
  end

  def create(conn, %{"step_execution_id" => execution_id} = params) do
    user = conn.assigns.current_user

    with {:ok, execution} <- StepExecutions.get(execution_id),
         {:ok, _} <- verify_execution_owner(user.id, execution),
         project_id = execution.project_id,
         {:ok, log} <-
           SessionLogs.insert(user.id, Map.merge(params, %{"project_id" => project_id})) do
      conn
      |> put_status(:created)
      |> render(:show, log: log)
    end
  end

  defp verify_execution_owner(user_id, execution) do
    if execution.user_id == user_id do
      {:ok, execution}
    else
      {:error, :forbidden}
    end
  end
end
