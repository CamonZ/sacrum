defmodule SacrumWeb.SessionLogController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.SessionLogs

  action_fallback SacrumWeb.FallbackController

  defp authorize_execution_owner(execution, user) do
    execution = Sacrum.Repo.preload(execution, workflow: :project)

    if execution.workflow && execution.workflow.project &&
         execution.workflow.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
    end
  end

  def index(conn, %{"step_execution_id" => execution_id}) do
    with {:ok, execution} <- StepExecutions.get(execution_id),
         :ok <- authorize_execution_owner(execution, conn.assigns.current_user) do
      logs = SessionLogs.list_for_execution(execution_id)
      render(conn, :index, logs: logs)
    end
  end
end
