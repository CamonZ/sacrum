defmodule SacrumWeb.ProjectChannel do
  use Phoenix.Channel

  alias Sacrum.Repo.Projects

  @impl true
  def join("project:" <> slug, _params, socket) do
    user = socket.assigns.current_user

    case Projects.get_by(user_id: user.id, slug: slug) do
      {:ok, project} ->
        {:ok, assign(socket, :project, project)}

      {:error, :not_found} ->
        {:error, %{reason: "not found"}}
    end
  end

  @doc """
  Broadcasts a task_created event to the project channel.
  """
  def broadcast_task_created(project_slug, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_slug}", "task_created", task_payload(task))
  end

  @doc """
  Broadcasts a task_updated event to the project channel.
  """
  def broadcast_task_updated(project_slug, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_slug}", "task_updated", task_payload(task))
  end

  @doc """
  Broadcasts a task_deleted event to the project channel.
  """
  def broadcast_task_deleted(project_slug, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_slug}", "task_deleted", %{id: task.id})
  end

  @doc """
  Broadcasts a workflow_changed event to the project channel.
  """
  def broadcast_workflow_changed(project_slug, task) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "workflow_changed",
      workflow_payload(task)
    )
  end

  defp task_payload(task) do
    %{
      id: task.id,
      short_id: task.short_id,
      title: task.title,
      description: task.description,
      level: task.level,
      priority: task.priority,
      tags: task.tags,
      needs_human_review: task.needs_human_review,
      started_at: task.started_at,
      completed_at: task.completed_at,
      project_id: task.project_id,
      workflow_id: task.workflow_id,
      current_step_id: task.current_step_id,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp workflow_payload(task) do
    %{
      id: task.id,
      short_id: task.short_id,
      title: task.title,
      workflow_id: task.workflow_id,
      current_step_id: task.current_step_id,
      updated_at: task.updated_at
    }
  end
end
