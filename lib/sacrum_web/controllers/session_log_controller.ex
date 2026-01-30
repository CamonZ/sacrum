defmodule SacrumWeb.SessionLogController do
  use SacrumWeb, :controller

  import SacrumWeb.Helpers.Authorization

  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.SessionLogs

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"step_execution_id" => execution_id}) do
    with {:ok, execution} <- StepExecutions.get(execution_id),
         :ok <- authorize_execution_owner(execution, conn.assigns.current_user) do
      logs = SessionLogs.list_for_execution(execution_id)
      render(conn, :index, logs: logs)
    end
  end
end
