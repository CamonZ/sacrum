defmodule SacrumWeb.SessionLogController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.SessionLogs

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"step_execution_id" => execution_id}) do
    user = conn.assigns.current_user
    logs = SessionLogs.list_by(user.id, conditions: [step_execution_id: execution_id])

    render(conn, :index, logs: logs)
  end
end
