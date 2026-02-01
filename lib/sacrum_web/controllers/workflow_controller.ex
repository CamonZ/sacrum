defmodule SacrumWeb.WorkflowController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Projects
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Workflow

  action_fallback SacrumWeb.FallbackController

  def index(conn, params) do
    user = conn.assigns.current_user

    case params do
      %{"project_id" => project_id} ->
        with {:ok, _project} <- Projects.get_by(user.id, conditions: [id: project_id]) do
          workflows = Workflows.list_by(user.id, conditions: [project_id: project_id])
          render(conn, :index, workflows: workflows)
        end

      _ ->
        workflows = Workflows.list_by(user.id)
        render(conn, :index, workflows: workflows)
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, %Workflow{} = workflow} <- Workflows.get_by(user.id, conditions: [id: id]) do
      render(conn, :show, workflow: workflow)
    end
  end

  def create(conn, %{"project_id" => project_id} = params) do
    user = conn.assigns.current_user

    with {:ok, _project} <- Projects.get_by(user.id, conditions: [id: project_id]),
         {:ok, %Workflow{} = workflow} <- Workflows.insert(user.id, project_id, params) do
      conn
      |> put_status(:created)
      |> render(:show, workflow: workflow)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, %Workflow{} = workflow} <- Workflows.get_by(user.id, conditions: [id: id]),
         {:ok, %Workflow{} = updated} <- Workflows.update(workflow, params),
         {:ok, updated} <- maybe_sync_transitions(updated, params) do
      render(conn, :show, workflow: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, %Workflow{} = workflow} <- Workflows.get_by(user.id, conditions: [id: id]),
         {:ok, _} <- Workflows.delete(workflow) do
      send_resp(conn, :no_content, "")
    end
  end

  defp maybe_sync_transitions(workflow, %{"transitions" => transitions})
       when is_list(transitions) do
    case Workflows.sync_transitions(workflow, transitions) do
      {:ok, _transitions} ->
        {:ok, Repo.preload(workflow, :transitions, force: true)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_sync_transitions(workflow, _params), do: {:ok, workflow}
end
