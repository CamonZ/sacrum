defmodule SacrumWeb.StepExecutionController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Repo.Tasks

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

  def create(conn, %{"task_id" => task_id} = params) do
    user = conn.assigns.current_user

    with {:ok, task} <- Tasks.get(task_id),
         project_id = task.project_id,
         {:ok, execution} <-
           StepExecutions.insert(user.id, Map.merge(params, %{"project_id" => project_id})) do
      conn
      |> put_status(:created)
      |> render(:show, execution: execution)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, execution} <- StepExecutions.get_by(user.id, conditions: [id: id]),
         {:ok, updated} <- StepExecutions.update(execution, params) do
      render(conn, :show, execution: updated)
    end
  end
end
