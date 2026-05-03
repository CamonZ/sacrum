defmodule SacrumWeb.ProjectChannel do
  use Phoenix.Channel

  alias Sacrum.Accounts.Projects

  @valid_client_types ~w(default daemon)
  @daemon_events ~w(run_step cancel_step)

  intercept([
    "task_created",
    "task_updated",
    "task_deleted",
    "workflow_created",
    "workflow_updated",
    "workflow_deleted",
    "step_created",
    "step_updated",
    "step_deleted",
    "step_transition_created",
    "step_transition_deleted",
    "step_execution_created",
    "step_execution_status_changed",
    "session_log_created",
    "section_created",
    "section_updated",
    "section_deleted",
    "run_step",
    "cancel_step"
  ])

  @impl true
  def join("project:" <> project_id, params, socket) do
    user = socket.assigns.current_user
    client_type = validate_client_type(params)

    case Projects.get_by(user.id, conditions: [id: project_id]) do
      {:ok, project} ->
        # Register daemon with the DaemonRegistry if client_type is daemon
        if client_type == "daemon" do
          Sacrum.DaemonRegistry.register_daemon(project_id)
        end

        {:ok, socket |> assign(:project, project) |> assign(:client_type, client_type)}

      {:error, :not_found} ->
        {:error, %{reason: "not found"}}
    end
  end

  defp validate_client_type(params) do
    client_type = Map.get(params, "client_type", "default")
    if client_type in @valid_client_types, do: client_type, else: "default"
  end

  @impl true
  def terminate(_reason, socket) do
    # Unregister daemon when it disconnects
    if Map.get(socket.assigns, :client_type) == "daemon" do
      project_id = socket.assigns.project.id
      Sacrum.DaemonRegistry.unregister_daemon(project_id)
    end

    :ok
  end

  @impl true
  def handle_out(event, payload, socket) do
    if should_push?(socket.assigns.client_type, event) do
      push(socket, event, payload)
    end

    {:noreply, socket}
  end

  defp should_push?(client_type, event) do
    case client_type do
      "default" -> event not in @daemon_events
      "daemon" -> event in @daemon_events
      _ -> false
    end
  end

  # Task broadcasts

  @spec broadcast_task_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_created(project_id, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_id}", "task_created", task_payload(task))
  end

  @spec broadcast_task_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_updated(project_id, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_id}", "task_updated", task_payload(task))
  end

  @spec broadcast_task_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_task_deleted(project_id, task) do
    SacrumWeb.Endpoint.broadcast("project:#{project_id}", "task_deleted", %{id: task.id})
  end

  # Workflow broadcasts

  @spec broadcast_workflow_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_workflow_created(project_id, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "workflow_created",
      workflow_entity_payload(workflow)
    )
  end

  @spec broadcast_workflow_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_workflow_updated(project_id, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "workflow_updated",
      workflow_entity_payload(workflow)
    )
  end

  @spec broadcast_workflow_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_workflow_deleted(project_id, workflow) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "workflow_deleted",
      %{id: workflow.id}
    )
  end

  # Step broadcasts

  @spec broadcast_step_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_created(project_id, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_created",
      step_payload(step)
    )
  end

  @spec broadcast_step_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_updated(project_id, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_updated",
      step_payload(step)
    )
  end

  @spec broadcast_step_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_deleted(project_id, step) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_deleted",
      %{id: step.id, workflow_id: step.workflow_id}
    )
  end

  # Step transition broadcasts

  @spec broadcast_step_transition_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_transition_created(project_id, transition) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_transition_created",
      step_transition_payload(transition)
    )
  end

  @spec broadcast_step_transition_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_transition_deleted(project_id, transition) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_transition_deleted",
      %{id: transition.id}
    )
  end

  # Step execution broadcasts

  @spec broadcast_step_execution_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_execution_created(project_id, execution) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_execution_created",
      step_execution_payload(execution)
    )
  end

  @spec broadcast_step_execution_status_changed(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_step_execution_status_changed(project_id, execution) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "step_execution_status_changed",
      step_execution_payload(execution)
    )
  end

  # Daemon broadcasts

  @spec broadcast_run_step(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_run_step(project_id, data) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "run_step",
      run_step_payload(data)
    )
  end

  @spec broadcast_cancel_step(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_cancel_step(project_id, data) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "cancel_step",
      cancel_step_payload(data)
    )
  end

  # Session log broadcasts

  @spec broadcast_session_log_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_session_log_created(project_id, log) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "session_log_created",
      session_log_payload(log)
    )
  end

  # Section broadcasts

  @spec broadcast_section_created(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_section_created(project_id, section) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "section_created",
      section_payload(section)
    )
  end

  @spec broadcast_section_updated(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_section_updated(project_id, section) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "section_updated",
      section_payload(section)
    )
  end

  @spec broadcast_section_deleted(String.t(), map()) :: :ok | {:error, term()}
  def broadcast_section_deleted(project_id, section) do
    SacrumWeb.Endpoint.broadcast(
      "project:#{project_id}",
      "section_deleted",
      %{id: section.id, task_id: section.task_id}
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
      review_comment: task.review_comment,
      rejection_reason: task.rejection_reason,
      revision_feedback: task.revision_feedback,
      started_at: task.started_at,
      completed_at: task.completed_at,
      project_id: task.project_id,
      workflow_id: task.workflow_id,
      current_step_id: task.current_step_id,
      worktree: task.worktree,
      inserted_at: task.inserted_at,
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
      is_final: workflow.is_final,
      display_order: workflow.display_order,
      metadata: workflow.metadata,
      initial_step_id: workflow.initial_step_id,
      kanban_column: workflow.kanban_column,
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
      step_type: step.step_type,
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
      cost: if(execution.cost, do: Decimal.to_string(execution.cost)),
      duration_ms: execution.duration_ms,
      handoff: execution.handoff,
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

  defp section_payload(section) do
    %{
      id: section.id,
      task_id: section.task_id,
      section_type: section.section_type,
      content: section.content,
      section_order: section.section_order,
      done: section.done,
      done_at: section.done_at,
      inserted_at: section.inserted_at,
      updated_at: section.updated_at
    }
  end

  defp run_step_payload(data) do
    payload = %{
      id: data.execution.id,
      task_id: data.execution.task_id,
      prompt: data.rendered_prompt,
      agent_config: data.step.agent_config,
      worktree: data.task.worktree
    }

    payload =
      case data.step.output_schema do
        nil -> payload
        schema -> Map.put(payload, :output_schema, schema)
      end

    # Field omitted when false so older daemons (pre-flag) see an unchanged payload shape.
    case data.step.verbose_daemon_logging do
      true -> Map.put(payload, :verbose_daemon_logging, true)
      _ -> payload
    end
  end

  defp cancel_step_payload(data) do
    %{
      step_execution_id: data.step_execution_id,
      task_id: data.task_id
    }
  end
end
