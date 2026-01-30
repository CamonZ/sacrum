defmodule SacrumWeb.StepExecutionController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Repo.Schemas.Task

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"task_id" => task_id}) do
    user = conn.assigns.current_user

    with {:ok, %Task{} = task} <- Tasks.find(user.id, task_id) do
      executions = StepExecutions.list_by(user.id, task_id: task.id)
      render(conn, :index, executions: executions)
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, execution} <- StepExecutions.get_by(user.id, id: id) do
      render(conn, :show, execution: execution)
    end
  end
end
