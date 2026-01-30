defmodule SacrumWeb.ProjectChannel do
  use Phoenix.Channel

  alias Sacrum.Accounts.Projects

  @impl true
  def join("project:" <> slug, _params, socket) do
    user = socket.assigns.current_user

    case Projects.get_by(user.id, slug: slug) do
      {:ok, project} ->
        {:ok, assign(socket, :project, project)}

      {:error, :not_found} ->
        {:error, %{reason: "not found"}}
    end
  end

  # Task broadcasts

  def broadcast_task_created(project_slug, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_slug}", "task_created", task_payload(task))
  end

  def broadcast_task_updated(project_slug, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_slug}", "task_updated", task_payload(task))
  end

  def broadcast_task_deleted(project_slug, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_slug}", "task_deleted", %{id: task.id})
  end

  def broadcast_workflow_changed(project_slug, task) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "workflow_changed",
      workflow_payload(task)
    )
  end

  # Workflow broadcasts

  def broadcast_workflow_created(project_slug, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "workflow_created",
      workflow_entity_payload(workflow)
    )
  end

  def broadcast_workflow_updated(project_slug, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "workflow_updated",
      workflow_entity_payload(workflow)
    )
  end

  def broadcast_workflow_deleted(project_slug, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "workflow_deleted",
      %{id: workflow.id}
    )
  end

  # Step broadcasts

  def broadcast_step_created(project_slug, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "step_created",
      step_payload(step)
    )
  end

  def broadcast_step_updated(project_slug, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "step_updated",
      step_payload(step)
    )
  end

  def broadcast_step_deleted(project_slug, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "step_deleted",
      %{id: step.id, workflow_id: step.workflow_id}
    )
  end

  # Step transition broadcasts

  def broadcast_step_transition_created(project_slug, transition) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "step_transition_created",
      step_transition_payload(transition)
    )
  end

  def broadcast_step_transition_deleted(project_slug, transition) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "step_transition_deleted",
      %{id: transition.id}
    )
  end

  # Step execution broadcasts

  def broadcast_step_execution_created(project_slug, execution) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "step_execution_created",
      step_execution_payload(execution)
    )
  end

  def broadcast_step_execution_status_changed(project_slug, execution) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "step_execution_status_changed",
      step_execution_payload(execution)
    )
  end

  # Session log broadcasts

  def broadcast_session_log_created(project_slug, log) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_slug}",
      "session_log_created",
      session_log_payload(log)
    )
  end

  # Payload helpers

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

  defp workflow_entity_payload(workflow) do
    %{
      id: workflow.id,
      name: workflow.name,
      description: workflow.description,
      auto_advance: workflow.auto_advance,
      is_default: workflow.is_default,
      display_order: workflow.display_order,
      metadata: workflow.metadata,
      initial_step_id: workflow.initial_step_id,
      project_id: workflow.project_id,
      inserted_at: workflow.inserted_at,
      updated_at: workflow.updated_at
    }
  end

  defp step_payload(step) do
    %{
      id: step.id,
      name: step.name,
      goal: step.goal,
      agents: step.agents,
      skills: step.skills,
      agent_config: step.agent_config,
      is_final: step.is_final,
      step_order: step.step_order,
      workflow_id: step.workflow_id,
      inserted_at: step.inserted_at,
      updated_at: step.updated_at
    }
  end

  defp step_transition_payload(transition) do
    %{
      id: transition.id,
      from_step_id: transition.from_step_id,
      to_step_id: transition.to_step_id,
      label: transition.label,
      inserted_at: transition.inserted_at,
      updated_at: transition.updated_at
    }
  end

  defp step_execution_payload(execution) do
    %{
      id: execution.id,
      task_id: execution.task_id,
      workflow_id: execution.workflow_id,
      step_name: execution.step_name,
      status: execution.status,
      context: execution.context,
      prompt: execution.prompt,
      output: execution.output,
      transition_result: execution.transition_result,
      model: execution.model,
      model_provider: execution.model_provider,
      input_tokens: execution.input_tokens,
      output_tokens: execution.output_tokens,
      cost: execution.cost,
      duration_ms: execution.duration_ms,
      inserted_at: execution.inserted_at,
      updated_at: execution.updated_at
    }
  end

  defp session_log_payload(log) do
    %{
      id: log.id,
      step_execution_id: log.step_execution_id,
      content: log.content,
      inserted_at: log.inserted_at,
      updated_at: log.updated_at
    }
  end
end
