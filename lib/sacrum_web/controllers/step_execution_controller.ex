defmodule SacrumWeb.StepExecutionController do
  use SacrumWeb, :controller

  import SacrumWeb.Helpers.Authorization

  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.Schemas.Task

  action_fallback SacrumWeb.FallbackController

  def index(conn, %{"task_id" => task_id}) do
    with {:ok, %Task{} = task} <- find_task(task_id),
         :ok <- authorize_task_owner(task, conn.assigns.current_user) do
      executions = StepExecutions.list_for_task(task.id)
      render(conn, :index, executions: executions)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, execution} <- StepExecutions.get(id),
         :ok <- authorize_execution_owner(execution, conn.assigns.current_user) do
      render(conn, :show, execution: execution)
    end
  end
end
