defmodule SacrumWeb.SessionLogController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Accounts.SessionLogs

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"step_execution_id" => execution_id}) do
    user = conn.assigns.current_user

    with {:ok, _execution} <- StepExecutions.get_by(user.id, id: execution_id) do
      logs = SessionLogs.list_by(user.id, step_execution_id: execution_id)
      render(conn, :index, logs: logs)
    end
  end
end
