defmodule SacrumWeb.WorkflowController do
  use SacrumWeb, :controller

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Workflow

  action_fallback SacrumWeb.FallbackController

  def index(conn, params) do
    user = conn.assigns.current_user

    case params do
      %{"project_id" => project_id} ->
        with {:ok, project} <- authorize_project(project_id, user) do
          workflows = Workflows.list(project)
          render(conn, :index, workflows: workflows)
        end

      _ ->
        projects = Projects.list(user)
        workflows = Enum.flat_map(projects, &Workflows.list/1)
        render(conn, :index, workflows: workflows)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, %Workflow{} = workflow} <- Workflows.get(id),
         :ok <- authorize_workflow_owner(workflow, conn.assigns.current_user) do
      render(conn, :show, workflow: workflow)
    end
  end

  def create(conn, %{"project_id" => project_id} = params) do
    with {:ok, project} <- authorize_project(project_id, conn.assigns.current_user),
         {:ok, %Workflow{} = workflow} <- Workflows.insert(project, params) do
      conn
      |> put_status(:created)
      |> render(:show, workflow: workflow)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, %Workflow{} = workflow} <- Workflows.get(id),
         :ok <- authorize_workflow_owner(workflow, conn.assigns.current_user),
         {:ok, %Workflow{} = updated} <- Workflows.update(workflow, params),
         {:ok, updated} <- maybe_sync_transitions(updated, params) do
      render(conn, :show, workflow: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %Workflow{} = workflow} <- Workflows.get(id),
         :ok <- authorize_workflow_owner(workflow, conn.assigns.current_user),
         {:ok, _} <- Workflows.delete(workflow) do
      send_resp(conn, :no_content, "")
    end
  end

  defp authorize_project(project_id, user) do
    with {:ok, %Project{} = project} <- Projects.get(project_id),
         true <- project.user_id == user.id do
      {:ok, project}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp authorize_workflow_owner(%Workflow{} = workflow, user) do
    workflow = Sacrum.Repo.preload(workflow, :project)

    if workflow.project && workflow.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp maybe_sync_transitions(workflow, %{"transitions" => transitions})
       when is_list(transitions) do
    case Workflows.sync_transitions(workflow, transitions) do
      {:ok, _transitions} ->
        {:ok, Sacrum.Repo.preload(workflow, :transitions, force: true)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp maybe_sync_transitions(workflow, _params), do: {:ok, workflow}
end
