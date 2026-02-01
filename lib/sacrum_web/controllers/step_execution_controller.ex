defmodule SacrumWeb.StepExecutionController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.StepExecutions

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"task_id" => task_id}) do
    user = conn.assigns.current_user
    executions = StepExecutions.list_by(user.id, conditions: [task_id: task_id])

    render(conn, :index, executions: executions)
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, execution} <- StepExecutions.get_by(user.id, conditions: [id: id]) do
      render(conn, :show, execution: execution)
    end
  end
end
